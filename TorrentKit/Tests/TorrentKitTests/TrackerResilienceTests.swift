import Foundation
import Testing
@testable import TorrentKit

/// A tracker that never answers, the way an unreachable UDP tracker behaves on
/// a network that silently drops its packets.
private struct HangingTracker: TrackerClient {
	let url: String

	func announce(_ request: AnnounceRequest) async throws -> AnnounceResponse {
		try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
		return AnnounceResponse(interval: 1800)
	}
}

/// Fails the way a socket torn down by iOS suspension does.
private struct InterruptedTracker: TrackerClient {
	let url: String

	func announce(_ request: AnnounceRequest) async throws -> AnnounceResponse {
		throw TrackerError.interrupted
	}
}

private struct InstantTracker: TrackerClient {
	let url: String
	let peers: [PeerAddress]

	func announce(_ request: AnnounceRequest) async throws -> AnnounceResponse {
		AnnounceResponse(interval: 1800, seeders: 1, leechers: 0, peers: peers)
	}
}

@Suite("Tracker resilience", .timeLimit(.minutes(1)))
struct TrackerResilienceTests {

	private func makeManager(
		clients: [(url: String, client: TrackerClient?)],
		timeout: TimeInterval
	) -> TrackerManager {
		TrackerManager(
			infoHash: InfoHash(hex: String(repeating: "11", count: 20))!,
			peerID: .random(),
			listenPort: 6881,
			clients: clients,
			announceTimeout: timeout
		)
	}

	private var statistics: TrackerManager.Statistics {
		TrackerManager.Statistics(uploaded: 0, downloaded: 0, left: 1_000)
	}

	@Test("A tracker that never answers cannot hold up the announce cycle")
	func hangingTrackerTimesOut() async throws {
		let manager = makeManager(
			clients: [("udp://dead.example:1337/announce", HangingTracker(url: "udp://dead.example:1337/announce"))],
			timeout: 1
		)

		let start = Date()
		_ = await manager.announce(event: .started, statistics: statistics)
		let elapsed = Date().timeIntervalSince(start)

		// Without a cancellable timeout this call never returns at all.
		#expect(elapsed < 10, "announce took \(elapsed)s")

		let status = try #require(await manager.statuses.first)
		#expect(status.state.isFailure)
	}

	@Test("One dead tracker does not hide the peers a live one returned")
	func liveTrackerStillReportsPeers() async throws {
		let live = PeerAddress(host: "10.9.8.7", port: 51_413)
		let manager = makeManager(
			clients: [
				("udp://dead.example:1337/announce", HangingTracker(url: "udp://dead.example:1337/announce")),
				("http://live.example/announce", InstantTracker(url: "http://live.example/announce", peers: [live])),
			],
            timeout: 1
		)

		let peers = await manager.announce(event: .started, statistics: statistics)
		#expect(peers == [live])

		let statuses = await manager.statuses
		#expect(statuses.count == 2)
		#expect(statuses.contains { $0.state.isFailure })
		#expect(statuses.contains { if case .working = $0.state { true } else { false } })
	}

	@Test("A wedged tracker is retried rather than left announcing forever")
	func wedgedTrackerRecovers() async throws {
		let url = "udp://dead.example:1337/announce"
		let manager = makeManager(clients: [(url, HangingTracker(url: url))], timeout: 1)

		_ = await manager.announce(event: .started, statistics: statistics)
		let first = try #require(await manager.statuses.first)
		#expect(first.state.isFailure)

		// The in-flight flag must have been cleared, otherwise the `due` filter
		// would skip this tracker for the rest of the session.
		let start = Date()
		_ = await manager.announce(event: .periodic, statistics: statistics, force: true)
		#expect(Date().timeIntervalSince(start) < 10)

		let second = try #require(await manager.statuses.first)
		#expect(second.state.isFailure)
		#expect(second.lastAnnounce != nil)
	}

	/// The shape that actually broke: a callback-driven wait that no amount of
	/// task cancellation can interrupt on its own.
	///
	/// A task group waits for every child before it returns, so wrapping such an
	/// operation in a timeout is not enough — the operation has to tear down
	/// whatever it is waiting on when cancelled. This is exactly what
	/// `UDPSocket.connect` does with `connection.cancel()`.
	@Test("A callback wait that only unblocks on cancellation still times out")
	func cancellationDrivenWaitTimesOut() async {
		final class Trigger: @unchecked Sendable {
			private let lock = NSLock()
			private var continuation: CheckedContinuation<Void, Error>?
			private var cancelled = false

			func store(_ value: CheckedContinuation<Void, Error>) {
				lock.lock()
				if cancelled {
					lock.unlock()
					value.resume(throwing: CancellationError())
					return
				}
				continuation = value
				lock.unlock()
			}

			func cancel() {
				lock.lock()
				cancelled = true
				let pending = continuation
				continuation = nil
				lock.unlock()
				pending?.resume(throwing: CancellationError())
			}
		}

		let start = Date()
		let trigger = Trigger()

		await #expect(throws: (any Error).self) {
			try await withTimeout(seconds: 0.5) {
				try await withTaskCancellationHandler {
					// Nothing ever resumes this except the cancellation handler.
					try await withCheckedThrowingContinuation { trigger.store($0) }
				} onCancel: {
					trigger.cancel()
				}
			}
		}

		#expect(Date().timeIntervalSince(start) < 5)
	}

	/// iOS cancels every socket when it suspends the app. Treating that as a
	/// tracker failure fails all trackers at once and buries each of them under
	/// an exponential backoff, which is what a screen lock used to do.
	@Test("An interrupted announce does not count against the tracker")
	func interruptionIsNotTheTrackersFault() async throws {
		let url = "udp://tracker.example:1337/announce"
		let manager = makeManager(clients: [(url, InterruptedTracker(url: url))], timeout: 5)

		_ = await manager.announce(event: .started, statistics: statistics)

		let status = try #require(await manager.statuses.first)
		#expect(!status.state.isFailure, "an interruption must not mark the tracker broken")
		#expect(status.message == nil)

		// And the retry must come soon, not after a punitive backoff.
		let next = try #require(status.nextAnnounce)
		#expect(next.timeIntervalSinceNow < 60)
	}

	@Test("Returning to the foreground clears pending backoffs")
	func foregroundRetryClearsBackoff() async throws {
		let dead = "udp://dead.example:1337/announce"
		let live = PeerAddress(host: "10.1.1.1", port: 6881)
		let manager = makeManager(
			clients: [
				(dead, HangingTracker(url: dead)),
				("http://live.example/announce", InstantTracker(url: "http://live.example/announce", peers: [live])),
			],
			timeout: 1
		)

		_ = await manager.announce(event: .started, statistics: statistics)
		let afterFailure = try #require(await manager.statuses.first { $0.url == dead })
		let backoff = try #require(afterFailure.nextAnnounce)
		#expect(backoff.timeIntervalSinceNow > 30, "expected a real backoff to be cleared later")

		// Without the reset this returns nothing: both trackers are still
		// waiting out their intervals.
		let peers = await manager.retryAfterInterruption(statistics: statistics)
		#expect(peers == [live])
	}

	@Test("withTimeout cancels the operation instead of waiting for it")
	func timeoutCancels() async {
		let start = Date()
		await #expect(throws: TimeoutError.self) {
			try await withTimeout(seconds: 0.5) {
				try await Task.sleep(nanoseconds: 30 * 1_000_000_000)
			}
		}
		#expect(Date().timeIntervalSince(start) < 5)
	}
}
