import Foundation

public enum SessionError: Error, LocalizedError {
	case duplicateTorrent(name: String)
	case storageUnavailable
	case unreadableTorrentFile

	public var errorDescription: String? {
		switch self {
		case let .duplicateTorrent(name): "'\(name)' has already been added."
		case .storageUnavailable: "The download folder could not be created."
		case .unreadableTorrentFile: "That file is not a valid .torrent."
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
	private let downloadRateLimiter: RateLimiter
	private let uploadRateLimiter: RateLimiter

	private var settings: SessionSettings
	private var tasks: [InfoHash: TorrentTask] = [:]
	private var snapshots: [InfoHash: TorrentSnapshot] = [:]
	private var order: [InfoHash] = []
	private var downloadDirectory: URL

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
		let connection = PeerConnection(
			incoming: incoming.connection,
			address: incoming.address,
			localPeerID: peerID
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
			address: incoming.address,
			handshake: handshake,
			channel: channel
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

	// MARK: - TorrentEnvironment

	public func listenPort() async -> UInt16 { listener.port }

	public func discoverPeersViaDHT(infoHash: InfoHash) async -> [PeerAddress] {
		guard settings.isDHTEnabled, await dht.isRunning else { return [] }
		return await dht.findPeers(infoHash: infoHash, announce: true)
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
