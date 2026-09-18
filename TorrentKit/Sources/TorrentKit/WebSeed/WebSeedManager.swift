import Foundation

/// What one web seed is doing, for the UI.
public struct WebSeedStatus: Sendable, Identifiable, Hashable {
	public let url: String
	public let isEnabled: Bool
	public let piecesInFlight: Int
	public let downloadedBytes: Int64
	public let failureCount: Int
	public let lastError: String?

	public var id: String { url }
}

/// Schedules piece fetches across a torrent's web seeds.
///
/// Owned by the `TorrentTask` actor and only ever touched from inside it, so it
/// needs no locking of its own. It decides *what* to fetch and remembers how
/// each seed has been behaving; the fetching itself happens in a detached task
/// so a slow HTTP server can never stall the torrent's tick.
final class WebSeedManager {

	/// Four at a time per seed: enough to keep a fast server busy across the
	/// round trip without turning one torrent into a flood of parallel
	/// requests. `httpMaximumConnectionsPerHost` keeps the sockets bounded.
	private static let maximumConcurrentPiecesPerSeed = 4
	/// A seed that keeps failing is almost always a dead or wrong URL.
	private static let maximumFailures = 5
	private static let initialBackoff: TimeInterval = 5
	private static let maximumBackoff: TimeInterval = 300

	private struct Seed {
		let client: WebSeedClient
		var piecesInFlight: Set<Int> = []
		var failureCount = 0
		var downloadedBytes: Int64 = 0
		var retryAfter = Date.distantPast
		var isDisabled = false
		var lastError: String?
	}

	private var seeds: [String: Seed] = [:]
	private var order: [String] = []

	private(set) var downloadedBytes: Int64 = 0

	var isEmpty: Bool { seeds.isEmpty }

	var hasCapacity: Bool {
		let now = Date()
		return seeds.values.contains { seed in
			!seed.isDisabled
				&& seed.retryAfter <= now
				&& seed.piecesInFlight.count < Self.maximumConcurrentPiecesPerSeed
		}
	}

	/// Rebuilds the seed list. Called once the metadata is known, since a
	/// magnet link's `ws` parameters arrive long before the file layout does.
	func configure(urls: [String], metainfo: TorrentMetainfo) {
		var seen = Set<String>()
		for url in urls {
			let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
			// Only HTTP(S). BEP 19 also allows FTP, which no client has served
			// this decade and URLSession will not fetch ranges from anyway.
			let scheme = trimmed.lowercased()
			guard scheme.hasPrefix("http://") || scheme.hasPrefix("https://") else { continue }

			if seeds[trimmed] == nil {
				seeds[trimmed] = Seed(client: WebSeedClient(baseURL: trimmed, metainfo: metainfo))
				order.append(trimmed)
			}
		}
	}

	/// The next seed that may start a piece, in rotation.
	func nextAvailableSeed() -> WebSeedClient? {
		let now = Date()
		for url in order {
			guard let seed = seeds[url],
			      !seed.isDisabled,
			      seed.retryAfter <= now,
			      seed.piecesInFlight.count < Self.maximumConcurrentPiecesPerSeed
			else { continue }
			return seed.client
		}
		return nil
	}

	func markStarted(piece index: Int, on url: String) {
		seeds[url]?.piecesInFlight.insert(index)
	}

	func markSucceeded(piece index: Int, byteCount: Int, on url: String) {
		guard var seed = seeds[url] else { return }
		seed.piecesInFlight.remove(index)
		seed.downloadedBytes += Int64(byteCount)
		// A success clears the slate: a seed that failed once because the
		// network dropped should not carry that towards a ban forever.
		seed.failureCount = 0
		seed.lastError = nil
		seeds[url] = seed
		downloadedBytes += Int64(byteCount)
	}

	func markFailed(piece index: Int, on url: String, error: String) {
		guard var seed = seeds[url] else { return }
		seed.piecesInFlight.remove(index)
		seed.failureCount += 1
		seed.lastError = error
		if seed.failureCount >= Self.maximumFailures {
			seed.isDisabled = true
			Log.torrent.warning("Web seed \(url, privacy: .public) disabled after \(seed.failureCount) failures")
		} else {
			let backoff = min(
				Self.maximumBackoff,
				Self.initialBackoff * pow(2, Double(seed.failureCount - 1))
			)
			seed.retryAfter = Date().addingTimeInterval(backoff)
		}
		seeds[url] = seed
	}

	/// Pieces every seed is currently fetching, so a restart can release them.
	func allPiecesInFlight() -> Set<Int> {
		seeds.values.reduce(into: Set<Int>()) { $0.formUnion($1.piecesInFlight) }
	}

	func reset() {
		for url in seeds.keys {
			seeds[url]?.piecesInFlight.removeAll()
		}
	}

	func statuses() -> [WebSeedStatus] {
		order.compactMap { url in
			guard let seed = seeds[url] else { return nil }
			return WebSeedStatus(
				url: url,
				isEnabled: !seed.isDisabled,
				piecesInFlight: seed.piecesInFlight.count,
				downloadedBytes: seed.downloadedBytes,
				failureCount: seed.failureCount,
				lastError: seed.lastError
			)
		}
	}
}
