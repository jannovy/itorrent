import Foundation
import Testing
@testable import TorrentKit

/// End-to-end tests: two real sessions, two real sockets, one real torrent.
///
/// These are the tests that matter. Everything else checks a component in
/// isolation; only this one proves that a handshake, a bitfield exchange, the
/// choking algorithm, piece requests, hash verification and disk writes all fit
/// together and move bytes.
@Suite("Transfer", .timeLimit(.minutes(2)))
struct TransferTests {

	private static func makeSession(downloadDirectory: URL) async -> TorrentSession {
		let session = TorrentSession(
			store: SessionStore(rootURL: Fixtures.temporaryDirectory()),
			downloadDirectory: downloadDirectory
		)
		var settings = SessionSettings.default
		// Tests must not touch the real DHT network.
		settings.isDHTEnabled = false
		settings.isPeerExchangeEnabled = false
		await session.update(settings: settings)
		await session.start()
		return session
	}

	private static func waitForListenPort(_ session: TorrentSession) async throws -> UInt16 {
		for _ in 0..<100 {
			let port = await session.listenPort()
			if port > 0 { return port }
			try await Task.sleep(nanoseconds: 50_000_000)
		}
		throw TestFailure.timedOut("listener never became ready")
	}

	private static func waitUntil(
		_ description: String,
		timeout: TimeInterval = 90,
		_ condition: @Sendable () async -> Bool
	) async throws {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if await condition() { return }
			try await Task.sleep(nanoseconds: 200_000_000)
		}
		throw TestFailure.timedOut(description)
	}

	enum TestFailure: Error, CustomStringConvertible {
		case timedOut(String)
		var description: String {
			if case let .timedOut(what) = self { return "Timed out waiting for \(what)" }
			return "failure"
		}
	}

	@Test("A complete peer transfers a single-file torrent to an empty peer")
	func transfersSingleFileTorrent() async throws {
		let payload = Fixtures.payload(byteCount: 1_500_000)
		let (metainfo, _) = Fixtures.singleFileTorrent(payload: payload, pieceLength: 32_768)
		#expect(metainfo.pieceCount == 46)

		let seederDirectory = Fixtures.temporaryDirectory()
		let leecherDirectory = Fixtures.temporaryDirectory()
		try payload.write(to: seederDirectory.appendingPathComponent("sample.bin"))

		let seeder = await Self.makeSession(downloadDirectory: seederDirectory)
		let leecher = await Self.makeSession(downloadDirectory: leecherDirectory)
		defer {
			Task {
				await seeder.stop()
				await leecher.stop()
			}
		}

		let seederPort = try await Self.waitForListenPort(seeder)
		_ = try await Self.waitForListenPort(leecher)

		// The seeder rechecks the existing file and should end up seeding.
		try await seeder.add(source: .metainfo(metainfo))
		try await Self.waitUntil("seeder to finish checking", timeout: 30) {
			guard let snapshot = await seeder.allSnapshots().first else { return false }
			if case .seeding = snapshot.status { return true }
			return false
		}

		let infoHash = try await leecher.add(source: .metainfo(metainfo))
		await leecher.addPeer(PeerAddress(host: "127.0.0.1", port: seederPort), to: infoHash)

		try await Self.waitUntil("the leecher to complete the download") {
			guard let snapshot = await leecher.allSnapshots().first else { return false }
			return snapshot.progress >= 1
		}

		let downloaded = try Data(contentsOf: leecherDirectory.appendingPathComponent("sample.bin"))
		#expect(downloaded == payload)

		let snapshot = try #require(await leecher.allSnapshots().first)
		#expect(snapshot.completedPieces == metainfo.pieceCount)
		#expect(snapshot.downloadedBytes >= Int64(payload.count))
		#expect(snapshot.connectedPeers >= 1)

		// The seeder should have accounted for the bytes it sent.
		let seederSnapshot = try #require(await seeder.allSnapshots().first)
		#expect(seederSnapshot.uploadedBytes > 0)
	}

	@Test("A multi-file torrent lands on disk with every file intact")
	func transfersMultiFileTorrent() async throws {
		// Odd sizes on purpose: pieces straddle file boundaries.
		let (metainfo, payload) = Fixtures.multiFileTorrent(
			fileSizes: [90_000, 150_001, 7, 260_000],
			pieceLength: 16_384
		)

		let seederDirectory = Fixtures.temporaryDirectory()
		let leecherDirectory = Fixtures.temporaryDirectory()

		// Lay the content out for the seeder exactly as the torrent describes.
		let seederStorage = TorrentStorage(metainfo: metainfo, downloadDirectory: seederDirectory)
		for index in 0..<metainfo.pieceCount {
			let range = metainfo.byteRange(ofPiece: index)
			try await seederStorage.write(
				piece: index,
				data: payload.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
			)
		}
		await seederStorage.flush()
		await seederStorage.close()

		let seeder = await Self.makeSession(downloadDirectory: seederDirectory)
		let leecher = await Self.makeSession(downloadDirectory: leecherDirectory)
		defer {
			Task {
				await seeder.stop()
				await leecher.stop()
			}
		}

		let seederPort = try await Self.waitForListenPort(seeder)
		try await seeder.add(source: .metainfo(metainfo))
		try await Self.waitUntil("seeder to finish checking", timeout: 30) {
			guard let snapshot = await seeder.allSnapshots().first else { return false }
			if case .seeding = snapshot.status { return true }
			return false
		}

		let infoHash = try await leecher.add(source: .metainfo(metainfo))
		await leecher.addPeer(PeerAddress(host: "127.0.0.1", port: seederPort), to: infoHash)

		try await Self.waitUntil("the multi-file download to complete") {
			guard let snapshot = await leecher.allSnapshots().first else { return false }
			return snapshot.progress >= 1
		}

		let leecherStorage = TorrentStorage(metainfo: metainfo, downloadDirectory: leecherDirectory)
		for file in metainfo.files {
			let url = await leecherStorage.url(for: file)
			let contents = try Data(contentsOf: url)
			let expected = payload.subdata(in: Int(file.offset)..<Int(file.offset + file.length))
			#expect(contents == expected, "\(file.relativePath) does not match")
		}
		await leecherStorage.close()
	}

	@Test("A magnet link fetches its metadata from a peer and then downloads")
	func fetchesMetadataFromPeer() async throws {
		let payload = Fixtures.payload(byteCount: 400_000)
		let (metainfo, _) = Fixtures.singleFileTorrent(payload: payload, pieceLength: 16_384)

		let seederDirectory = Fixtures.temporaryDirectory()
		let leecherDirectory = Fixtures.temporaryDirectory()
		try payload.write(to: seederDirectory.appendingPathComponent("sample.bin"))

		let seeder = await Self.makeSession(downloadDirectory: seederDirectory)
		let leecher = await Self.makeSession(downloadDirectory: leecherDirectory)
		defer {
			Task {
				await seeder.stop()
				await leecher.stop()
			}
		}

		let seederPort = try await Self.waitForListenPort(seeder)
		try await seeder.add(source: .metainfo(metainfo))
		try await Self.waitUntil("seeder to finish checking", timeout: 30) {
			guard let snapshot = await seeder.allSnapshots().first else { return false }
			if case .seeding = snapshot.status { return true }
			return false
		}

		// The leecher knows only the info-hash, as with a real magnet link.
		let magnet = MagnetURI(infoHash: metainfo.infoHash, displayName: "unknown")
		let infoHash = try await leecher.add(source: .magnet(magnet))

		let initial = try #require(await leecher.allSnapshots().first)
		#expect(initial.isMagnetOnly)

		await leecher.addPeer(PeerAddress(host: "127.0.0.1", port: seederPort), to: infoHash)

		try await Self.waitUntil("metadata to arrive over ut_metadata", timeout: 60) {
			guard let snapshot = await leecher.allSnapshots().first else { return false }
			return !snapshot.isMagnetOnly
		}

		let resolved = try #require(await leecher.allSnapshots().first)
		#expect(resolved.name == metainfo.name)
		#expect(resolved.totalBytes == metainfo.totalLength)

		try await Self.waitUntil("the magnet download to complete") {
			guard let snapshot = await leecher.allSnapshots().first else { return false }
			return snapshot.progress >= 1
		}

		let downloaded = try Data(contentsOf: leecherDirectory.appendingPathComponent("sample.bin"))
		#expect(downloaded == payload)
	}

	/// The failure this reproduces: every tracker wedged in "announcing", zero
	/// peers, and a download frozen mid-transfer. An unreachable tracker used to
	/// hang the torrent's tick, which is what actually keeps peers connected and
	/// blocks flowing — so one bad announce URL stopped everything.
	@Test("An unreachable tracker does not stop the download")
	func unreachableTrackerDoesNotStallTransfer() async throws {
		let payload = Fixtures.payload(byteCount: 600_000)
		let (metainfo, _) = Fixtures.singleFileTorrent(payload: payload, pieceLength: 16_384)

		let seederDirectory = Fixtures.temporaryDirectory()
		let leecherDirectory = Fixtures.temporaryDirectory()
		try payload.write(to: seederDirectory.appendingPathComponent("sample.bin"))

		let seeder = await Self.makeSession(downloadDirectory: seederDirectory)
		let leecher = await Self.makeSession(downloadDirectory: leecherDirectory)
		defer {
			Task {
				await seeder.stop()
				await leecher.stop()
			}
		}

		let seederPort = try await Self.waitForListenPort(seeder)
		try await seeder.add(source: .metainfo(metainfo))
		try await Self.waitUntil("seeder to finish checking", timeout: 30) {
			guard let snapshot = await seeder.allSnapshots().first else { return false }
			if case .seeding = snapshot.status { return true }
			return false
		}

		let infoHash = try await leecher.add(source: .metainfo(metainfo))

		// RFC 5737 TEST-NET-1: guaranteed not routable, so the announce either
		// hangs until it is timed out or fails outright. Either way the
		// download must proceed.
		await leecher.addTracker("udp://192.0.2.1:1337/announce", to: infoHash)
		await leecher.addPeer(PeerAddress(host: "127.0.0.1", port: seederPort), to: infoHash)

		try await Self.waitUntil("the download to finish despite the dead tracker") {
			guard let snapshot = await leecher.allSnapshots().first else { return false }
			return snapshot.progress >= 1
		}

		let downloaded = try Data(contentsOf: leecherDirectory.appendingPathComponent("sample.bin"))
		#expect(downloaded == payload)

		// And the tracker must eventually be reported as broken. Sitting in
		// "announcing" forever was the visible symptom of the wedge: the entry
		// never cleared, so it was never retried either.
		try await Self.waitUntil("the dead tracker to stop announcing", timeout: 90) {
			guard let snapshot = await leecher.allSnapshots().first,
			      let dead = snapshot.trackers.first(where: { $0.url.contains("192.0.2.1") })
			else { return false }
			if case .announcing = dead.state { return false }
			return true
		}

		let snapshot = try #require(await leecher.allSnapshots().first)
		let dead = try #require(snapshot.trackers.first { $0.url.contains("192.0.2.1") })
		#expect(dead.state.isFailure)
		#expect(dead.nextAnnounce != nil, "a failed tracker must be scheduled for a retry")
	}

	/// A tracker the user typed in exists nowhere but our own resume file, so
	/// dropping it on restart loses it for good.
	@Test("A manually added tracker survives a restart")
	func addedTrackerIsPersisted() async throws {
		let payload = Fixtures.payload(byteCount: 40_000)
		let (metainfo, _) = Fixtures.singleFileTorrent(payload: payload, pieceLength: 16_384)

		let downloadDirectory = Fixtures.temporaryDirectory()
		let store = SessionStore(rootURL: Fixtures.temporaryDirectory())
		try store.prepare()

		var settings = SessionSettings.default
		settings.isDHTEnabled = false
		settings.startTorrentsPaused = true

		let extraTracker = "udp://added-by-hand.example:1337/announce"

		let first = TorrentSession(store: store, downloadDirectory: downloadDirectory)
		await first.update(settings: settings)
		await first.start()
		let infoHash = try await first.add(source: .metainfo(metainfo))
		await first.addTracker(extraTracker, to: infoHash)
		await first.stop()

		// A brand-new session over the same store is what a relaunch looks like.
		let second = TorrentSession(store: store, downloadDirectory: downloadDirectory)
		await second.update(settings: settings)
		await second.start()
		defer { Task { await second.stop() } }

		try await Self.waitUntil("the torrent to be restored", timeout: 20) {
			await !second.allSnapshots().isEmpty
		}

		let snapshot = try #require(await second.allSnapshots().first)
		#expect(snapshot.trackers.contains { $0.url == extraTracker }, "hand-added tracker was lost")
		// The metainfo's own trackers must still be there, and only once.
		#expect(snapshot.trackers.count == metainfo.trackerTiers.flatMap { $0 }.count + 1)
	}

	/// Announcing port zero makes a client unreachable: trackers hand our
	/// address to other peers with a port nobody can dial, so every connection
	/// has to be one we open ourselves and almost nothing is ever uploaded.
	@Test("The listening port is known before any torrent announces")
	func listenPortIsReadyBeforeRestore() async throws {
		let payload = Fixtures.payload(byteCount: 40_000)
		let (metainfo, _) = Fixtures.singleFileTorrent(payload: payload, pieceLength: 16_384)

		let downloadDirectory = Fixtures.temporaryDirectory()
		let store = SessionStore(rootURL: Fixtures.temporaryDirectory())
		try store.prepare()

		var settings = SessionSettings.default
		settings.isDHTEnabled = false
		settings.startTorrentsPaused = true

		let first = TorrentSession(store: store, downloadDirectory: downloadDirectory)
		await first.update(settings: settings)
		await first.start()
		_ = try await first.add(source: .metainfo(metainfo))
		await first.stop()

		let second = TorrentSession(store: store, downloadDirectory: downloadDirectory)
		await second.update(settings: settings)
		await second.start()
		defer { Task { await second.stop() } }

		// The port must be bound by the time `start()` returns, because that is
		// when persisted torrents are restored and first announce.
		let port = await second.listenPort()
		#expect(port > 0, "session restored torrents while still announcing port 0")

		let statistics = await second.statistics()
		#expect(statistics.listenPort == port)
	}

	@Test("Resume data lets a partial download continue instead of restarting")
	func resumesFromPersistedState() async throws {
		let payload = Fixtures.payload(byteCount: 300_000)
		let (metainfo, _) = Fixtures.singleFileTorrent(payload: payload, pieceLength: 16_384)

		let downloadDirectory = Fixtures.temporaryDirectory()
		let storeRoot = Fixtures.temporaryDirectory()
		let store = SessionStore(rootURL: storeRoot)
		try store.prepare()

		// Pretend the first half was downloaded before the app was killed.
		let storage = TorrentStorage(metainfo: metainfo, downloadDirectory: downloadDirectory)
		var bitfield = BitField(bitCount: metainfo.pieceCount)
		for index in 0..<(metainfo.pieceCount / 2) {
			let range = metainfo.byteRange(ofPiece: index)
			try await storage.write(
				piece: index,
				data: payload.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
			)
			bitfield[index] = true
		}
		await storage.flush()
		await storage.close()

		store.saveMetainfo(metainfo, forInfoHashHex: metainfo.infoHash.hex)
		store.save(state: TorrentPersistentState(
			infoHashHex: metainfo.infoHash.hex,
			name: metainfo.name,
			magnetURI: nil,
			savePath: downloadDirectory.path,
			addedAt: Date(),
			completedAt: nil,
			uploadedBytes: 0,
			downloadedBytes: 0,
			pieceCount: metainfo.pieceCount,
			bitfield: bitfield.bytes,
			isPaused: true,
			filePriorities: [:],
			trackers: []
		))

		let session = TorrentSession(store: store, downloadDirectory: downloadDirectory)
		var settings = SessionSettings.default
		settings.isDHTEnabled = false
		await session.update(settings: settings)
		await session.start()
		defer { Task { await session.stop() } }

		try await Self.waitUntil("the restored torrent to appear", timeout: 20) {
			await !session.allSnapshots().isEmpty
		}

		let snapshot = try #require(await session.allSnapshots().first)
		#expect(snapshot.name == metainfo.name)
		#expect(snapshot.status.isPaused)
		#expect(snapshot.completedPieces == metainfo.pieceCount / 2)
		#expect(snapshot.progress > 0.4 && snapshot.progress < 0.6)
	}
}
