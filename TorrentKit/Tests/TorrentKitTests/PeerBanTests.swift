import Foundation
import Testing
@testable import TorrentKit

/// A peer that answers every request with zeroes of the right length.
///
/// Speaking the wire protocol with our own encoder is deliberate: the point is
/// to prove the *receiving* side notices, and a hand-rolled attacker would only
/// prove that the test's idea of the protocol matches the test's own.
private final class MaliciousPeer: @unchecked Sendable {
	private let connection: PeerConnection
	private let pieceCount: Int
	private var task: Task<Void, Never>?

	private let lock = NSLock()
	private var disconnectReason: PeerDisconnectReason?
	private var blocksSent = 0

	init(to port: UInt16, infoHash: InfoHash, pieceCount: Int) {
		self.pieceCount = pieceCount
		self.connection = PeerConnection(
			address: PeerAddress(host: "127.0.0.1", port: port),
			role: .outgoing(infoHash: infoHash),
			localPeerID: .random()
		)
	}

	var wasDisconnected: Bool { lock.withLock { disconnectReason != nil } }
	var sentBlockCount: Int { lock.withLock { blocksSent } }

	func start() {
		let stream = connection.start()
		task = Task { [weak self] in
			for await event in stream {
				guard let self else { return }
				switch event {
				case .handshake:
					var everything = BitField(bitCount: self.pieceCount)
					for index in 0..<self.pieceCount { everything[index] = true }
					self.connection.send([.bitfield(everything.bytes), .unchoke])

				case let .message(message):
					if case let .request(request) = message {
						self.lock.withLock { self.blocksSent += 1 }
						self.connection.send(.piece(
							pieceIndex: request.pieceIndex,
							begin: request.begin,
							block: Data(count: request.length)
						))
					}

				case let .disconnected(reason):
					self.lock.withLock { self.disconnectReason = reason }
					return
				}
			}
		}
	}

	func stop() {
		task?.cancel()
		connection.close()
	}
}

@Suite("Peer bans", .timeLimit(.minutes(1)))
struct PeerBanTests {

	@Test("A piece assembled from one peer names that peer when it fails its hash")
	func attributesACorruptPieceToItsOnlyContributor() {
		let payload = Fixtures.payload(byteCount: 32_768)
		let (metainfo, _) = Fixtures.singleFileTorrent(payload: payload, pieceLength: 16_384)
		let picker = PiecePicker(metainfo: metainfo)

		// Held in variables on purpose: an ObjectIdentifier of a temporary is
		// only unique while that temporary is alive, and two of them in a row
		// land on the same address.
		let honestPeer = NSObject()
		let lyingPeer = NSObject()
		let honest = ObjectIdentifier(honestPeer)
		let liar = ObjectIdentifier(lyingPeer)

		_ = picker.receive(pieceIndex: 0, begin: 0, block: Data(count: 16_384), from: liar)
		#expect(picker.contributors(toPiece: 0) == [liar])
		#expect(!picker.contributors(toPiece: 0).contains(honest))
	}

	@Test("A piece built from several peers implicates all of them")
	func attributesACorruptPieceToEveryContributor() {
		let payload = Fixtures.payload(byteCount: 65_536)
		let (metainfo, _) = Fixtures.singleFileTorrent(payload: payload, pieceLength: 65_536)
		let picker = PiecePicker(metainfo: metainfo)

		let firstPeer = NSObject()
		let secondPeer = NSObject()
		let first = ObjectIdentifier(firstPeer)
		let second = ObjectIdentifier(secondPeer)

		_ = picker.receive(pieceIndex: 0, begin: 0, block: Data(count: 16_384), from: first)
		_ = picker.receive(pieceIndex: 0, begin: 16_384, block: Data(count: 16_384), from: second)

		#expect(picker.contributors(toPiece: 0) == [first, second])
	}

	@Test("Contributors are forgotten once the piece is thrown away")
	func forgetsContributorsAfterDiscardingThePiece() {
		let payload = Fixtures.payload(byteCount: 16_384)
		let (metainfo, _) = Fixtures.singleFileTorrent(payload: payload, pieceLength: 16_384)
		let picker = PiecePicker(metainfo: metainfo)

		let peer = ObjectIdentifier(NSObject())
		_ = picker.receive(pieceIndex: 0, begin: 0, block: Data(count: 16_384), from: peer)
		picker.markCorrupt(piece: 0)

		#expect(picker.contributors(toPiece: 0).isEmpty)
	}

	@Test("A peer that sends a corrupt piece is banned and disconnected")
	func bansAPeerThatSendsCorruptData() async throws {
		let directory = Fixtures.temporaryDirectory()
		let session = TorrentSession(
			store: SessionStore(rootURL: Fixtures.temporaryDirectory()),
			downloadDirectory: directory
		)
		var settings = SessionSettings.default
		settings.isDHTEnabled = false
		settings.isPeerExchangeEnabled = false
		await session.update(settings: settings)
		await session.start()
		defer { Task { await session.stop() } }

		let payload = Fixtures.payload(byteCount: 65_536)
		let (metainfo, _) = Fixtures.singleFileTorrent(payload: payload, pieceLength: 16_384)
		let infoHash = try await session.add(source: .metainfo(metainfo))

		var port: UInt16 = 0
		for _ in 0..<100 where port == 0 {
			port = await session.listenPort()
			if port == 0 { try await Task.sleep(nanoseconds: 50_000_000) }
		}
		#expect(port > 0)

		let attacker = MaliciousPeer(to: port, infoHash: infoHash, pieceCount: metainfo.pieceCount)
		attacker.start()
		defer { attacker.stop() }

		let deadline = Date().addingTimeInterval(30)
		var banned: Set<String> = []
		while Date() < deadline {
			banned = await session.bannedHosts(for: infoHash)
			if !banned.isEmpty { break }
			try await Task.sleep(nanoseconds: 100_000_000)
		}

		#expect(banned.contains("127.0.0.1"), "the attacker's host should be banned")
		#expect(attacker.sentBlockCount > 0, "the attacker should have been asked for data")

		// The ban has to close the connection, not merely stop asking: a peer
		// left connected still occupies a slot and still gets our bitfield.
		let disconnectDeadline = Date().addingTimeInterval(10)
		while Date() < disconnectDeadline, !attacker.wasDisconnected {
			try await Task.sleep(nanoseconds: 100_000_000)
		}
		#expect(attacker.wasDisconnected)
	}
}
