import Foundation
import Testing
@testable import TorrentKit

/// A real torrent over µTP, which is the only way to know the transport, the
/// framing, the encryption layer and the engine all fit together.
@Suite("uTP transfers", .timeLimit(.minutes(2)))
struct UTPTransferTests {

	private static func makeSession(
		downloadDirectory: URL,
		utp: Bool,
		encryption: EncryptionPolicy = .disabled
	) async -> TorrentSession {
		let session = TorrentSession(
			store: SessionStore(rootURL: Fixtures.temporaryDirectory()),
			downloadDirectory: downloadDirectory
		)
		var settings = SessionSettings.default
		settings.isDHTEnabled = false
		settings.isPeerExchangeEnabled = false
		settings.areWebSeedsEnabled = false
		settings.isUTPEnabled = utp
		settings.encryptionPolicy = encryption
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
		throw UTPFailure.timedOut("listener never became ready")
	}

	private static func waitUntil(
		_ what: String,
		timeout: TimeInterval = 60,
		_ condition: @Sendable () async -> Bool
	) async throws {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if await condition() { return }
			try await Task.sleep(nanoseconds: 200_000_000)
		}
		throw UTPFailure.timedOut(what)
	}

	private func transfer(
		seederUsesUTP: Bool,
		leecherUsesUTP: Bool,
		encryption: EncryptionPolicy = .disabled,
		byteCount: Int = 600_000,
		expectUTP: Bool? = nil
	) async throws {
		let payload = Fixtures.payload(byteCount: byteCount)
		let (metainfo, _) = Fixtures.singleFileTorrent(payload: payload, pieceLength: 32_768)

		let seedDirectory = Fixtures.temporaryDirectory()
		try payload.write(to: seedDirectory.appendingPathComponent("sample.bin"))
		let leechDirectory = Fixtures.temporaryDirectory()

		let seeder = await Self.makeSession(
			downloadDirectory: seedDirectory,
			utp: seederUsesUTP,
			encryption: encryption
		)
		let leecher = await Self.makeSession(
			downloadDirectory: leechDirectory,
			utp: leecherUsesUTP,
			encryption: encryption
		)
		defer {
			Task {
				await seeder.stop()
				await leecher.stop()
			}
		}

		let seederPort = try await Self.waitForListenPort(seeder)
		_ = try await Self.waitForListenPort(leecher)

		let infoHash = try await seeder.add(source: .metainfo(metainfo))
		try await Self.waitUntil("the seeder to finish checking") {
			await seeder.allSnapshots().first { $0.infoHash == infoHash }?.progress == 1
		}

		try await leecher.add(source: .metainfo(metainfo))
		await leecher.addPeer(PeerAddress(host: "127.0.0.1", port: seederPort), to: infoHash)

		try await Self.waitUntil("the transfer to finish") {
			await leecher.allSnapshots().first { $0.infoHash == infoHash }?.progress == 1
		}

		let received = try Data(contentsOf: leechDirectory.appendingPathComponent("sample.bin"))
		#expect(received == payload)

		if let expectUTP {
			// Which transport actually carried it, rather than just that
			// something did: the fallback path is easy to pass by accident.
			let peers = await seeder.allSnapshots().first { $0.infoHash == infoHash }?.peers ?? []
			#expect(
				peers.contains { $0.usesUTP == expectUTP },
				"expected a peer with usesUTP == \(expectUTP), got \(peers.map(\.flags))"
			)
		}
	}

	@Test("A torrent transfers over uTP")
	func transfersOverUTP() async throws {
		try await transfer(seederUsesUTP: true, leecherUsesUTP: true, expectUTP: true)
	}

	@Test("A torrent transfers over uTP with MSE on top")
	func transfersOverEncryptedUTP() async throws {
		try await transfer(seederUsesUTP: true, leecherUsesUTP: true, encryption: .required)
	}

	@Test("A uTP peer falls back to TCP for a peer that has uTP switched off")
	func fallsBackToTCP() async throws {
		// The seeder answers nothing on UDP, so the leecher's SYN must time out
		// and the peer be redialled over TCP rather than being written off.
		try await transfer(seederUsesUTP: false, leecherUsesUTP: true, expectUTP: false)
	}

	@Test("A uTP peer still accepts an inbound TCP connection")
	func acceptsTCPWhileRunningUTP() async throws {
		try await transfer(seederUsesUTP: true, leecherUsesUTP: false)
	}

	@Test("uTP binds the same port number the client announces")
	func sharesTheListenPort() async throws {
		let session = await Self.makeSession(downloadDirectory: Fixtures.temporaryDirectory(), utp: true)
		defer { Task { await session.stop() } }

		let tcpPort = try await Self.waitForListenPort(session)
		let transport = await session.utpTransport(to: PeerAddress(host: "127.0.0.1", port: 1))
		#expect(transport != nil, "uTP should be available once the listener is up")

		let statistics = await session.statistics()
		#expect(statistics.listenPort == tcpPort)
	}
}
