import Foundation
import Testing
@testable import TorrentKit

@Suite("Peer wire protocol")
struct WireTests {

	@Test("Round-trips every message type")
	func roundTripsMessages() throws {
		let messages: [PeerMessage] = [
			.keepAlive,
			.choke, .unchoke, .interested, .notInterested,
			.have(pieceIndex: 1_234),
			.bitfield(Data([0xFF, 0x0F])),
			.request(BlockRequest(pieceIndex: 7, begin: 16_384, length: 16_384)),
			.piece(pieceIndex: 2, begin: 32_768, block: Data([1, 2, 3, 4])),
			.cancel(BlockRequest(pieceIndex: 9, begin: 0, length: 16_384)),
			.port(6881),
			.extended(id: 3, payload: Data("hello".utf8)),
		]

		for message in messages {
			let encoded = message.encoded()
			let length = try #require(encoded.bigEndianUInt32(at: 0))
			#expect(Int(length) == encoded.count - 4)
			let decoded = try PeerMessage.decode(body: encoded.dropFirst(4))
			#expect(decoded == message)
		}
	}

	@Test("Handshake carries the info-hash and advertised extensions")
	func handshakeRoundTrip() throws {
		let infoHash = InfoHash(hex: String(repeating: "a1", count: 20))!
		let peerID = PeerID.random()
		let handshake = PeerHandshake(infoHash: infoHash, peerID: peerID.raw)

		let encoded = handshake.encoded()
		#expect(encoded.count == PeerHandshake.byteCount)

		let decoded = try #require(PeerHandshake(data: encoded))
		#expect(decoded.infoHash == infoHash)
		#expect(decoded.peerID == peerID.raw)
		#expect(decoded.supportsExtensionProtocol)
		#expect(decoded.supportsDHT)
	}

	@Test("Rejects a handshake with the wrong protocol name")
	func rejectsBadHandshake() {
		var data = Data([19])
		data.append(contentsOf: Array("NotTorrent proto".utf8))
		data.append(Data(repeating: 0, count: PeerHandshake.byteCount - data.count))
		#expect(PeerHandshake(data: data) == nil)
	}

	@Test("Decodes compact peer lists")
	func decodesCompactPeers() {
		let data = Data([127, 0, 0, 1, 0x1A, 0xE1, 10, 0, 0, 5, 0x00, 0x50])
		let peers = PeerAddress.decodeCompact(data)
		#expect(peers.count == 2)
		#expect(peers[0] == PeerAddress(host: "127.0.0.1", port: 6881))
		#expect(peers[1] == PeerAddress(host: "10.0.0.5", port: 80))
	}

	@Test("Drops compact peers with port zero")
	func dropsPortZero() {
		let data = Data([1, 2, 3, 4, 0, 0])
		#expect(PeerAddress.decodeCompact(data).isEmpty)
	}

	@Test("Recognises well-known client identifiers")
	func recognisesClients() {
		var qbittorrent = Data("-qB4630-".utf8)
		qbittorrent.append(Data(repeating: 0x41, count: 12))
		#expect(PeerID(raw: qbittorrent)?.clientName == "qBittorrent 4.6.3")

		var transmission = Data("-TR4050-".utf8)
		transmission.append(Data(repeating: 0x42, count: 12))
		#expect(transmission.count == 20)
		#expect(PeerID(raw: transmission)?.clientName.hasPrefix("Transmission") == true)
	}

	@Test("Our own peer id is well formed")
	func ownPeerIDIsWellFormed() {
		let peerID = PeerID.random()
		#expect(peerID.raw.count == 20)
		#expect(peerID.clientName.hasPrefix("iTorrent"))
	}
}

@Suite("Extension protocol")
struct ExtensionTests {

	@Test("Parses an extension handshake")
	func parsesHandshake() {
		let payload = ExtensionProtocol.handshakePayload(
			metadataSize: 12_345,
			listenPort: 51_413,
			clientVersion: "iTorrent 1.0",
			supportsPeerExchange: true
		)
		let parsed = ExtensionProtocol.RemoteHandshake(payload: payload)
		#expect(parsed.metadataID == ExtensionProtocol.LocalID.metadata)
		#expect(parsed.peerExchangeID == ExtensionProtocol.LocalID.peerExchange)
		#expect(parsed.metadataSize == 12_345)
		#expect(parsed.clientVersion == "iTorrent 1.0")
	}

	@Test("Metadata messages survive the bencode-plus-binary framing")
	func metadataMessageFraming() throws {
		let chunk = Fixtures.payload(byteCount: MetadataMessage.pieceSize)
		let encoded = MetadataMessage.data(piece: 2, totalSize: 40_000, payload: chunk).encoded()
		let decoded = try #require(MetadataMessage(payload: encoded))

		guard case let .data(piece, totalSize, payload) = decoded else {
			Issue.record("Expected a data message")
			return
		}
		#expect(piece == 2)
		#expect(totalSize == 40_000)
		#expect(payload == chunk)
	}

	@Test("Assembles metadata and verifies it against the info-hash")
	func assemblesMetadata() throws {
		// Many small files make the info dictionary exceed one metadata piece,
		// which is the case worth testing.
		let (metainfo, _) = Fixtures.multiFileTorrent(
			fileSizes: Array(repeating: 100, count: 400),
			pieceLength: 64
		)
		let raw = metainfo.rawInfoDictionary
		#expect(raw.count > MetadataMessage.pieceSize)

		let download = try #require(MetadataDownload(infoHash: metainfo.infoHash, totalSize: raw.count))
		var requested = download.nextRequests(limit: download.pieceCount)
		#expect(requested.count == download.pieceCount)

		// Feeding the pieces back out of order must still assemble correctly.
		requested.shuffle()
		for piece in requested {
			let start = piece * MetadataMessage.pieceSize
			let end = min(raw.count, start + MetadataMessage.pieceSize)
			download.store(piece: piece, payload: raw.subdata(in: start..<end))
		}
		#expect(download.isComplete)
		#expect(download.assembledInfoDictionary() == raw)
	}

	@Test("Discards metadata that hashes to the wrong info-hash")
	func discardsPoisonedMetadata() throws {
		let (metainfo, _) = Fixtures.singleFileTorrent(payload: Fixtures.payload(byteCount: 1_000), pieceLength: 512)
		let raw = metainfo.rawInfoDictionary
		let download = try #require(MetadataDownload(infoHash: metainfo.infoHash, totalSize: raw.count))

		_ = download.nextRequests(limit: 1)
		download.store(piece: 0, payload: Data(repeating: 0x2A, count: raw.count))
		#expect(download.isComplete)
		#expect(download.assembledInfoDictionary() == nil)
	}

	@Test("Peer exchange decodes added peers")
	func peerExchangeDecodes() {
		let added = [PeerAddress(host: "1.2.3.4", port: 6881), PeerAddress(host: "5.6.7.8", port: 51_413)]
		let payload = PeerExchange.encode(added: added, dropped: [])
		#expect(PeerExchange.decode(payload: payload) == added)
	}
}

@Suite("Magnet links")
struct MagnetTests {

	@Test("Parses a hex magnet link with trackers")
	func parsesHexMagnet() throws {
		let hash = String(repeating: "0f", count: 20)
		let link = "magnet:?xt=urn:btih:\(hash)&dn=Example%20Name"
			+ "&tr=udp%3A%2F%2Ftracker.example%3A1337%2Fannounce&tr=http%3A%2F%2Fother.example%2Fannounce"
			+ "&x.pe=10.0.0.1%3A6881"
		let magnet = try MagnetURI(string: link)

		#expect(magnet.infoHash.hex == hash)
		#expect(magnet.displayName == "Example Name")
		#expect(magnet.trackers == ["udp://tracker.example:1337/announce", "http://other.example/announce"])
		#expect(magnet.peerHints == [PeerAddress(host: "10.0.0.1", port: 6881)])
	}

	@Test("Parses a base32 magnet link")
	func parsesBase32Magnet() throws {
		let raw = Data((0..<20).map { UInt8($0) })
		let base32 = Self.base32Encode(raw)
		let magnet = try MagnetURI(string: "magnet:?xt=urn:btih:\(base32)")
		#expect(magnet.infoHash.raw == raw)
	}

	@Test("Rejects v2-only and malformed links with a specific reason")
	func rejectsUnsupported() {
		#expect(throws: MagnetError.self) {
			try MagnetURI(string: "magnet:?xt=urn:btmh:1220caf1e1f0")
		}
		#expect(throws: MagnetError.self) {
			try MagnetURI(string: "magnet:?dn=no-hash-here")
		}
		#expect(throws: MagnetError.self) {
			try MagnetURI(string: "https://example.com/file.torrent")
		}
	}

	@Test("Round-trips through its own URI form")
	func roundTripsURI() throws {
		let hash = String(repeating: "ab", count: 20)
		let magnet = try MagnetURI(string: "magnet:?xt=urn:btih:\(hash)&tr=http%3A%2F%2Ft.example%2Fa")
		let again = try MagnetURI(string: magnet.uriString)
		#expect(again.infoHash == magnet.infoHash)
		#expect(again.trackers == magnet.trackers)
	}

	private static func base32Encode(_ data: Data) -> String {
		let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
		var output = ""
		var buffer = 0
		var bits = 0
		for byte in data {
			buffer = buffer << 8 | Int(byte)
			bits += 8
			while bits >= 5 {
				bits -= 5
				output.append(alphabet[(buffer >> bits) & 31])
			}
		}
		if bits > 0 { output.append(alphabet[(buffer << (5 - bits)) & 31]) }
		return output
	}
}
