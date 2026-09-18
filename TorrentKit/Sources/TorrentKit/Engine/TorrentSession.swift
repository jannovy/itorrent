import Foundation

public enum SessionError: Error, LocalizedError {
	case duplicateTorrent(name: String)
	case storageUnavailable
	case unreadableTorrentFile
	case downloadFolderUnusable(path: String, reason: String)

	public var errorDescription: String? {
		switch self {
		case let .duplicateTorrent(name): "'\(name)' has already been added."
		case .storageUnavailable: "The download folder could not be created."
		case .unreadableTorrentFile: "That file is not a valid .torrent."
		case let .downloadFolderUnusable(path, reason): "'\(path)' cannot be used for downloads: \(reason)"
		}
	}
}

/// The top-level engine: owns the peer id, the listening socket, the DHT node,
/// global settings and every running torrent.
public actor TorrentSession: TorrentEnvironment {

	public nonisolated let peerID: PeerID

	private let store: SessionStore
	private let dht: DHT
	private let listener = PeerListener()
	/// µTP shares the TCP listener's port number, so one announced address
	/// works for both transports.
	private let utp = UTPSocket()
	private let downloadRateLimiter: RateLimiter
	private let uploadRateLimiter: RateLimiter

	private var settings: SessionSettings
	private var tasks: [InfoHash: TorrentTask] = [:]
	private var snapshots: [InfoHash: TorrentSnapshot] = [:]
	private var order: [InfoHash] = []
	private var downloadDirectory: URL

	/// Readable without entering the actor, because an inbound encrypted
	/// handshake has to be matched against every torrent we hold *while* the
	/// connection's serial queue is parsing it.
	private let infoHashRegistry = InfoHashRegistry()

	private var listenerTask: Task<Void, Never>?
	private var publishTask: Task<Void, Never>?
	private var dhtMaintenanceTask: Task<Void, Never>?
	private var observers: [UUID: AsyncStream<[TorrentSnapshot]>.Continuation] = [:]
	private var boundPort: UInt16 = 0
	private var isRunning = false

	public init(store: SessionStore = .defaultStore(), downloadDirectory: URL? = nil) {
		self.store = store
		self.peerID = .random()
		let loaded = store.loadSettings() ?? .default
		self.settings = loaded
		self.dht = DHT()
		self.downloadRateLimiter = RateLimiter(bytesPerSecond: loaded.downloadLimit)
		self.uploadRateLimiter = RateLimiter(bytesPerSecond: loaded.uploadLimit)

		let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
		self.downloadDirectory = downloadDirectory ?? documents.appendingPathComponent("Downloads", isDirectory: true)
	}

	// MARK: - Lifecycle

	public func start() async {
		guard !isRunning else { return }
		isRunning = true

		do {
			try store.prepare()
			try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
		} catch {
			Log.session.error("Could not prepare storage: \(error.localizedDescription, privacy: .public)")
		}
		Log.session.info("Starting session, peer id \(self.peerID.clientName, privacy: .public), downloads at \(self.downloadDirectory.path, privacy: .public)")

		startListener()
		// Torrents must not be restored before we know the port, or every one
		// of them announces zero and stays unreachable for the whole session.
		let port = await listener.waitUntilReady(timeout: 5)
		if port == 0 {
			Log.session.error("Listener did not bind; inbound peer connections will not work")
		} else {
			Log.session.info("Listening for peers on port \(port)")
		}

		startUTPIfEnabled(port: port)
		await startDHTIfEnabled()
		await restorePersistedTorrents()
		startPublishing()
	}

	public func stop() async {
		isRunning = false
		listenerTask?.cancel()
		publishTask?.cancel()
		dhtMaintenanceTask?.cancel()
		listener.stop()

		utp.stop()

		let exported = await dht.exportNodes()
		if !exported.isEmpty { store.save(dhtNodes: exported) }
		await dht.stop()

		for task in tasks.values {
			let state = await task.persistentState()
			store.save(state: state)
			await task.shutdown(deleteFiles: false)
		}
		for continuation in observers.values { continuation.finish() }
		observers.removeAll()
	}

	/// Called when iOS suspends the app: flush state so nothing is lost if the
	/// process is killed while in the background.
	public func prepareForBackground() async {
		for task in tasks.values {
			store.save(state: await task.persistentState())
		}
	}

	/// Called when the app returns to the foreground.
	///
	/// Everything network-shaped died while we were suspended, so trackers get
	/// another chance immediately rather than after a backoff they did nothing
	/// to deserve.
	public func recoverFromBackground() async {
		guard isRunning else { return }
		Log.session.info("Returning to foreground; re-announcing \(self.tasks.count) torrent(s)")
		for task in tasks.values {
			await task.recoverFromSuspension()
		}
	}

	private func startListener() {
		let stream = listener.start(preferredPort: settings.listenPort)
		listenerTask = Task { [weak self] in
			for await incoming in stream {
				guard let self else { return }
				Task { await self.accept(incoming) }
			}
		}
	}

	private func startUTPIfEnabled(port: UInt16) {
		guard settings.isUTPEnabled, port > 0 else { return }
		do {
			try utp.start(port: port)
			Log.session.info("uTP listening on UDP port \(self.utp.localPort)")
		} catch {
			// Not fatal: TCP still works, and the alternative is refusing to
			// start over a transport that is an optimisation.
			Log.session.error("Could not start uTP: \(error.localizedDescription, privacy: .public)")
			return
		}

		let socketQueue = utp.queue
		utp.onIncomingConnection = { [weak self] connection in
			guard let self else { return }
			let transport = UTPTransport(connection: connection, socketQueue: socketQueue)
			let address = connection.remote
			Task { await self.accept(transport: transport, address: address, label: "utp", usesUTP: true) }
		}
	}

	private func startDHTIfEnabled() async {
		guard settings.isDHTEnabled else { return }
		// Bind the DHT to its own UDP port; sharing the TCP port number is
		// conventional but not required, and port 0 lets the OS choose.
		try? await dht.start(port: 0, announcingPeerPort: listener.port)

		let saved = store.loadDHTNodes()
		dhtMaintenanceTask = Task { [weak self] in
			guard let self else { return }
			await self.dht.bootstrap(savedNodes: saved)
			while !Task.isCancelled {
				try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
				guard !Task.isCancelled else { return }
				await self.persistDHTNodes()
				await self.dht.bootstrap()
			}
		}
	}

	private func persistDHTNodes() async {
		let nodes = await dht.exportNodes()
		guard !nodes.isEmpty else { return }
		store.save(dhtNodes: nodes)
	}

	private func startPublishing() {
		publishTask = Task { [weak self] in
			while !Task.isCancelled {
				await self?.publishSnapshots()
				try? await Task.sleep(nanoseconds: 1_000_000_000)
			}
		}
	}

	// MARK: - Inbound connections

	private func accept(_ incoming: PeerListener.Incoming) async {
		await accept(
			transport: TCPTransport(accepted: incoming.connection),
			address: incoming.address,
			label: "tcp"
		)
	}

	private func accept(
		transport: PeerTransport,
		address: PeerAddress,
		label: String,
		usesUTP: Bool = false
	) async {
		let registry = infoHashRegistry
		let connection = PeerConnection(
			transport: transport,
			address: address,
			role: .incoming,
			localPeerID: peerID,
			encryption: settings.encryptionPolicy,
			knownInfoHashes: { registry.all },
			queueLabel: "itorrent.peer.in.\(label).\(address.description)"
		)
		let channel = PeerEventChannel(connection.start())

		// The first event is the peer's handshake, which tells us which torrent
		// this connection is for. Anything else means a broken or hostile peer.
		guard case let .handshake(handshake)? = await channel.next() else {
			connection.close(reason: .protocolViolation("No handshake"))
			return
		}
		guard let task = tasks[handshake.infoHash] else {
			connection.close(reason: .protocolViolation("Unknown info-hash"))
			return
		}
		await task.adopt(
			incoming: connection,
			address: address,
			handshake: handshake,
			channel: channel,
			usesUTP: usesUTP
		)
	}

	// MARK: - Adding and removing torrents

	@discardableResult
	public func add(source: TorrentSource, startImmediately: Bool? = nil) async throws -> InfoHash {
		let infoHash = source.infoHash
		guard tasks[infoHash] == nil else {
			throw SessionError.duplicateTorrent(name: source.displayName)
		}

		try? FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)

		let task = TorrentTask(
			source: source,
			downloadDirectory: downloadDirectory,
			environment: self,
			listenPort: listener.port
		)
		tasks[infoHash] = task
		order.append(infoHash)
		infoHashRegistry.insert(infoHash)

		if case let .metainfo(metainfo) = source {
			store.saveMetainfo(metainfo, forInfoHashHex: infoHash.hex)
		}
		store.save(state: await task.persistentState())

		let shouldStart = startImmediately ?? !settings.startTorrentsPaused
		if shouldStart {
			await task.start()
			await seedInitialPeers(for: task, infoHash: infoHash)
		} else {
			await task.pause()
			await task.prepareStorageOnly(resumeBitfield: nil)
		}

		await publishSnapshots()
		return infoHash
	}

	@discardableResult
	public func add(magnetLink: String) async throws -> InfoHash {
		try await add(source: .magnet(try MagnetURI(string: magnetLink)))
	}

	@discardableResult
	public func add(torrentFileAt url: URL) async throws -> InfoHash {
		// Files handed over by the document picker live outside our sandbox.
		let needsScope = url.startAccessingSecurityScopedResource()
		defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

		guard let data = try? Data(contentsOf: url),
		      let metainfo = try? TorrentMetainfo(fileContents: data)
		else { throw SessionError.unreadableTorrentFile }
		return try await add(source: .metainfo(metainfo))
	}

	public func remove(infoHash: InfoHash, deleteFiles: Bool) async {
		guard let task = tasks.removeValue(forKey: infoHash) else { return }
		order.removeAll { $0 == infoHash }
		infoHashRegistry.remove(infoHash)
		snapshots[infoHash] = nil
		await task.shutdown(deleteFiles: deleteFiles)
		store.delete(infoHashHex: infoHash.hex)
		await publishSnapshots()
	}

	public func pause(infoHash: InfoHash) async {
		await tasks[infoHash]?.pause()
		await publishSnapshots()
	}

	public func resume(infoHash: InfoHash) async {
		guard let task = tasks[infoHash] else { return }
		await task.resume()
		await seedInitialPeers(for: task, infoHash: infoHash)
		await publishSnapshots()
	}

	public func pauseAll() async {
		for task in tasks.values { await task.pause() }
		await publishSnapshots()
	}

	public func resumeAll() async {
		for infoHash in order { await resume(infoHash: infoHash) }
	}

	/// Hosts banned for sending corrupt data, per torrent.
	func bannedHosts(for infoHash: InfoHash) async -> Set<String> {
		await tasks[infoHash]?.bannedHosts ?? []
	}

	public func recheck(infoHash: InfoHash) async {
		await tasks[infoHash]?.recheck()
		await publishSnapshots()
	}

	public func forceAnnounce(infoHash: InfoHash) async {
		await tasks[infoHash]?.forceAnnounce()
	}

	public func setPriority(_ priority: PiecePriority, forFileAt index: Int, in infoHash: InfoHash) async {
		await tasks[infoHash]?.setPriority(priority, forFileAt: index)
	}

	/// Adds a peer by address, bypassing discovery. Used for local peer
	/// discovery, `x.pe` magnet hints and tests.
	public func addPeer(_ address: PeerAddress, to infoHash: InfoHash) async {
		await tasks[infoHash]?.addCandidates([address])
	}

	public func addTracker(_ url: String, to infoHash: InfoHash) async {
		await tasks[infoHash]?.addTracker(url)
	}

	/// Exports a `.torrent` file for a torrent whose metadata we now hold,
	/// including ones that started life as a magnet link.
	public func exportTorrentFile(infoHash: InfoHash) async -> Data? {
		await tasks[infoHash]?.metainfoForExport()?.torrentFileData()
	}

	/// Kick-starts discovery so a fresh torrent does not wait a full tick.
	private func seedInitialPeers(for task: TorrentTask, infoHash: InfoHash) async {
		Task { [weak self] in
			guard let self else { return }
			await task.forceAnnounce()
			if await self.settings.isDHTEnabled {
				let peers = await self.discoverPeersViaDHT(infoHash: infoHash)
				await task.addCandidates(peers)
			}
		}
	}

	private func restorePersistedTorrents() async {
		let states = store.loadAllStates()
		Log.session.info("Restoring \(states.count) persisted torrent(s)")
		for state in states {
			guard let infoHash = state.infoHash, tasks[infoHash] == nil else { continue }

			let source: TorrentSource
			if let metainfo = store.loadMetainfo(forInfoHashHex: state.infoHashHex) {
				source = .metainfo(metainfo)
			} else if let magnetURI = state.magnetURI, let magnet = try? MagnetURI(string: magnetURI) {
				source = .magnet(magnet)
			} else {
				Log.session.error("No metainfo or magnet for \(state.infoHashHex, privacy: .public); skipping")
				continue
			}

			let task = TorrentTask(
				source: source,
				downloadDirectory: URL(fileURLWithPath: state.savePath),
				environment: self,
				listenPort: listener.port,
				restoredState: state
			)
			tasks[infoHash] = task
			order.append(infoHash)
			infoHashRegistry.insert(infoHash)

			Log.session.info("Restored \(state.name, privacy: .public) paused=\(state.isPaused)")
			if state.isPaused {
				// Paused torrents still need storage so the list shows real
				// progress rather than zero until the user resumes.
				await task.prepareStorageOnly(resumeBitfield: state.resumeBitfield)
			} else {
				await task.start(resumeBitfield: state.resumeBitfield, needsCheck: false)
				await seedInitialPeers(for: task, infoHash: infoHash)
			}
		}
		await publishSnapshots()
	}

	// MARK: - Settings

	public func currentSettings() async -> SessionSettings { settings }

	public func update(settings newValue: SessionSettings) async {
		let previous = settings
		settings = newValue
		store.save(settings: newValue)

		await downloadRateLimiter.setLimit(newValue.downloadLimit)
		await uploadRateLimiter.setLimit(newValue.uploadLimit)

		if previous.isDHTEnabled != newValue.isDHTEnabled {
			if newValue.isDHTEnabled {
				await startDHTIfEnabled()
			} else {
				dhtMaintenanceTask?.cancel()
				await dht.stop()
			}
		}
		if previous.listenPort != newValue.listenPort {
			listenerTask?.cancel()
			listener.stop()
			startListener()
			let port = await listener.waitUntilReady(timeout: 5)
			await propagateListenPort(port)
		}
	}

	/// Pushes the real port into every torrent and re-announces, so trackers
	/// stop handing out an address nobody can reach.
	private func propagateListenPort(_ port: UInt16) async {
		guard port > 0 else { return }
		for task in tasks.values {
			await task.setListenPort(port)
		}
	}

	// MARK: - Snapshots

	public func allSnapshots() async -> [TorrentSnapshot] {
		order.compactMap { snapshots[$0] }
	}

	/// A stream of the full torrent list, published about once a second.
	public func snapshotStream() -> AsyncStream<[TorrentSnapshot]> {
		AsyncStream { continuation in
			let id = UUID()
			observers[id] = continuation
			continuation.onTermination = { [weak self] _ in
				Task { await self?.removeObserver(id) }
			}
			continuation.yield(order.compactMap { snapshots[$0] })
		}
	}

	private func removeObserver(_ id: UUID) {
		observers[id] = nil
	}

	private func publishSnapshots() async {
		var updated: [InfoHash: TorrentSnapshot] = [:]
		for (infoHash, task) in tasks {
			// Read the cache rather than awaiting the torrent actor: a busy
			// torrent must never be able to stall the whole UI.
			if let cached = task.cachedSnapshot {
				updated[infoHash] = cached
			} else {
				updated[infoHash] = await task.snapshot()
			}
		}
		snapshots = updated

		let list = order.compactMap { snapshots[$0] }
		Log.session.debug("Publishing \(list.count) snapshot(s) to \(self.observers.count) observer(s)")
		for continuation in observers.values { continuation.yield(list) }
	}

	// MARK: - Aggregate statistics

	public struct Statistics: Sendable {
		public var downloadRate: Double = 0
		public var uploadRate: Double = 0
		public var activeTorrents: Int = 0
		public var totalTorrents: Int = 0
		public var connectedPeers: Int = 0
		public var dhtNodes: Int = 0
		public var listenPort: UInt16 = 0

		public init() {}
	}

	public func statistics() async -> Statistics {
		var statistics = Statistics()
		for snapshot in snapshots.values {
			statistics.downloadRate += snapshot.downloadRate
			statistics.uploadRate += snapshot.uploadRate
			statistics.connectedPeers += snapshot.connectedPeers
			if snapshot.status.isActive { statistics.activeTorrents += 1 }
		}
		statistics.totalTorrents = tasks.count
		statistics.dhtNodes = await dht.nodeCount
		statistics.listenPort = listener.port
		return statistics
	}

	public var downloadFolder: URL { downloadDirectory }

	/// Chooses where newly added torrents are saved.
	///
	/// Torrents already running keep the folder they were added with. Their
	/// data is there, and silently moving gigabytes because a preference
	/// changed is not something to do behind someone's back.
	///
	/// The folder is written to before it is accepted: a location picked from
	/// the Files app can be on a share that is gone, or read-only, and finding
	/// that out when the first piece completes means a torrent failing for
	/// reasons the user cannot connect to what they just did.
	public func setDownloadDirectory(_ url: URL) throws {
		let manager = FileManager.default
		do {
			try manager.createDirectory(at: url, withIntermediateDirectories: true)
		} catch {
			throw SessionError.downloadFolderUnusable(path: url.path, reason: error.localizedDescription)
		}

		let probe = url.appendingPathComponent(".itorrent-write-test")
		do {
			try Data([0]).write(to: probe, options: .atomic)
			try? manager.removeItem(at: probe)
		} catch {
			throw SessionError.downloadFolderUnusable(path: url.path, reason: "it is not writable")
		}

		downloadDirectory = url
		Log.session.info("Downloads now go to \(url.path, privacy: .public)")
	}

	// MARK: - TorrentEnvironment

	public func listenPort() async -> UInt16 { listener.port }

	public func discoverPeersViaDHT(infoHash: InfoHash) async -> [PeerAddress] {
		guard settings.isDHTEnabled, await dht.isRunning else { return [] }
		return await dht.findPeers(infoHash: infoHash, announce: true)
	}

	public func utpTransport(to address: PeerAddress) async -> PeerTransport? {
		guard settings.isUTPEnabled, utp.localPort > 0 else { return nil }
		return UTPTransport(socket: utp, address: address)
	}

	public func downloadLimiter() async -> RateLimiter { downloadRateLimiter }

	public func uploadLimiter() async -> RateLimiter { uploadRateLimiter }

	public func torrentDidChange(infoHash: InfoHash) async {
		guard let snapshot = tasks[infoHash]?.cachedSnapshot else { return }
		snapshots[infoHash] = snapshot
	}

	public func persist(state: TorrentPersistentState) async {
		store.save(state: state)
	}

	/// A magnet link has resolved; writing the metadata now means the next
	/// launch starts as an ordinary torrent instead of refetching it.
	public func persist(metainfo: TorrentMetainfo) async {
		store.saveMetainfo(metainfo, forInfoHashHex: metainfo.infoHash.hex)
	}
}

/// The set of torrents the session is running, readable from any queue.
///
/// An encrypted handshake hides the info-hash behind a hash of the shared
/// secret, so the only way to tell which torrent an inbound peer wants is to
/// try them all — on the connection's own queue, while it is mid-handshake.
/// Awaiting the session actor from there would deadlock the framing.
final class InfoHashRegistry: @unchecked Sendable {
	private let lock = NSLock()
	private var storage: Set<InfoHash> = []

	var all: [InfoHash] { lock.withLock { Array(storage) } }

	func insert(_ infoHash: InfoHash) { lock.withLock { _ = storage.insert(infoHash) } }
	func remove(_ infoHash: InfoHash) { lock.withLock { _ = storage.remove(infoHash) } }
}
