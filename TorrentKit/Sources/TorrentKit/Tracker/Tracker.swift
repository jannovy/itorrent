import Foundation

public enum AnnounceEvent: String, Sendable {
	case started
	case stopped
	case completed
	case periodic = ""
}

public struct AnnounceRequest: Sendable {
	public let infoHash: InfoHash
	public let peerID: PeerID
	public let port: UInt16
	public let uploaded: Int64
	public let downloaded: Int64
	public let left: Int64
	public let event: AnnounceEvent
	public let numberWanted: Int
	/// Stable per-session random key so trackers can recognise us across IP changes.
	public let key: UInt32
	/// Advertises MSE support, which some trackers use to pair us with peers
	/// that also speak it.
	public let supportsEncryption: Bool

	public init(
		infoHash: InfoHash,
		peerID: PeerID,
		port: UInt16,
		uploaded: Int64,
		downloaded: Int64,
		left: Int64,
		event: AnnounceEvent,
		numberWanted: Int = 80,
		key: UInt32,
		supportsEncryption: Bool = false
	) {
		self.infoHash = infoHash
		self.peerID = peerID
		self.port = port
		self.uploaded = uploaded
		self.downloaded = downloaded
		self.left = left
		self.event = event
		self.numberWanted = numberWanted
		self.supportsEncryption = supportsEncryption
		self.key = key
	}
}

public struct AnnounceResponse: Sendable {
	public var interval: TimeInterval
	public var minimumInterval: TimeInterval?
	public var seeders: Int?
	public var leechers: Int?
	public var peers: [PeerAddress]
	public var warning: String?
	public var trackerID: String?

	public init(
		interval: TimeInterval,
		minimumInterval: TimeInterval? = nil,
		seeders: Int? = nil,
		leechers: Int? = nil,
		peers: [PeerAddress] = [],
		warning: String? = nil,
		trackerID: String? = nil
	) {
		self.interval = interval
		self.minimumInterval = minimumInterval
		self.seeders = seeders
		self.leechers = leechers
		self.peers = peers
		self.warning = warning
		self.trackerID = trackerID
	}
}

public enum TrackerError: Error, LocalizedError {
	case unsupportedScheme(String)
	case invalidURL(String)
	case httpStatus(Int)
	case malformedResponse
	case rejected(String)
	case timedOut
	case interrupted

	public var errorDescription: String? {
		switch self {
		case let .unsupportedScheme(scheme): "Unsupported tracker scheme '\(scheme)'."
		case let .invalidURL(url): "Invalid tracker URL '\(url)'."
		case let .httpStatus(code): "Tracker returned HTTP \(code)."
		case .malformedResponse: "The tracker response could not be parsed."
		case let .rejected(reason): reason
		case .timedOut: "The tracker did not respond."
		case .interrupted: "The connection was interrupted."
		}
	}
}

/// Turns any error into something worth showing a person.
///
/// Raw `Error` descriptions leak type names — a torn-down connection surfaced
/// as "The operation couldn't be completed. (Swift.CancellationError error 1.)",
/// which tells the user nothing about which tracker failed or why.
public func describeTrackerError(_ error: any Error) -> String {
	if error is CancellationError { return "The announce was interrupted." }
	if let timeout = error as? TimeoutError { return timeout.localizedDescription }
	if let tracker = error as? TrackerError { return tracker.errorDescription ?? "Tracker error." }
	if let urlError = error as? URLError {
		switch urlError.code {
		case .notConnectedToInternet: return "No internet connection."
		case .timedOut: return "The tracker did not respond."
		case .cannotFindHost, .cannotConnectToHost: return "The tracker host is unreachable."
		case .networkConnectionLost: return "The network connection was lost."
		default: return urlError.localizedDescription
		}
	}
	if let localized = error as? LocalizedError, let description = localized.errorDescription {
		return description
	}
	return error.localizedDescription
}

public protocol TrackerClient: Sendable {
	var url: String { get }
	func announce(_ request: AnnounceRequest) async throws -> AnnounceResponse
}

public enum TrackerFactory {
	public static func make(url: String) throws -> TrackerClient {
		guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased() else {
			throw TrackerError.invalidURL(url)
		}
		switch scheme {
		case "http", "https":
			return HTTPTracker(url: url)
		case "udp":
			guard let host = parsed.host else { throw TrackerError.invalidURL(url) }
			return UDPTracker(url: url, host: host, port: UInt16(parsed.port ?? 80))
		default:
			// wss:// (WebTorrent) trackers need a browser-style WebRTC stack.
			throw TrackerError.unsupportedScheme(scheme)
		}
	}
}
