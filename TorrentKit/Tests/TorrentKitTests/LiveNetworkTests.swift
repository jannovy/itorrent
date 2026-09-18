import Foundation
import Testing
@testable import TorrentKit

/// Smoke tests against the real BitTorrent network.
///
/// Disabled unless `ITORRENT_LIVE_TESTS=1` is set: they depend on a public tracker,
/// the DHT and strangers' upload slots, none of which belong in a normal test
/// run. Run them by hand when changing the wire protocol, the tracker clients
/// or the DHT, because nothing else proves we interoperate with other clients.
@Suite(
	"Live network",
	.enabled(if: ProcessInfo.processInfo.environment["ITORRENT_LIVE_TESTS"] == "1"),
	.timeLimit(.minutes(5))
)
struct LiveNetworkTests {

	/// Debian's official netinst image: a large, well-seeded, freely
	/// redistributable torrent with a public HTTP tracker.
	private static let magnetLink = ProcessInfo.processInfo.environment["ITORRENT_LIVE_MAGNET"] ?? ""

	@Test("Fetches metadata and real pieces from strangers")
	func downloadsFromRealSwarm() async throws {
		guard !Self.magnetLink.isEmpty else {
			Issue.record("Set ITORRENT_LIVE_MAGNET to a magnet link to run this test")
			return
		}

		let downloadDirectory = Fixtures.temporaryDirectory()
		let session = TorrentSession(
			store: SessionStore(rootURL: Fixtures.temporaryDirectory()),
			downloadDirectory: downloadDirectory
		)
		await session.start()
		defer { Task { await session.stop() } }

		let infoHash = try await session.add(magnetLink: Self.magnetLink)
		print("Added \(infoHash.hex)")

		// Stage one: the metadata must arrive over ut_metadata from a peer.
		try await waitUntil("metadata", timeout: 180) {
			guard let snapshot = await session.allSnapshots().first else { return false }
			return !snapshot.isMagnetOnly
		}
		let resolved = try #require(await session.allSnapshots().first)
		print("Metadata: \(resolved.name), \(Format.bytes(resolved.totalBytes)), \(resolved.pieceCount) pieces")
		#expect(resolved.totalBytes > 0)
		#expect(resolved.pieceCount > 0)

		// Stage two: real pieces must verify and land on disk. A handful is
		// enough; the point is that other clients accept our wire protocol.
		try await waitUntil("verified pieces", timeout: 180) {
			guard let snapshot = await session.allSnapshots().first else { return false }
			return snapshot.completedPieces >= 2
		}

		let final = try #require(await session.allSnapshots().first)
		print("""
		Peers: \(final.connectedPeers) connected of \(final.knownPeers) known
		Pieces: \(final.completedPieces)/\(final.pieceCount)
		Down: \(Format.rate(final.downloadRate)), got \(Format.bytes(final.downloadedBytes))
		Trackers: \(final.trackers.map { "\($0.host) \($0.state)" })
		""")
		#expect(final.connectedPeers > 0)
		#expect(final.downloadedBytes > 0)
	}

	private func waitUntil(
		_ what: String,
		timeout: TimeInterval,
		_ condition: @Sendable () async -> Bool
	) async throws {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if await condition() { return }
			try await Task.sleep(nanoseconds: 1_000_000_000)
		}
		throw LiveFailure.timedOut(what)
	}

	enum LiveFailure: Error, CustomStringConvertible {
		case timedOut(String)
		var description: String {
			if case let .timedOut(what) = self { return "Timed out waiting for \(what)" }
			return "failure"
		}
	}
}
