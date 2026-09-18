import CryptoKit
import Foundation

/// Services a `TorrentTask` needs from the session it belongs to.
public protocol TorrentEnvironment: AnyObject, Sendable {
	var peerID: PeerID { get }
	func currentSettings() async -> SessionSettings
	func listenPort() async -> UInt16
	func discoverPeersViaDHT(infoHash: InfoHash) async -> [PeerAddress]
	func downloadLimiter() async -> RateLimiter
	func uploadLimiter() async -> RateLimiter
	func torrentDidChange(infoHash: InfoHash) async
	func persist(state: TorrentPersistentState) async
	/// Called once a magnet link has resolved, so the metadata survives a restart.
	func persist(metainfo: TorrentMetainfo) async
}

/// Everything about one torrent: peers, pieces, trackers, disk and state.
public actor TorrentTask {

	private enum Constants {
		static let tickInterval: TimeInterval = 1
		static let chokeInterval: TimeInterval = 10
		static let optimisticUnchokeInterval: TimeInterval = 30
		static let dhtInterval: TimeInterval = 300
		/// With no peers at all there is nothing to lose by asking the DHT
		/// again sooner; the usual interval exists to save battery on a torrent
		/// that is already well connected.
		static let dhtIntervalWhenStarved: TimeInterval = 45
		/// How often a peerless torrent may ignore tracker backoff.
		static let starvedAnnounceInterval: TimeInterval = 120
		static let persistInterval: TimeInterval = 20
		static let requestTimeout: TimeInterval = 60
		static let keepAliveInterval: TimeInterval = 100
		static let unchokeSlots = 4
		/// Give up on a piece that keeps failing its hash check; something in
		/// the swarm is poisoned and refetching forever burns bandwidth.
		static let maximumHashFailures = 5
		/// How many corrupt pieces a peer may be *implicated* in before it is
		/// banned. A peer caught on its own is banned at once instead; this
		/// counter only exists for pieces assembled from several peers, where
		/// any one of them could be the liar.
		static let maximumPeerHashFailures = 3
	}

	// MARK: - Identity

	public let infoHash: InfoHash
	private let environment: TorrentEnvironment
	private let downloadDirectory: URL

	private var metainfo: TorrentMetainfo?
	private var magnet: MagnetURI?
	private var displayName: String

	// MARK: - State

	private var storage: TorrentStorage?
	private var picker: PiecePicker?
	private var trackers: TrackerManager
	private let webSeeds = WebSeedManager()
	/// URLs from the metainfo's `url-list` or the magnet's `ws` parameters,
	/// kept until the metadata arrives and the file layout is known.
	private var webSeedURLs: [String] = []
	/// Mirror of the tracker list, kept because `persistentState()` is
	/// synchronous and cannot await the tracker actor.
	private var knownTrackerURLs: [String] = []
	private var metadataDownload: MetadataDownload?

	private var peers: [PeerAddress: PeerSession] = [:]
	private var candidatePeers: [PeerAddress] = []
	private var attemptedPeers: Set<PeerAddress> = []
	private var connectingCount = 0

	/// Peers implicated in corrupt pieces. Banned by host rather than by
	/// address: a peer that reconnects arrives from a fresh source port, so
	/// banning the full address would ban nothing at all.
	private(set) var bannedHosts: Set<String> = []
	private var hashFailuresByHost: [String: Int] = [:]

	private var status: TorrentStatus = .queued
	private var errorMessage: String?
	private var addedAt = Date()
	private var completedAt: Date?
	private var uploadedBytes: Int64 = 0
	private var downloadedBytes: Int64 = 0
	private var sessionDownloadedBytes: Int64 = 0
	private var downloadMeter = RateMeter()
	private var uploadMeter = RateMeter()
	private var filePriorities: [Int: PiecePriority] = [:]

	/// Last published snapshot, readable without entering the actor.
	private let snapshotCache = SnapshotCache()

	private var runLoop: Task<Void, Never>?
	private var lastChokeUpdate = Date.distantPast
	private var lastOptimisticUnchoke = Date.distantPast
	private var lastDHTLookup = Date.distantPast
	private var lastPersist = Date.distantPast
	private var optimisticPeer: PeerAddress?
	private var isShuttingDown = false
	private var isAnnounceInFlight = false
	private var isDHTLookupInFlight = false
	private var lastStarvedAnnounce = Date.distantPast

	// MARK: - Init

	public init(
		source: TorrentSource,
		downloadDirectory: URL,
		environment: TorrentEnvironment,
		listenPort: UInt16,
		restoredState: TorrentPersistentState? = nil
	) {
		self.infoHash = source.infoHash
		self.environment = environment
		self.downloadDirectory = downloadDirectory
		self.displayName = restoredState?.name ?? source.displayName

		var tiers: [[String]] = []
		switch source {
		case let .metainfo(metainfo):
			self.metainfo = metainfo
			tiers = metainfo.trackerTiers
			self.webSeedURLs = metainfo.webSeeds
		case let .magnet(magnet):
			self.magnet = magnet
			tiers = magnet.trackers.isEmpty ? [] : [magnet.trackers]
			self.candidatePeers = magnet.peerHints
			self.webSeedURLs = magnet.webSeeds
		}
		if let extra = restoredState?.trackers, !extra.isEmpty {
			tiers.append(extra)
		}

		self.trackers = TrackerManager(
			infoHash: source.infoHash,
			peerID: environment.peerID,
			listenPort: listenPort,
			tiers: tiers
		)
		self.knownTrackerURLs = tiers.flatMap { $0 }

		if let restoredState {
			self.addedAt = restoredState.addedAt
			self.completedAt = restoredState.completedAt
			self.uploadedBytes = restoredState.uploadedBytes
			self.downloadedBytes = restoredState.downloadedBytes
			self.filePriorities = restoredState.filePriorities.reduce(into: [:]) { result, entry in
				result[entry.key] = PiecePriority(rawValue: entry.value) ?? .normal
			}
			self.status = restoredState.isPaused ? .paused : .queued
		}
	}

	// MARK: - Lifecycle

	public func start(resumeBitfield: BitField? = nil, needsCheck: Bool = false) async {
		guard runLoop == nil else { return }
		isShuttingDown = false
		errorMessage = nil

		Log.torrent.info("Starting \(self.displayName, privacy: .public)")
		if let metainfo {
			await prepare(metainfo: metainfo, resumeBitfield: resumeBitfield, needsCheck: needsCheck)
		} else {
			status = .fetchingMetadata(progress: 0)
		}

		runLoop = Task { [weak self] in
			while !Task.isCancelled {
				await self?.tick()
				try? await Task.sleep(nanoseconds: UInt64(Constants.tickInterval * 1_000_000_000))
			}
		}
	}

	public func pause() async {
		guard !status.isPaused else { return }
		status = .paused
		await shutdownNetworking(announceStopped: true)
		await persistState()
		await snapshot()
		await environment.torrentDidChange(infoHash: infoHash)
	}

	public func resume() async {
		guard status.isPaused else { return }
		status = .queued
		attemptedPeers.removeAll()
		await start(resumeBitfield: picker?.have, needsCheck: false)
		await snapshot()
		await environment.torrentDidChange(infoHash: infoHash)
	}

	public func shutdown(deleteFiles: Bool) async {
		isShuttingDown = true
		await shutdownNetworking(announceStopped: true)
		if deleteFiles {
			await storage?.deleteFiles()
		} else {
			await storage?.flush()
		}
		await storage?.close()
		storage = nil
	}

	private func shutdownNetworking(announceStopped: Bool) async {
		runLoop?.cancel()
		runLoop = nil
		for peer in peers.values {
			peer.eventTask?.cancel()
			peer.connection.close(reason: .localChoice)
		}
		peers.removeAll()
		connectingCount = 0
		// A fetch already in the air will be discarded on delivery; releasing
		// the reservations now stops those pieces from being unclaimable after
		// the torrent resumes.
		for index in webSeeds.allPiecesInFlight() {
			picker?.releaseWebSeedReservation(index)
		}
		webSeeds.reset()
		resetDiscoveryGuards()
		downloadMeter.reset()
		uploadMeter.reset()
		if announceStopped {
			await trackers.announceStopped(statistics: trackerStatistics())
		}
	}

	/// Sets up storage and the piece picker without starting networking, so a
	/// paused torrent still reports accurate progress in the UI.
	public func prepareStorageOnly(resumeBitfield: BitField?) async {
		guard let metainfo, picker == nil else { return }
		await prepare(metainfo: metainfo, resumeBitfield: resumeBitfield, needsCheck: false)
	}

	private func prepare(metainfo: TorrentMetainfo, resumeBitfield: BitField?, needsCheck: Bool) async {
		let wasPaused = status.isPaused
		let storage = TorrentStorage(metainfo: metainfo, downloadDirectory: downloadDirectory)
		let picker = PiecePicker(metainfo: metainfo, have: resumeBitfield)
		self.storage = storage
		self.picker = picker
		applyFilePriorities()
		// The metainfo's own list and the magnet's `ws` parameters are both
		// valid sources and a torrent added as a magnet only ever has the latter.
		webSeeds.configure(urls: webSeedURLs + metainfo.webSeeds, metainfo: metainfo)

		let hasExistingFiles = await storage.anyFileExists()
		if needsCheck || (resumeBitfield == nil && hasExistingFiles) {
			Log.torrent.info("Rechecking \(metainfo.pieceCount) pieces of \(metainfo.name, privacy: .public)")
			await recheck()
		}

		if wasPaused {
			status = .paused
		} else {
			status = picker.isComplete ? .seeding : .downloading
		}
		if picker.isComplete, completedAt == nil { completedAt = Date() }
		downloadedBytes = max(downloadedBytes, picker.downloadedBytes)
		await snapshot()
	}

	// MARK: - Piece verification

	/// Re-hashes everything on disk. Used when resume data is missing or the
	/// user asks for it; the files may have been changed behind our back.
	public func recheck() async {
		guard let metainfo, let storage else { return }
		let previousStatus = status
		status = .checkingFiles(progress: 0)

		var verified = BitField(bitCount: metainfo.pieceCount)
		for index in 0..<metainfo.pieceCount {
			let size = metainfo.pieceSize(at: index)
			let request = BlockRequest(pieceIndex: index, begin: 0, length: size)
			if let data = try? await storage.read(request),
			   Data(Insecure.SHA1.hash(data: data)) == metainfo.pieceHashes[index] {
				verified[index] = true
			}
			if index % 32 == 0 {
				status = .checkingFiles(progress: Double(index) / Double(metainfo.pieceCount))
				await snapshot()
				await environment.torrentDidChange(infoHash: infoHash)
				await Task.yield()
			}
		}

		Log.torrent.info("Recheck finished: \(verified.setBitCount)/\(metainfo.pieceCount) pieces present")
		picker?.restore(have: verified)
		downloadedBytes = picker?.downloadedBytes ?? downloadedBytes
		status = previousStatus.isPaused ? .paused : (picker?.isComplete == true ? .seeding : .downloading)
		await persistState()
	}

	// MARK: - Tick

	private func tick() async {
		guard !isShuttingDown, !status.isPaused else { return }
		let settings = await environment.currentSettings()

		updateRates()
		expireStaleRequests()
		await maintainPeerConnections(settings: settings)
		// Peer discovery runs alongside the tick rather than inside it. Both
		// talk to the network, and a tracker or DHT node that never answers
		// must not be able to stop the heartbeat that keeps peers connected
		// and blocks flowing.
		startAnnounceIfNeeded()
		startDHTDiscoveryIfNeeded(settings: settings)
		startWebSeedFetchesIfNeeded(settings: settings)
		await updateChokingIfNeeded()
		await requestBlocks()
		sendKeepAlives()
		updateStatus(settings: settings)

		if Date().timeIntervalSince(lastPersist) > Constants.persistInterval {
			await persistState()
		}
		await snapshot()
		await environment.torrentDidChange(infoHash: infoHash)
	}

	private func updateRates() {
		var totalDownload: Int64 = 0
		var totalUpload: Int64 = 0
		let now = Date()
		for peer in peers.values {
			peer.downloadMeter.update(total: peer.downloadedBytes, now: now)
			peer.uploadMeter.update(total: peer.uploadedBytes, now: now)
			totalDownload += peer.downloadedBytes
			totalUpload += peer.uploadedBytes
		}
		downloadMeter.update(total: sessionDownloadedBytes + totalDownload + webSeeds.downloadedBytes, now: now)
		uploadMeter.update(total: uploadedBytes, now: now)
	}

	private func expireStaleRequests() {
		guard let picker else { return }
		picker.expireStaleRequests(olderThan: Constants.requestTimeout)
	}

	private func updateStatus(settings: SessionSettings) {
		guard !status.isPaused else { return }
		if case .checkingFiles = status { return }
		if case .failed = status { return }

		if metainfo == nil {
			status = .fetchingMetadata(progress: metadataDownload?.progress ?? 0)
			return
		}
		guard let picker else { return }

		if picker.isComplete {
			if completedAt == nil {
				completedAt = Date()
				Task { [weak self] in await self?.announceCompleted() }
			}
			let ratio = downloadedBytes > 0 ? Double(uploadedBytes) / Double(downloadedBytes) : 0
			if settings.seedRatioLimit > 0, ratio >= settings.seedRatioLimit {
				status = .finished
				Task { [weak self] in await self?.pause() }
			} else {
				status = .seeding
			}
		} else if downloadMeter.bytesPerSecond > 0 {
			status = .downloading
		} else {
			status = peers.isEmpty ? .stalled : .downloading
		}
	}

	// MARK: - Peer discovery

	private func startAnnounceIfNeeded() {
		guard !isAnnounceInFlight else { return }
		isAnnounceInFlight = true
		Task { [weak self] in
			await self?.runAnnounce()
		}
	}

	private func runAnnounce() async {
		defer { isAnnounceInFlight = false }
		// With no peers at all there is nothing to conserve: override the
		// backoff so a torrent cannot sit at zero peers waiting out a
		// half-hour timer.
		let starved = peers.isEmpty && Date().timeIntervalSince(lastStarvedAnnounce) > Constants.starvedAnnounceInterval
		if starved { lastStarvedAnnounce = Date() }

		let discovered = await trackers.announce(
			event: .periodic,
			statistics: trackerStatistics(),
			force: starved
		)
		if !discovered.isEmpty {
			Log.tracker.info("Trackers returned \(discovered.count) peer(s) for \(self.displayName, privacy: .public)")
		}
		addCandidates(discovered)
	}

	private func announceCompleted() async {
		let peers = await trackers.announce(event: .completed, statistics: trackerStatistics(), force: true)
		addCandidates(peers)
	}

	/// Clears the in-flight guards so a resumed torrent announces immediately
	/// instead of waiting out a guard left set by the previous run.
	private func resetDiscoveryGuards() {
		isAnnounceInFlight = false
		isDHTLookupInFlight = false
		lastDHTLookup = .distantPast
	}

	private func startDHTDiscoveryIfNeeded(settings: SessionSettings) {
		guard !isDHTLookupInFlight, settings.isDHTEnabled, metainfo?.isPrivate != true else { return }
		guard peers.count < settings.maximumPeersPerTorrent else { return }
		let interval = peers.isEmpty ? Constants.dhtIntervalWhenStarved : Constants.dhtInterval
		guard Date().timeIntervalSince(lastDHTLookup) > interval else { return }
		lastDHTLookup = Date()
		isDHTLookupInFlight = true

		Task { [weak self] in
			await self?.runDHTDiscovery()
		}
	}

	private func runDHTDiscovery() async {
		defer { isDHTLookupInFlight = false }
		let found = await environment.discoverPeersViaDHT(infoHash: infoHash)
		Log.torrent.info("DHT returned \(found.count) peer(s) for \(self.displayName, privacy: .public)")
		addCandidates(found)
	}

	public func addCandidates(_ addresses: [PeerAddress]) {
		for address in addresses where address.isRoutable {
			guard !bannedHosts.contains(address.host) else { continue }
			guard peers[address] == nil, !attemptedPeers.contains(address) else { continue }
			guard !candidatePeers.contains(address) else { continue }
			candidatePeers.append(address)
		}
		// Keep the queue bounded; stale candidates are worthless anyway.
		if candidatePeers.count > 500 {
			candidatePeers.removeFirst(candidatePeers.count - 500)
		}
	}

	// MARK: - Web seeds

	/// Hands idle web seeds a piece to fetch.
	///
	/// Like announces and DHT lookups, the fetch runs beside the tick rather
	/// than inside it: an HTTP server that accepts the connection and then says
	/// nothing for thirty seconds must not be able to stop the heartbeat.
	/// Refills the web seeds' queues as soon as one finishes, rather than
	/// leaving them idle until the next tick: at a second per piece a web seed
	/// would be throttled to the tick rate rather than to the network.
	private func pumpWebSeeds() async {
		guard !webSeeds.isEmpty else { return }
		startWebSeedFetchesIfNeeded(settings: await environment.currentSettings())
	}

	private func startWebSeedFetchesIfNeeded(settings: SessionSettings) {
		guard settings.areWebSeedsEnabled, !webSeeds.isEmpty, !status.isPaused else { return }
		guard let picker, !picker.isComplete else { return }

		while webSeeds.hasCapacity, let client = webSeeds.nextAvailableSeed() {
			guard let index = picker.reservePieceForWebSeed() else { return }
			webSeeds.markStarted(piece: index, on: client.baseURL)
			Task { [weak self] in
				await self?.runWebSeedFetch(piece: index, client: client)
			}
		}
	}

	private func runWebSeedFetch(piece index: Int, client: WebSeedClient) async {
		do {
			let data = try await client.fetch(piece: index)
			// Web seeds are not choked and cannot be asked to slow down, so the
			// limiter is applied after the fact: the next piece simply waits.
			let limiter = await environment.downloadLimiter()
			await limiter.consume(data.count)
			await deliverWebSeedPiece(index: index, data: data, from: client.baseURL)
		} catch {
			await failWebSeedPiece(index: index, from: client.baseURL, error: error)
		}
		await pumpWebSeeds()
	}

	private func deliverWebSeedPiece(index: Int, data: Data, from url: String) async {
		guard let picker, let storage, let metainfo else { return }
		defer { picker.releaseWebSeedReservation(index) }

		guard data.count == metainfo.pieceSize(at: index) else {
			webSeeds.markFailed(piece: index, on: url, error: "Wrong piece length")
			return
		}
		guard Data(Insecure.SHA1.hash(data: data)) == metainfo.pieceHashes[index] else {
			Log.torrent.warning("Web seed \(url, privacy: .public) served a corrupt piece \(index)")
			webSeeds.markFailed(piece: index, on: url, error: "Piece \(index) failed its hash check")
			return
		}
		guard !picker.have[index] else {
			// Peers beat the web seed to it; the bytes are simply redundant.
			webSeeds.markSucceeded(piece: index, byteCount: 0, on: url)
			return
		}

		do {
			try await storage.write(piece: index, data: data)
		} catch {
			Log.storage.error("Web seed write failed: \(error.localizedDescription, privacy: .public)")
			webSeeds.markFailed(piece: index, on: url, error: error.localizedDescription)
			return
		}

		webSeeds.markSucceeded(piece: index, byteCount: data.count, on: url)
		picker.markVerified(piece: index)
		downloadedBytes = picker.downloadedBytes

		for peer in peers.values {
			peer.connection.send(.have(pieceIndex: index))
		}
		for peer in peers.values {
			await updateInterest(in: peer)
		}
		if picker.isComplete {
			await storage.flush()
			await persistState()
		}
	}

	private func failWebSeedPiece(index: Int, from url: String, error: Error) async {
		picker?.releaseWebSeedReservation(index)
		webSeeds.markFailed(piece: index, on: url, error: error.localizedDescription)
		Log.torrent.debug("Web seed \(url, privacy: .public) failed piece \(index): \(error.localizedDescription, privacy: .public)")
	}

	private func maintainPeerConnections(settings: SessionSettings) async {
		let limit = settings.maximumPeersPerTorrent
		guard peers.count + connectingCount < limit else { return }

		// Once every candidate has been tried, allow retries; peers come and go.
		if candidatePeers.isEmpty, !attemptedPeers.isEmpty, peers.isEmpty {
			attemptedPeers.removeAll()
		}

		let slots = min(8, limit - peers.count - connectingCount)
		guard slots > 0 else { return }

		for _ in 0..<slots {
			guard !candidatePeers.isEmpty else { break }
			let address = candidatePeers.removeFirst()
			guard peers[address] == nil, !attemptedPeers.contains(address) else { continue }
			attemptedPeers.insert(address)
			connect(to: address)
		}
	}

	private func connect(to address: PeerAddress) {
		let connection = PeerConnection(
			address: address,
			role: .outgoing(infoHash: infoHash),
			localPeerID: environment.peerID
		)
		let session = PeerSession(
			connection: connection,
			address: address,
			isIncoming: false,
			pieceCount: metainfo?.pieceCount ?? 0
		)
		peers[address] = session
		connectingCount += 1
		consumeEvents(of: session, channel: PeerEventChannel(connection.start()))
	}

	/// Adopts a connection that `TorrentSession` accepted and matched to us.
	public func adopt(
		incoming connection: PeerConnection,
		address: PeerAddress,
		handshake: PeerHandshake,
		channel: PeerEventChannel
	) async {
		let settings = await environment.currentSettings()
		guard peers.count < settings.maximumPeersPerTorrent,
		      peers[address] == nil,
		      !bannedHosts.contains(address.host),
		      !status.isPaused
		else {
			connection.close(reason: .localChoice)
			return
		}
		let session = PeerSession(
			connection: connection,
			address: address,
			isIncoming: true,
			pieceCount: metainfo?.pieceCount ?? 0
		)
		peers[address] = session
		consumeEvents(of: session, channel: channel)
		connection.acceptIncomingHandshake(infoHash: infoHash)
		await handleHandshake(handshake, from: address)
	}

	private func consumeEvents(of session: PeerSession, channel: PeerEventChannel) {
		let address = session.address
		session.eventTask = Task { [weak self] in
			while let event = await channel.next() {
				guard let self else { return }
				switch event {
				case let .handshake(handshake):
					await self.handleHandshake(handshake, from: address)
				case let .message(message):
					await self.handle(message: message, from: address)
				case let .disconnected(reason):
					await self.handleDisconnect(address: address, reason: reason)
				}
			}
		}
	}

	// MARK: - Peer protocol

	private func handleHandshake(_ handshake: PeerHandshake, from address: PeerAddress) async {
		guard let session = peers[address] else { return }
		if !session.isIncoming {
			connectingCount = max(0, connectingCount - 1)
		}
		session.remotePeerID = handshake.peerID
		session.supportsExtensions = handshake.supportsExtensionProtocol
		session.lastMessageAt = Date()

		// Reject our own connections, which happen when a tracker hands us back
		// our external address.
		if handshake.peerID == environment.peerID.raw {
			disconnect(address: address, reason: .localChoice)
			return
		}

		var outgoing: [PeerMessage] = []
		if handshake.supportsExtensionProtocol {
			let settings = await environment.currentSettings()
			let port = await environment.listenPort()
			outgoing.append(.extended(
				id: ExtensionProtocol.handshakeID,
				payload: ExtensionProtocol.handshakePayload(
					metadataSize: metainfo?.rawInfoDictionary.count,
					listenPort: port,
					clientVersion: "iTorrent 1.0",
					supportsPeerExchange: settings.isPeerExchangeEnabled && metainfo?.isPrivate != true
				)
			))
		}
		if let picker, picker.completedPieces > 0 {
			outgoing.append(.bitfield(picker.have.bytes))
		}
		session.connection.send(outgoing)
	}

	private func handle(message: PeerMessage, from address: PeerAddress) async {
		guard let session = peers[address], let key = peers[address].map({ ObjectIdentifier($0) }) else { return }
		session.lastMessageAt = Date()

		switch message {
		case .keepAlive:
			break

		case .choke:
			session.peerIsChoking = true
			picker?.releaseRequests(from: key)

		case .unchoke:
			session.peerIsChoking = false
			await requestBlocks(from: session)

		case .interested:
			session.peerIsInterested = true

		case .notInterested:
			session.peerIsInterested = false

		case let .have(index):
			guard index >= 0 else { return }
			guard session.bitfield.bitCount > index else {
				// Still waiting for metadata; replay this later.
				session.pendingHaveIndices.insert(index)
				return
			}
			let alreadyHad = session.bitfield[index]
			session.bitfield[index] = true
			if !alreadyHad { picker?.addAvailability(piece: index) }
			await updateInterest(in: session)

		case let .bitfield(bytes):
			guard let metainfo else {
				// Arrived before metadata, so the piece count is still unknown.
				session.pendingBitfieldBytes = bytes
				return
			}
			guard let bitfield = BitField(bytes: bytes, bitCount: metainfo.pieceCount) else {
				disconnect(address: address, reason: .protocolViolation("Bad bitfield"))
				return
			}
			if session.didReceiveBitfield {
				picker?.removeAvailability(bitfield: session.bitfield)
			}
			session.bitfield = bitfield
			session.didReceiveBitfield = true
			picker?.addAvailability(bitfield: bitfield)
			await updateInterest(in: session)

		case let .request(request):
			await handleUploadRequest(request, from: session)

		case let .piece(index, begin, block):
			await handleIncomingBlock(pieceIndex: index, begin: begin, block: block, from: session)

		case let .cancel(request):
			session.pendingUploads.removeAll { $0 == request }

		case .port:
			// The peer advertises a DHT node; the session-level DHT bootstraps
			// from routers and PEX, so this is informational only.
			break

		case let .extended(id, payload):
			await handleExtended(id: id, payload: payload, from: session)
		}
	}

	private func updateInterest(in session: PeerSession) async {
		guard let picker else { return }
		let interesting = picker.isInteresting(peerBitfield: session.bitfield)
		guard interesting != session.weAreInterested else { return }
		session.weAreInterested = interesting
		session.connection.send(interesting ? .interested : .notInterested)
		if interesting, !session.peerIsChoking {
			await requestBlocks(from: session)
		}
	}

	// MARK: - Downloading

	private func requestBlocks() async {
		for session in peers.values where session.canRequest {
			await requestBlocks(from: session)
		}
	}

	private func requestBlocks(from session: PeerSession) async {
		guard let picker, session.canRequest, !status.isPaused else { return }

		let outstanding = picker.outstandingRequestCount(for: session.key)
		var budget = session.targetPipelineDepth - outstanding
		guard budget > 0 else { return }

		// Honour the download limit by capping how much we ask for; refusing to
		// request is the only way to throttle an incoming TCP stream without
		// stalling the socket.
		let limiter = await environment.downloadLimiter()
		if await limiter.isLimited {
			let allowedBytes = await limiter.take(upTo: budget * BlockRequest.standardLength)
			budget = min(budget, allowedBytes / BlockRequest.standardLength)
			guard budget > 0 else { return }
		}

		let requests = picker.pick(for: session.key, peerBitfield: session.bitfield, limit: budget)
		guard !requests.isEmpty else { return }
		session.connection.send(requests.map { PeerMessage.request($0) })
	}

	private func handleIncomingBlock(pieceIndex: Int, begin: Int, block: Data, from session: PeerSession) async {
		guard let picker, let storage, let metainfo else { return }
		session.downloadedBytes += Int64(block.count)

		switch picker.receive(pieceIndex: pieceIndex, begin: begin, block: block, from: session.key) {
		case .ignored, .accepted:
			break

		case let .pieceReady(index, data):
			let expected = metainfo.pieceHashes[index]
			let actual = Data(Insecure.SHA1.hash(data: data))
			guard actual == expected else {
				Log.torrent.warning("Piece \(index) failed its hash check")
				let culprits = picker.contributors(toPiece: index)
				picker.markCorrupt(piece: index)
				if picker.failureCount(piece: index) >= Constants.maximumHashFailures {
					errorMessage = "Piece \(index) failed its hash check repeatedly."
				}
				await banPeers(implicatedIn: culprits)
				return
			}
			do {
				try await storage.write(piece: index, data: data)
			} catch {
				Log.storage.error("Write failed: \(error.localizedDescription, privacy: .public)")
				status = .failed(error.localizedDescription)
				errorMessage = error.localizedDescription
				await pause()
				return
			}
			picker.markVerified(piece: index)
			downloadedBytes = picker.downloadedBytes

			for peer in peers.values {
				peer.connection.send(.have(pieceIndex: index))
			}
			for peer in peers.values {
				await updateInterest(in: peer)
			}
			if picker.isComplete {
				await storage.flush()
				await persistState()
			}
		}

		await requestBlocks(from: session)
	}

	// MARK: - Banning

	/// Attributes a corrupt piece to the peers that built it.
	///
	/// A piece assembled from exactly one peer is proof: that peer sent bytes
	/// that do not hash to what the torrent says they must, so it goes at once.
	/// When several peers contributed, each is only suspected, and a peer has
	/// to turn up in a few such pieces before it is banned — otherwise one
	/// poisoner would take honest peers down with it.
	private func banPeers(implicatedIn culprits: Set<ObjectIdentifier>) async {
		let addresses = peers.values.filter { culprits.contains($0.key) }.map(\.address)
		guard !addresses.isEmpty else { return }

		for address in addresses {
			if addresses.count == 1 {
				ban(host: address.host, reason: "sent a piece that failed its hash check")
				continue
			}
			let failures = hashFailuresByHost[address.host, default: 0] + 1
			hashFailuresByHost[address.host] = failures
			if failures >= Constants.maximumPeerHashFailures {
				ban(host: address.host, reason: "implicated in \(failures) corrupt pieces")
			}
		}
	}

	private func ban(host: String, reason: String) {
		guard bannedHosts.insert(host).inserted else { return }
		Log.peer.warning("Banned \(host, privacy: .public): \(reason, privacy: .public)")

		hashFailuresByHost[host] = nil
		candidatePeers.removeAll { $0.host == host }
		for address in peers.keys where address.host == host {
			disconnect(address: address, reason: .protocolViolation("Banned: \(reason)"))
		}
	}

	// MARK: - Uploading

	private func handleUploadRequest(_ request: BlockRequest, from session: PeerSession) async {
		guard !session.weAreChoking,
		      request.length > 0,
		      request.length <= 128 * 1024,
		      let picker, picker.have[request.pieceIndex],
		      let storage
		else { return }

		guard let data = try? await storage.read(request) else { return }

		let limiter = await environment.uploadLimiter()
		await limiter.consume(data.count)

		session.connection.send(.piece(pieceIndex: request.pieceIndex, begin: request.begin, block: data))
		session.uploadedBytes += Int64(data.count)
		uploadedBytes += Int64(data.count)
	}

	// MARK: - Choking

	private func updateChokingIfNeeded() async {
		guard Date().timeIntervalSince(lastChokeUpdate) >= Constants.chokeInterval else { return }
		lastChokeUpdate = Date()

		let seeding = picker?.isComplete == true
		let interested = peers.values.filter(\.peerIsInterested)

		// While downloading, reciprocate with whoever feeds us fastest; while
		// seeding, favour whoever takes data fastest so pieces spread quickly.
		let ranked = interested.sorted { lhs, rhs in
			seeding
				? lhs.uploadMeter.bytesPerSecond > rhs.uploadMeter.bytesPerSecond
				: lhs.downloadMeter.bytesPerSecond > rhs.downloadMeter.bytesPerSecond
		}

		var unchoked = Set(ranked.prefix(Constants.unchokeSlots - 1).map(\.address))

		// One rotating optimistic slot gives new peers a chance to prove
		// themselves; without it the same four peers are unchoked forever.
		if Date().timeIntervalSince(lastOptimisticUnchoke) >= Constants.optimisticUnchokeInterval || optimisticPeer == nil {
			lastOptimisticUnchoke = Date()
			optimisticPeer = peers.values
				.filter { $0.peerIsInterested && !unchoked.contains($0.address) }
				.randomElement()?
				.address
		}
		if let optimisticPeer { unchoked.insert(optimisticPeer) }

		for session in peers.values {
			let shouldChoke = !unchoked.contains(session.address)
			guard shouldChoke != session.weAreChoking else { continue }
			session.weAreChoking = shouldChoke
			session.connection.send(shouldChoke ? .choke : .unchoke)
		}
	}

	private func sendKeepAlives() {
		let now = Date()
		for session in peers.values where now.timeIntervalSince(session.lastKeepAliveSentAt) > Constants.keepAliveInterval {
			session.lastKeepAliveSentAt = now
			session.connection.send(.keepAlive)
		}
	}

	// MARK: - Extensions

	private func handleExtended(id: UInt8, payload: Data, from session: PeerSession) async {
		if id == ExtensionProtocol.handshakeID {
			let handshake = ExtensionProtocol.RemoteHandshake(payload: payload)
			session.remoteExtensions = handshake
			if metainfo == nil, let size = handshake.metadataSize, metadataDownload == nil {
				metadataDownload = MetadataDownload(infoHash: infoHash, totalSize: size)
			}
			await requestMetadata(from: session)
			return
		}

		switch id {
		case ExtensionProtocol.LocalID.metadata:
			await handleMetadata(payload: payload, from: session)

		case ExtensionProtocol.LocalID.peerExchange:
			let settings = await environment.currentSettings()
			guard settings.isPeerExchangeEnabled, metainfo?.isPrivate != true else { return }
			addCandidates(PeerExchange.decode(payload: payload))

		default:
			break
		}
	}

	private func requestMetadata(from session: PeerSession) async {
		guard metainfo == nil,
		      let download = metadataDownload,
		      let remoteID = session.remoteExtensions?.metadataID
		else { return }

		let budget = 4 - session.metadataRequestsInFlight
		guard budget > 0 else { return }
		let pieces = download.nextRequests(limit: budget)
		guard !pieces.isEmpty else { return }

		session.metadataRequestsInFlight += pieces.count
		session.connection.send(pieces.map { piece in
			PeerMessage.extended(id: remoteID, payload: MetadataMessage.request(piece: piece).encoded())
		})
	}

	private func handleMetadata(payload: Data, from session: PeerSession) async {
		guard let message = MetadataMessage(payload: payload) else { return }

		switch message {
		case let .request(piece):
			// Serve metadata to others once we have it.
			guard let metainfo, let remoteID = session.remoteExtensions?.metadataID else { return }
			let raw = metainfo.rawInfoDictionary
			let start = piece * MetadataMessage.pieceSize
			guard start < raw.count else {
				session.connection.send(.extended(id: remoteID, payload: MetadataMessage.reject(piece: piece).encoded()))
				return
			}
			let end = min(raw.count, start + MetadataMessage.pieceSize)
			let chunk = raw.subdata(in: start..<end)
			session.connection.send(.extended(
				id: remoteID,
				payload: MetadataMessage.data(piece: piece, totalSize: raw.count, payload: chunk).encoded()
			))

		case let .reject(piece):
			session.metadataRequestsInFlight = max(0, session.metadataRequestsInFlight - 1)
			metadataDownload?.markFailed(piece: piece)

		case let .data(piece, totalSize, chunk):
			session.metadataRequestsInFlight = max(0, session.metadataRequestsInFlight - 1)
			if metadataDownload == nil {
				metadataDownload = MetadataDownload(infoHash: infoHash, totalSize: totalSize)
			}
			guard let download = metadataDownload else { return }
			download.store(piece: piece, payload: chunk)
			status = .fetchingMetadata(progress: download.progress)

			if let raw = download.assembledInfoDictionary() {
				await adoptMetadata(rawInfoDictionary: raw)
			} else {
				await requestMetadata(from: session)
			}
		}
	}

	/// Turns a magnet download into a real torrent once the `info` dictionary
	/// has been assembled and verified against the info-hash.
	private func adoptMetadata(rawInfoDictionary: Data) async {
		guard metainfo == nil else { return }
		let trackerURLs = await trackers.trackerURLs
		guard let parsed = try? TorrentMetainfo(
			rawInfoDictionary: rawInfoDictionary,
			trackerTiers: trackerURLs.isEmpty ? [] : [trackerURLs],
			expectedInfoHash: infoHash
		) else {
			metadataDownload = nil
			return
		}

		Log.torrent.info("Metadata resolved: \(parsed.name, privacy: .public), \(parsed.pieceCount) pieces")
		metainfo = parsed
		displayName = parsed.name
		metadataDownload = nil
		knownTrackerURLs = trackerURLs
		await environment.persist(metainfo: parsed)
		await prepare(metainfo: parsed, resumeBitfield: nil, needsCheck: false)

		// Replay what each peer told us before we knew the piece count.
		for session in peers.values {
			var bitfield = session.pendingBitfieldBytes
				.flatMap { BitField(bytes: $0, bitCount: parsed.pieceCount) }
				?? BitField(bitCount: parsed.pieceCount)
			for index in session.pendingHaveIndices where index < parsed.pieceCount {
				bitfield[index] = true
			}
			session.pendingBitfieldBytes = nil
			session.pendingHaveIndices.removeAll()
			session.bitfield = bitfield
			session.didReceiveBitfield = true
			picker?.addAvailability(bitfield: bitfield)

			if let picker, picker.completedPieces > 0 {
				session.connection.send(.bitfield(picker.have.bytes))
			}
			await updateInterest(in: session)
		}
		await persistState()
		await snapshot()
		await environment.torrentDidChange(infoHash: infoHash)
	}

	// MARK: - Disconnects

	private func handleDisconnect(address: PeerAddress, reason: PeerDisconnectReason) async {
		guard let session = peers.removeValue(forKey: address) else { return }
		if !session.isIncoming, session.remotePeerID == nil {
			connectingCount = max(0, connectingCount - 1)
		}
		sessionDownloadedBytes += session.downloadedBytes
		if session.didReceiveBitfield {
			picker?.removeAvailability(bitfield: session.bitfield)
		}
		picker?.releaseRequests(from: session.key)
		session.eventTask?.cancel()
		if optimisticPeer == address { optimisticPeer = nil }
	}

	private func disconnect(address: PeerAddress, reason: PeerDisconnectReason) {
		peers[address]?.connection.close(reason: reason)
	}

	// MARK: - File selection

	public func setPriority(_ priority: PiecePriority, forFileAt index: Int) async {
		filePriorities[index] = priority
		applyFilePriorities()
		await persistState()
		await environment.torrentDidChange(infoHash: infoHash)
	}

	private func applyFilePriorities() {
		guard let metainfo, let picker else { return }

		var piecePriorities = [PiecePriority](repeating: .skip, count: metainfo.pieceCount)
		var skipped: Set<Int> = []

		for file in metainfo.files {
			let priority = file.isPadding ? PiecePriority.skip : (filePriorities[file.index] ?? .normal)
			if priority == .skip {
				skipped.insert(file.index)
				continue
			}
			guard file.length > 0 else { continue }
			let first = Int(file.offset / Int64(metainfo.pieceLength))
			let last = Int((file.offset + file.length - 1) / Int64(metainfo.pieceLength))
			for index in first...last {
				// A piece shared by several files takes the highest priority
				// among them, since it has to be downloaded either way.
				piecePriorities[index] = max(piecePriorities[index], priority)
			}
		}

		picker.setPriorities(piecePriorities)
		Task { [storage, skipped] in await storage?.setSkippedFiles(skipped) }
	}

	// MARK: - Trackers

	/// Shakes the torrent awake after the app was suspended: every peer socket
	/// and every announce died while it was in the background.
	public func recoverFromSuspension() async {
		guard !status.isPaused, !isShuttingDown, runLoop != nil else { return }
		lastStarvedAnnounce = .distantPast
		lastDHTLookup = .distantPast

		guard !isAnnounceInFlight else { return }
		isAnnounceInFlight = true
		Task { [weak self] in
			guard let self else { return }
			await self.runInterruptionRetry()
		}
	}

	private func runInterruptionRetry() async {
		defer { isAnnounceInFlight = false }
		let discovered = await trackers.retryAfterInterruption(statistics: trackerStatistics())
		Log.tracker.info(
			"Post-suspension retry for \(self.displayName, privacy: .public) found \(discovered.count) peer(s)"
		)
		addCandidates(discovered)
	}

	/// Updates the port advertised to trackers and re-announces immediately.
	public func setListenPort(_ port: UInt16) async {
		await trackers.setListenPort(port)
		guard !status.isPaused, runLoop != nil, !isAnnounceInFlight else { return }
		isAnnounceInFlight = true
		Task { [weak self] in
			await self?.runInterruptionRetry()
		}
	}

	public func addTracker(_ url: String) async {
		await trackers.add(urls: [url])
		knownTrackerURLs = await trackers.trackerURLs
		await persistState()
	}

	public func forceAnnounce() async {
		let found = await trackers.announce(event: .periodic, statistics: trackerStatistics(), force: true)
		addCandidates(found)
	}

	private func trackerStatistics() -> TrackerManager.Statistics {
		TrackerManager.Statistics(
			uploaded: uploadedBytes,
			downloaded: downloadedBytes,
			left: picker?.remainingBytes ?? (metainfo?.totalLength ?? 0)
		)
	}

	// MARK: - Persistence

	public func persistentState() -> TorrentPersistentState {
		TorrentPersistentState(
			infoHashHex: infoHash.hex,
			name: displayName,
			magnetURI: metainfo == nil ? magnet?.uriString : nil,
			savePath: downloadDirectory.path,
			addedAt: addedAt,
			completedAt: completedAt,
			uploadedBytes: uploadedBytes,
			downloadedBytes: downloadedBytes,
			pieceCount: metainfo?.pieceCount ?? 0,
			bitfield: picker?.have.bytes ?? Data(),
			isPaused: status.isPaused,
			filePriorities: filePriorities.reduce(into: [:]) { $0[$1.key] = $1.value.rawValue },
			// Saved in full: a tracker the user typed in by hand exists nowhere
			// else, and the metainfo's own list is re-merged on restore anyway.
			trackers: knownTrackerURLs
		)
	}

	public func metainfoForExport() -> TorrentMetainfo? { metainfo }

	private func persistState() async {
		lastPersist = Date()
		await environment.persist(state: persistentState())
	}

	// MARK: - Snapshot

	/// The most recent snapshot, readable from anywhere without awaiting.
	///
	/// Pulling a fresh snapshot through the actor is what the session used to
	/// do, and during a fast download the actor is saturated with peer traffic:
	/// actors are not FIFO, so the UI's request could be starved indefinitely
	/// and the torrent list simply stopped updating. The task now pushes a
	/// snapshot at the end of every tick instead.
	public nonisolated var cachedSnapshot: TorrentSnapshot? {
		snapshotCache.value
	}

	@discardableResult
	public func snapshot() async -> TorrentSnapshot {
		let trackerStatuses = await trackers.statuses
		let total = metainfo?.totalLength ?? 0
		let wanted = picker?.wantedBytes ?? total
		let remaining = picker?.remainingBytes ?? total
		let completed = wanted - remaining
		let progress: Double
		if metainfo == nil {
			progress = metadataDownload?.progress ?? 0
		} else {
			progress = wanted == 0 ? 0 : min(1, Double(completed) / Double(wanted))
		}

		var files: [FileSnapshot] = []
		if let metainfo, let picker {
			for file in metainfo.contentFiles {
				files.append(FileSnapshot(
					index: file.index,
					path: file.relativePath,
					length: file.length,
					bytesComplete: completedBytes(of: file, picker: picker, metainfo: metainfo),
					priority: filePriorities[file.index] ?? .normal
				))
			}
		}

		let peerSnapshots = peers.values
			.filter { $0.remotePeerID != nil }
			.map { $0.snapshot() }
			.sorted { $0.downloadRate > $1.downloadRate }

		let snapshot = TorrentSnapshot(
			infoHash: infoHash,
			name: displayName,
			status: status,
			progress: progress,
			downloadRate: downloadMeter.bytesPerSecond,
			uploadRate: uploadMeter.bytesPerSecond,
			downloadedBytes: downloadedBytes,
			uploadedBytes: uploadedBytes,
			totalBytes: total,
			wantedBytes: wanted,
			remainingBytes: remaining,
			connectedPeers: peerSnapshots.count,
			connectedSeeds: peers.values.count(where: { $0.isSeed }),
			knownPeers: candidatePeers.count + peers.count,
			pieceCount: metainfo?.pieceCount ?? 0,
			completedPieces: picker?.completedPieces ?? 0,
			addedAt: addedAt,
			completedAt: completedAt,
			savePath: downloadDirectory.path,
			isMagnetOnly: metainfo == nil,
			trackers: trackerStatuses,
			peers: peerSnapshots,
			files: files,
			webSeeds: webSeeds.statuses(),
			errorMessage: errorMessage
		)
		snapshotCache.value = snapshot
		return snapshot
	}

	/// Bytes of a file covered by verified pieces. Pieces straddling a file
	/// boundary are counted only for the part that falls inside the file.
	private func completedBytes(of file: TorrentFile, picker: PiecePicker, metainfo: TorrentMetainfo) -> Int64 {
		guard file.length > 0 else { return 0 }
		let first = Int(file.offset / Int64(metainfo.pieceLength))
		let last = Int((file.offset + file.length - 1) / Int64(metainfo.pieceLength))
		var total: Int64 = 0
		for index in first...last where picker.have[index] {
			let pieceRange = metainfo.byteRange(ofPiece: index)
			let overlap = min(pieceRange.upperBound, file.range.upperBound) - max(pieceRange.lowerBound, file.range.lowerBound)
			total += max(0, overlap)
		}
		return min(total, file.length)
	}
}


/// Lock-protected snapshot holder, written by the torrent actor and read by the
/// session and UI without an actor hop.
final class SnapshotCache: @unchecked Sendable {
	private let lock = NSLock()
	private var storage: TorrentSnapshot?

	var value: TorrentSnapshot? {
		get { lock.withLock { storage } }
		set { lock.withLock { storage = newValue } }
	}
}
