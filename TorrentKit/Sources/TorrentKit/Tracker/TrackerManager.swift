import Foundation

public struct TrackerStatus: Sendable, Identifiable, Hashable {
	public enum State: Sendable, Hashable {
		case idle
		case announcing
		case working
		case failed(String)
		case unsupported(String)

		public var isFailure: Bool {
			if case .failed = self { return true }
			if case .unsupported = self { return true }
			return false
		}
	}

	public let url: String
	public let tier: Int
	public var state: State = .idle
	public var seeders: Int?
	public var leechers: Int?
	public var peersReturned: Int = 0
	public var lastAnnounce: Date?
	public var nextAnnounce: Date?
	public var message: String?

	public var id: String { url }

	public var host: String {
		URL(string: url)?.host ?? url
	}
}

/// Drives announces for one torrent across its tracker tiers.
///
/// BEP 12 describes trying tiers in order and stopping at the first success.
/// We announce to every tier in parallel instead: on public swarms the extra
/// peers are worth far more than the saved requests, and tier order is
/// preserved only as a display detail.
public actor TrackerManager {
	public struct Statistics: Sendable {
		public var uploaded: Int64
		public var downloaded: Int64
		public var left: Int64

		public init(uploaded: Int64, downloaded: Int64, left: Int64) {
			self.uploaded = uploaded
			self.downloaded = downloaded
			self.left = left
		}
	}

	private struct Entry {
		let client: TrackerClient?
		var status: TrackerStatus
		var failureCount = 0
		var announceStartedAt: Date?

		/// An announce is only considered in flight while it is plausibly still
		/// running. Without the deadline a single wedged request would leave the
		/// flag set forever and the tracker would never be retried.
		func isAnnouncing(now: Date, staleAfter: TimeInterval) -> Bool {
			guard let announceStartedAt else { return false }
			return now.timeIntervalSince(announceStartedAt) < staleAfter
		}
	}

	/// No tracker gets to hold the announce cycle open longer than this.
	private let announceTimeout: TimeInterval
	/// An announce we abandoned ourselves is retried promptly.
	private static let interruptedRetryDelay: TimeInterval = 20

	/// Errors that mean "we stopped listening", not "this tracker is broken".
	private static func isInterruption(_ error: any Error) -> Bool {
		if error is CancellationError { return true }
		if case TrackerError.interrupted = error { return true }
		return false
	}

	private let infoHash: InfoHash
	private let peerID: PeerID
	private let key = UInt32.random(in: .min ... .max)
	private var listenPort: UInt16
	private var entries: [String: Entry] = [:]
	private var order: [String] = []
	private var hasSentStarted = false

	public init(
		infoHash: InfoHash,
		peerID: PeerID,
		listenPort: UInt16,
		tiers: [[String]],
		announceTimeout: TimeInterval = 30
	) {
		self.infoHash = infoHash
		self.peerID = peerID
		self.listenPort = listenPort
		self.announceTimeout = announceTimeout
		for (tierIndex, tier) in tiers.enumerated() {
			for url in tier {
				guard let (key, entry) = Self.makeEntry(url: url, tier: tierIndex), entries[key] == nil else { continue }
				entries[key] = entry
				order.append(key)
			}
		}
	}

	/// Test seam: builds a manager around pre-made clients so a deliberately
	/// misbehaving tracker can be injected.
	init(
		infoHash: InfoHash,
		peerID: PeerID,
		listenPort: UInt16,
		clients: [(url: String, client: TrackerClient?)],
		announceTimeout: TimeInterval
	) {
		self.infoHash = infoHash
		self.peerID = peerID
		self.listenPort = listenPort
		self.announceTimeout = announceTimeout
		for (url, client) in clients {
			entries[url] = Entry(client: client, status: TrackerStatus(url: url, tier: 0))
			order.append(url)
		}
	}

	public var statuses: [TrackerStatus] {
		order.compactMap { entries[$0]?.status }
	}

	public var trackerURLs: [String] { order }

	public func setListenPort(_ port: UInt16) {
		listenPort = port
	}

	public func add(urls: [String], tier: Int = 0) {
		for url in urls { insert(url: url, tier: tier) }
	}

	public func remove(url: String) {
		entries[url] = nil
		order.removeAll { $0 == url }
	}

	private func insert(url: String, tier: Int) {
		guard let (key, entry) = Self.makeEntry(url: url, tier: tier), entries[key] == nil else { return }
		entries[key] = entry
		order.append(key)
	}

	/// Static so it can be used from the (non-isolated) initialiser as well as
	/// from actor-isolated code.
	private static func makeEntry(url: String, tier: Int) -> (String, Entry)? {
		let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }

		var status = TrackerStatus(url: trimmed, tier: tier)
		var client: TrackerClient?
		do {
			client = try TrackerFactory.make(url: trimmed)
		} catch {
			status.state = .unsupported(error.localizedDescription)
			status.message = error.localizedDescription
		}
		return (trimmed, Entry(client: client, status: status))
	}

	/// Announces to every tracker whose interval has elapsed and returns the
	/// union of the peers they reported.
	@discardableResult
	public func announce(
		event: AnnounceEvent,
		statistics: Statistics,
		force: Bool = false
	) async -> [PeerAddress] {
		let now = Date()
		var effectiveEvent = event
		if event == .periodic, !hasSentStarted {
			effectiveEvent = .started
		}
		if effectiveEvent == .started { hasSentStarted = true }

		let staleAfter = announceTimeout * 2
		let due = order.filter { url in
			guard let entry = entries[url], entry.client != nil,
			      !entry.isAnnouncing(now: now, staleAfter: staleAfter)
			else { return false }
			if force || effectiveEvent != .periodic { return true }
			guard let next = entry.status.nextAnnounce else { return true }
			return next <= now
		}
		guard !due.isEmpty else { return [] }

		for url in due {
			entries[url]?.announceStartedAt = now
			entries[url]?.status.state = .announcing
		}

		let request = AnnounceRequest(
			infoHash: infoHash,
			peerID: peerID,
			port: listenPort,
			uploaded: statistics.uploaded,
			downloaded: statistics.downloaded,
			left: statistics.left,
			event: effectiveEvent,
			key: key
		)

		let clients = due.compactMap { url in entries[url]?.client.map { (url, $0) } }

		let results = await withTaskGroup(of: (String, Result<AnnounceResponse, Error>).self) { group in
			let timeout = announceTimeout
			for (url, client) in clients {
				group.addTask {
					do {
						// The timeout is the backstop that keeps one unreachable
						// tracker from holding up every other tracker's result.
						let response = try await withTimeout(seconds: timeout) {
							try await client.announce(request)
						}
						return (url, .success(response))
					} catch {
						return (url, .failure(error))
					}
				}
			}
			var collected: [(String, Result<AnnounceResponse, Error>)] = []
			for await result in group { collected.append(result) }
			return collected
		}

		var peers: Set<PeerAddress> = []
		for (url, result) in results {
			guard var entry = entries[url] else { continue }
			entry.announceStartedAt = nil
			entry.status.lastAnnounce = Date()

			switch result {
			case let .success(response):
				entry.failureCount = 0
				entry.status.state = .working
				entry.status.seeders = response.seeders
				entry.status.leechers = response.leechers
				entry.status.peersReturned = response.peers.count
				entry.status.message = response.warning
				entry.status.nextAnnounce = Date().addingTimeInterval(response.interval)
				peers.formUnion(response.peers.filter(\.isRoutable))

			case let .failure(error):
				let description = describeTrackerError(error)
				Log.tracker.error(
					"Announce to \(entry.status.host, privacy: .public) failed: \(String(describing: type(of: error)), privacy: .public) — \(description, privacy: .public)"
				)

				if Self.isInterruption(error) {
					// Our side gave up, not the tracker's. iOS tears down every
					// socket when it suspends the app, so a single screen lock
					// would otherwise fail all trackers at once and sideline
					// each of them for an exponential backoff it never earned.
					entry.status.state = entry.status.seeders == nil ? .idle : .working
					entry.status.message = nil
					entry.status.nextAnnounce = Date().addingTimeInterval(Self.interruptedRetryDelay)
				} else {
					entry.failureCount += 1
					entry.status.state = .failed(description)
					entry.status.message = description
					// Exponential backoff, capped at 30 minutes, so a dead
					// tracker stops burning battery and radio time.
					let backoff = min(1800, 60 * pow(2, Double(min(entry.failureCount, 5))))
					entry.status.nextAnnounce = Date().addingTimeInterval(backoff)
				}
			}
			entries[url] = entry
		}

		return Array(peers)
	}

	/// Re-announces everything that was interrupted or is waiting out a backoff.
	///
	/// Called when the app returns to the foreground: every socket died while it
	/// was suspended, and making the user wait out a backoff caused by their own
	/// screen lock is indefensible.
	public func retryAfterInterruption(statistics: Statistics) async -> [PeerAddress] {
		let now = Date()
		for url in order {
			guard var entry = entries[url] else { continue }
			guard !entry.isAnnouncing(now: now, staleAfter: announceTimeout * 2) else { continue }
			entry.status.nextAnnounce = nil
			entries[url] = entry
		}
		return await announce(event: .periodic, statistics: statistics)
	}

	/// Best-effort final announce; failures are irrelevant because the torrent
	/// is going away either way.
	public func announceStopped(statistics: Statistics) async {
		guard hasSentStarted else { return }
		await announce(event: .stopped, statistics: statistics, force: true)
	}
}
