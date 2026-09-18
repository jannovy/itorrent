import Foundation

public enum TorrentStatus: Sendable, Hashable {
	case queued
	case checkingFiles(progress: Double)
	case fetchingMetadata(progress: Double)
	case downloading
	case stalled
	case seeding
	case paused
	case finished
	case failed(String)

	public var isActive: Bool {
		switch self {
		case .downloading, .seeding, .stalled, .fetchingMetadata, .checkingFiles: true
		default: false
		}
	}

	public var isPaused: Bool {
		if case .paused = self { return true }
		return false
	}

	public var label: String {
		switch self {
		case .queued: "Queued"
		case .checkingFiles: "Checking"
		case .fetchingMetadata: "Metadata"
		case .downloading: "Downloading"
		case .stalled: "Stalled"
		case .seeding: "Seeding"
		case .paused: "Paused"
		case .finished: "Done"
		case .failed: "Error"
		}
	}
}

public struct PeerSnapshot: Sendable, Identifiable, Hashable {
	public let address: PeerAddress
	public let client: String
	public let progress: Double
	public let downloadRate: Double
	public let uploadRate: Double
	public let isChokingUs: Bool
	public let isInterestedInUs: Bool
	public let weAreChoking: Bool
	public let weAreInterested: Bool
	public let isIncoming: Bool
	public let supportsExtensions: Bool

	public var id: String { address.description }

	/// Compact flag string in the style desktop clients use.
	public var flags: String {
		var flags = ""
		flags += isIncoming ? "I" : "O"
		if !isChokingUs && weAreInterested { flags += "D" }
		if !weAreChoking && isInterestedInUs { flags += "U" }
		if supportsExtensions { flags += "E" }
		return flags
	}
}

public struct FileSnapshot: Sendable, Identifiable, Hashable {
	public let index: Int
	public let path: String
	public let length: Int64
	public let bytesComplete: Int64
	public let priority: PiecePriority

	public var id: Int { index }
	public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
	public var progress: Double { length == 0 ? 1 : min(1, Double(bytesComplete) / Double(length)) }
}

public struct TorrentSnapshot: Sendable, Identifiable, Hashable {
	public let infoHash: InfoHash
	public let name: String
	public let status: TorrentStatus
	public let progress: Double
	public let downloadRate: Double
	public let uploadRate: Double
	public let downloadedBytes: Int64
	public let uploadedBytes: Int64
	public let totalBytes: Int64
	public let wantedBytes: Int64
	public let remainingBytes: Int64
	public let connectedPeers: Int
	public let connectedSeeds: Int
	public let knownPeers: Int
	public let pieceCount: Int
	public let completedPieces: Int
	public let addedAt: Date
	public let completedAt: Date?
	public let savePath: String
	public let isMagnetOnly: Bool
	public let trackers: [TrackerStatus]
	public let peers: [PeerSnapshot]
	public let files: [FileSnapshot]
	public let webSeeds: [WebSeedStatus]
	public let errorMessage: String?

	public var id: InfoHash { infoHash }

	public var ratio: Double {
		downloadedBytes > 0 ? Double(uploadedBytes) / Double(downloadedBytes) : 0
	}

	/// Seconds until completion, or nil when it cannot be estimated.
	public var estimatedTimeRemaining: TimeInterval? {
		guard remainingBytes > 0, downloadRate > 1024 else { return nil }
		return Double(remainingBytes) / downloadRate
	}
}

/// Exponentially weighted transfer rate.
///
/// A plain "bytes since last tick" figure jumps around far too much to read on
/// screen; the smoothing factor is tuned so the number settles within a few
/// seconds but still reacts to a stall.
public struct RateMeter: Sendable {
	private static let smoothing = 0.35

	private var lastTotal: Int64 = 0
	private var lastSample = Date()
	public private(set) var bytesPerSecond: Double = 0

	public init() {}

	public mutating func update(total: Int64, now: Date = Date()) {
		let elapsed = now.timeIntervalSince(lastSample)
		guard elapsed >= 0.2 else { return }
		let delta = max(0, total - lastTotal)
		let instantaneous = Double(delta) / elapsed
		bytesPerSecond = bytesPerSecond == 0
			? instantaneous
			: bytesPerSecond * (1 - Self.smoothing) + instantaneous * Self.smoothing
		// The exponential tail decays towards zero forever; below a useful
		// resolution just call it idle rather than showing "1 byte/s".
		if bytesPerSecond < 64 { bytesPerSecond = 0 }
		lastTotal = total
		lastSample = now
	}

	public mutating func reset() {
		bytesPerSecond = 0
		lastTotal = 0
		lastSample = Date()
	}
}

public struct SessionSettings: Sendable, Codable, Equatable {
	public var listenPort: UInt16
	public var isDHTEnabled: Bool
	public var isPeerExchangeEnabled: Bool
	public var isLocalDiscoveryEnabled: Bool
	/// BEP 19 web seeds. On by default: a torrent whose swarm has died still
	/// downloads at full speed from the HTTP server that published it.
	public var areWebSeedsEnabled: Bool
	public var maximumPeersPerTorrent: Int
	public var maximumGlobalPeers: Int
	public var maximumActiveTorrents: Int
	/// Bytes per second; zero means unlimited.
	public var downloadLimit: Int
	public var uploadLimit: Int
	/// Stop seeding at this ratio; zero means seed indefinitely.
	public var seedRatioLimit: Double
	public var startTorrentsPaused: Bool
	/// Hold off the display's auto-lock while a torrent is actually
	/// transferring. iOS suspends the app once the screen sleeps, so this is
	/// the only way to keep a download running without leaving the phone
	/// propped up and tapped every few minutes.
	public var keepScreenAwakeWhileDownloading: Bool

	public static let `default` = SessionSettings(
		// Port 0 lets the OS pick; a fixed default port is a fingerprint and is
		// often blocked on mobile networks anyway.
		listenPort: 0,
		isDHTEnabled: true,
		isPeerExchangeEnabled: true,
		isLocalDiscoveryEnabled: false,
		areWebSeedsEnabled: true,
		maximumPeersPerTorrent: 50,
		maximumGlobalPeers: 200,
		maximumActiveTorrents: 5,
		downloadLimit: 0,
		uploadLimit: 0,
		seedRatioLimit: 0,
		startTorrentsPaused: false,
		keepScreenAwakeWhileDownloading: true
	)

	public init(
		listenPort: UInt16,
		isDHTEnabled: Bool,
		isPeerExchangeEnabled: Bool,
		isLocalDiscoveryEnabled: Bool,
		areWebSeedsEnabled: Bool,
		maximumPeersPerTorrent: Int,
		maximumGlobalPeers: Int,
		maximumActiveTorrents: Int,
		downloadLimit: Int,
		uploadLimit: Int,
		seedRatioLimit: Double,
		startTorrentsPaused: Bool,
		keepScreenAwakeWhileDownloading: Bool
	) {
		self.listenPort = listenPort
		self.isDHTEnabled = isDHTEnabled
		self.isPeerExchangeEnabled = isPeerExchangeEnabled
		self.isLocalDiscoveryEnabled = isLocalDiscoveryEnabled
		self.areWebSeedsEnabled = areWebSeedsEnabled
		self.maximumPeersPerTorrent = maximumPeersPerTorrent
		self.maximumGlobalPeers = maximumGlobalPeers
		self.maximumActiveTorrents = maximumActiveTorrents
		self.downloadLimit = downloadLimit
		self.uploadLimit = uploadLimit
		self.seedRatioLimit = seedRatioLimit
		self.startTorrentsPaused = startTorrentsPaused
		self.keepScreenAwakeWhileDownloading = keepScreenAwakeWhileDownloading
	}

	/// Decodes field by field, falling back to the default for anything the
	/// stored file predates.
	///
	/// The synthesised initialiser throws on a missing key, which would make
	/// every settings file written by an older build unreadable — and since the
	/// loader treats an unreadable file as "no settings", the user would
	/// silently lose all of them every time a field is added.
	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let fallback = SessionSettings.default

		// `try?` flattens the doubly-optional result, so one guard covers both
		// "key absent" and "value unreadable".
		func value<T: Decodable>(_ key: CodingKeys, _ default: T) -> T {
			guard let decoded = try? container.decodeIfPresent(T.self, forKey: key) else { return `default` }
			return decoded
		}

		listenPort = value(.listenPort, fallback.listenPort)
		isDHTEnabled = value(.isDHTEnabled, fallback.isDHTEnabled)
		isPeerExchangeEnabled = value(.isPeerExchangeEnabled, fallback.isPeerExchangeEnabled)
		isLocalDiscoveryEnabled = value(.isLocalDiscoveryEnabled, fallback.isLocalDiscoveryEnabled)
		areWebSeedsEnabled = value(.areWebSeedsEnabled, fallback.areWebSeedsEnabled)
		maximumPeersPerTorrent = value(.maximumPeersPerTorrent, fallback.maximumPeersPerTorrent)
		maximumGlobalPeers = value(.maximumGlobalPeers, fallback.maximumGlobalPeers)
		maximumActiveTorrents = value(.maximumActiveTorrents, fallback.maximumActiveTorrents)
		downloadLimit = value(.downloadLimit, fallback.downloadLimit)
		uploadLimit = value(.uploadLimit, fallback.uploadLimit)
		seedRatioLimit = value(.seedRatioLimit, fallback.seedRatioLimit)
		startTorrentsPaused = value(.startTorrentsPaused, fallback.startTorrentsPaused)
		keepScreenAwakeWhileDownloading = value(
			.keepScreenAwakeWhileDownloading,
			fallback.keepScreenAwakeWhileDownloading
		)
	}
}

/// Shared token bucket used to honour the user's speed limits.
public actor RateLimiter {
	private var bytesPerSecond: Int
	private var available: Double
	private var lastRefill = Date()

	public init(bytesPerSecond: Int) {
		self.bytesPerSecond = bytesPerSecond
		self.available = Double(bytesPerSecond)
	}

	public var isLimited: Bool { bytesPerSecond > 0 }

	public func setLimit(_ bytesPerSecond: Int) {
		self.bytesPerSecond = max(0, bytesPerSecond)
		available = min(available, Double(self.bytesPerSecond))
	}

	/// Waits until `count` bytes may be transferred.
	public func consume(_ count: Int) async {
		guard bytesPerSecond > 0 else { return }
		while true {
			refill()
			if available >= Double(count) {
				available -= Double(count)
				return
			}
			let deficit = Double(count) - available
			let waitSeconds = min(2.0, deficit / Double(bytesPerSecond))
			try? await Task.sleep(nanoseconds: UInt64(max(0.01, waitSeconds) * 1_000_000_000))
		}
	}

	/// Non-blocking variant for deciding how much to request next.
	public func take(upTo count: Int) -> Int {
		guard bytesPerSecond > 0 else { return count }
		refill()
		let granted = min(Double(count), available)
		available -= granted
		return Int(granted)
	}

	private func refill() {
		let now = Date()
		let elapsed = now.timeIntervalSince(lastRefill)
		guard elapsed > 0 else { return }
		lastRefill = now
		available = min(Double(bytesPerSecond), available + elapsed * Double(bytesPerSecond))
	}
}
