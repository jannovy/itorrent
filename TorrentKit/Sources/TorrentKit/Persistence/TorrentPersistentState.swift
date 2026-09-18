import Foundation

/// Everything needed to bring a torrent back after the app is killed, minus the
/// metainfo itself, which is stored alongside as a `.torrent` file.
public struct TorrentPersistentState: Codable, Sendable, Equatable {
	public var infoHashHex: String
	public var name: String
	/// Present only while the torrent is still magnet-only; once the metadata
	/// arrives it is written to disk and this becomes redundant.
	public var magnetURI: String?
	public var savePath: String
	public var addedAt: Date
	public var completedAt: Date?
	public var uploadedBytes: Int64
	public var downloadedBytes: Int64
	public var pieceCount: Int
	/// Resume data: the verified-piece bitfield.
	public var bitfield: Data
	public var isPaused: Bool
	public var filePriorities: [Int: Int]
	public var trackers: [String]

	public init(
		infoHashHex: String,
		name: String,
		magnetURI: String?,
		savePath: String,
		addedAt: Date,
		completedAt: Date?,
		uploadedBytes: Int64,
		downloadedBytes: Int64,
		pieceCount: Int,
		bitfield: Data,
		isPaused: Bool,
		filePriorities: [Int: Int],
		trackers: [String]
	) {
		self.infoHashHex = infoHashHex
		self.name = name
		self.magnetURI = magnetURI
		self.savePath = savePath
		self.addedAt = addedAt
		self.completedAt = completedAt
		self.uploadedBytes = uploadedBytes
		self.downloadedBytes = downloadedBytes
		self.pieceCount = pieceCount
		self.bitfield = bitfield
		self.isPaused = isPaused
		self.filePriorities = filePriorities
		self.trackers = trackers
	}

	public var infoHash: InfoHash? { InfoHash(hex: infoHashHex) }

	public var resumeBitfield: BitField? {
		guard pieceCount > 0, !bitfield.isEmpty else { return nil }
		return BitField(bytes: bitfield, bitCount: pieceCount)
	}
}

/// On-disk layout for the session:
///
/// ```
/// Application Support/iTorrent/
///   settings.json
///   dht-nodes.json
///   torrents/<info-hash>/state.json
///   torrents/<info-hash>/metainfo.torrent
/// Documents/Downloads/<torrent name>/…
/// ```
public struct SessionStore: Sendable {
	private let rootURL: URL

	private var manager: FileManager { .default }

	public init(rootURL: URL) {
		self.rootURL = rootURL
	}

	public static func defaultStore() -> SessionStore {
		let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		return SessionStore(rootURL: support.appendingPathComponent("iTorrent", isDirectory: true))
	}

	public var torrentsDirectory: URL { rootURL.appendingPathComponent("torrents", isDirectory: true) }
	private var settingsURL: URL { rootURL.appendingPathComponent("settings.json") }
	private var dhtNodesURL: URL { rootURL.appendingPathComponent("dht-nodes.json") }

	public func prepare() throws {
		try manager.createDirectory(at: torrentsDirectory, withIntermediateDirectories: true)
		var mutableRoot = rootURL
		var values = URLResourceValues()
		values.isExcludedFromBackup = true
		try? mutableRoot.setResourceValues(values)
	}

	private func directory(for infoHashHex: String) -> URL {
		torrentsDirectory.appendingPathComponent(infoHashHex, isDirectory: true)
	}

	// MARK: - Torrent state

	public func save(state: TorrentPersistentState) {
		let directory = directory(for: state.infoHashHex)
		try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		guard let data = try? encoder.encode(state) else { return }
		// Atomic write: a torn state.json on a kill would lose resume data.
		try? data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
	}

	public func saveMetainfo(_ metainfo: TorrentMetainfo, forInfoHashHex hex: String) {
		let directory = directory(for: hex)
		try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
		try? metainfo.torrentFileData().write(
			to: directory.appendingPathComponent("metainfo.torrent"),
			options: .atomic
		)
	}

	public func loadMetainfo(forInfoHashHex hex: String) -> TorrentMetainfo? {
		let url = directory(for: hex).appendingPathComponent("metainfo.torrent")
		guard let data = try? Data(contentsOf: url) else { return nil }
		return try? TorrentMetainfo(fileContents: data)
	}

	public func loadAllStates() -> [TorrentPersistentState] {
		guard let entries = try? manager.contentsOfDirectory(
			at: torrentsDirectory,
			includingPropertiesForKeys: nil
		) else { return [] }

		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return entries.compactMap { entry in
			let url = entry.appendingPathComponent("state.json")
			guard let data = try? Data(contentsOf: url) else { return nil }
			do {
				return try decoder.decode(TorrentPersistentState.self, from: data)
			} catch {
				// Losing a torrent silently is worse than a noisy log: the user
				// would just find it missing after a restart with no clue why.
				Log.session.error(
					"Unreadable resume state at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)"
				)
				return nil
			}
		}
		.sorted { $0.addedAt < $1.addedAt }
	}

	public func delete(infoHashHex: String) {
		try? manager.removeItem(at: directory(for: infoHashHex))
	}

	// MARK: - Settings and DHT

	public func loadSettings() -> SessionSettings? {
		guard let data = try? Data(contentsOf: settingsURL) else { return nil }
		return try? JSONDecoder().decode(SessionSettings.self, from: data)
	}

	public func save(settings: SessionSettings) {
		guard let data = try? JSONEncoder().encode(settings) else { return }
		try? data.write(to: settingsURL, options: .atomic)
	}

	public func loadDHTNodes() -> [PeerAddress] {
		guard let data = try? Data(contentsOf: dhtNodesURL),
		      let entries = try? JSONDecoder().decode([String].self, from: data)
		else { return [] }
		return entries.compactMap(PeerAddress.init(hostPortString:))
	}

	public func save(dhtNodes: [PeerAddress]) {
		let entries = dhtNodes.map(\.description)
		guard let data = try? JSONEncoder().encode(entries) else { return }
		try? data.write(to: dhtNodesURL, options: .atomic)
	}
}
