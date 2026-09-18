import Foundation
import Testing
@testable import TorrentKit

/// MSE over real sockets: two sessions, one torrent, nothing readable on the
/// wire. The handshake unit tests prove the protocol; these prove it survives
/// contact with `PeerConnection`, framing, and a transfer that matters.
@Suite("Encrypted transfers", .timeLimit(.minutes(2)))
struct EncryptedTransferTests {

	private static func makeSession(
		downloadDirectory: URL,
		encryption: EncryptionPolicy
	) async -> TorrentSession {
		let session = TorrentSession(
			store: SessionStore(rootURL: Fixtures.temporaryDirectory()),
			downloadDirectory: downloadDirectory
		)
		var settings = SessionSettings.default
		settings.isDHTEnabled = false
		settings.isPeerExchangeEnabled = false
		settings.areWebSeedsEnabled = false
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
		throw Failure.timedOut("listener never became ready")
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
		throw Failure.timedOut(what)
	}

	enum Failure: Error, CustomStringConvertible {
		case timedOut(String)
		var description: String {
			if case let .timedOut(what) = self { return "Timed out waiting for \(what)" }
			return "failure"
		}
	}

	/// Runs a complete transfer between two sessions with the given policies.
	private func transfer(
		seederPolicy: EncryptionPolicy,
		leecherPolicy: EncryptionPolicy,
		byteCount: Int = 600_000
	) async throws {
		let payload = Fixtures.payload(byteCount: byteCount)
		let (metainfo, _) = Fixtures.singleFileTorrent(payload: payload, pieceLength: 32_768)

		let seedDirectory = Fixtures.temporaryDirectory()
		try payload.write(to: seedDirectory.appendingPathComponent("sample.bin"))
		let leechDirectory = Fixtures.temporaryDirectory()

		let seeder = await Self.makeSession(downloadDirectory: seedDirectory, encryption: seederPolicy)
		let leecher = await Self.makeSession(downloadDirectory: leechDirectory, encryption: leecherPolicy)
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

		try await Self.waitUntil("the encrypted transfer to complete") {
			await leecher.allSnapshots().first { $0.infoHash == infoHash }?.progress == 1
		}

		let received = try Data(contentsOf: leechDirectory.appendingPathComponent("sample.bin"))
		#expect(received == payload)
	}

	@Test("Two peers that both prefer encryption transfer a torrent")
	func transfersWithPreferredEncryption() async throws {
		try await transfer(seederPolicy: .preferred, leecherPolicy: .preferred)
	}

	@Test("Two peers that both require encryption transfer a torrent")
	func transfersWithRequiredEncryption() async throws {
		try await transfer(seederPolicy: .required, leecherPolicy: .required)
	}

	@Test("An encrypted peer falls back to plaintext for a peer without MSE")
	func fallsBackToPlaintext() async throws {
		// The seeder speaks no MSE at all, so the leecher's encrypted handshake
		// must fail and be redialled in the clear rather than losing the peer.
		try await transfer(seederPolicy: .disabled, leecherPolicy: .preferred)
	}

	@Test("A plaintext peer can still dial an encryption-preferring peer")
	func acceptsPlaintextWhenOnlyPreferred() async throws {
		try await transfer(seederPolicy: .preferred, leecherPolicy: .disabled)
	}

	@Test("A peer that requires encryption refuses a plaintext handshake")
	func refusesPlaintextWhenRequired() async throws {
		let payload = Fixtures.payload(byteCount: 65_536)
		let (metainfo, _) = Fixtures.singleFileTorrent(payload: payload, pieceLength: 32_768)

		let seedDirectory = Fixtures.temporaryDirectory()
		try payload.write(to: seedDirectory.appendingPathComponent("sample.bin"))

		let seeder = await Self.makeSession(downloadDirectory: seedDirectory, encryption: .required)
		defer { Task { await seeder.stop() } }

		let port = try await Self.waitForListenPort(seeder)
		let infoHash = try await seeder.add(source: .metainfo(metainfo))
		try await Self.waitUntil("the seeder to finish checking") {
			await seeder.allSnapshots().first { $0.infoHash == infoHash }?.progress == 1
		}

		// A bare plaintext handshake, the way a client with encryption off dials.
		let plaintext = PeerConnection(
			address: PeerAddress(host: "127.0.0.1", port: port),
			role: .outgoing(infoHash: infoHash),
			localPeerID: .random(),
			encryption: .disabled
		)
		let stream = plaintext.start()

		var sawHandshake = false
		var wasRefused = false
		let deadline = Date().addingTimeInterval(15)
		for await event in stream {
			if case .handshake = event { sawHandshake = true }
			if case .disconnected = event { wasRefused = true; break }
			if Date() > deadline { break }
		}

		#expect(!sawHandshake, "a required-encryption peer must not answer in the clear")
		#expect(wasRefused)
	}
}
