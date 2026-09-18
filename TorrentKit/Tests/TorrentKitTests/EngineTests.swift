import CryptoKit
import Foundation
import Testing
@testable import TorrentKit

@Suite("BitField")
struct BitFieldTests {

	@Test("Bit zero is the most significant bit of byte zero")
	func bitOrdering() {
		var field = BitField(bitCount: 16)
		field[0] = true
		#expect(field.bytes[0] == 0x80)
		field[7] = true
		#expect(field.bytes[0] == 0x81)
		field[8] = true
		#expect(field.bytes[1] == 0x80)
		#expect(field.setBitCount == 3)
	}

	@Test("Tracks the number of set bits through sets and clears")
	func tracksCount() {
		var field = BitField(bitCount: 10)
		for index in 0..<10 { field[index] = true }
		#expect(field.isComplete)
		#expect(field.completionFraction == 1)

		field[3] = false
		#expect(field.setBitCount == 9)
		#expect(!field.isComplete)

		// Setting the same bit twice must not double-count.
		field[3] = true
		field[3] = true
		#expect(field.setBitCount == 10)
	}

	@Test("Rejects a bitfield with spare bits set")
	func rejectsSpareBits() {
		#expect(BitField(bytes: Data([0xFF]), bitCount: 4) == nil)
		#expect(BitField(bytes: Data([0xF0]), bitCount: 4) != nil)
		#expect(BitField(bytes: Data([0xFF]), bitCount: 16) == nil) // too short
	}
}

@Suite("Piece picker")
struct PiecePickerTests {

	private func makePicker(pieces: Int, pieceLength: Int = 32_768) -> (PiecePicker, TorrentMetainfo) {
		let (metainfo, _) = Fixtures.singleFileTorrent(
			payload: Fixtures.payload(byteCount: pieces * pieceLength),
			pieceLength: pieceLength
		)
		return (PiecePicker(metainfo: metainfo), metainfo)
	}

	@Test("Only requests pieces the peer actually has")
	func requestsOnlyAvailablePieces() {
		let (picker, metainfo) = makePicker(pieces: 8)
		var peerBits = BitField(bitCount: metainfo.pieceCount)
		peerBits[3] = true
		peerBits[5] = true

		let peer = ObjectIdentifier(NSObject())
		let requests = picker.pick(for: peer, peerBitfield: peerBits, limit: 32)
		#expect(!requests.isEmpty)
		#expect(requests.allSatisfy { $0.pieceIndex == 3 || $0.pieceIndex == 5 })
	}

	@Test("Never issues the same block to one peer twice")
	func noDuplicateRequests() {
		let (picker, metainfo) = makePicker(pieces: 4)
		var peerBits = BitField(bitCount: metainfo.pieceCount)
		peerBits.setAll()

		let peer = ObjectIdentifier(NSObject())
		let first = picker.pick(for: peer, peerBitfield: peerBits, limit: 6)
		let second = picker.pick(for: peer, peerBitfield: peerBits, limit: 6)
		#expect(Set(first).intersection(Set(second)).isEmpty)
	}

	@Test("Assembles a piece from its blocks and reports it ready")
	func assemblesPiece() throws {
		let pieceLength = 32_768
		let payload = Fixtures.payload(byteCount: pieceLength * 2)
		let (metainfo, _) = Fixtures.singleFileTorrent(payload: payload, pieceLength: pieceLength)
		let picker = PiecePicker(metainfo: metainfo)

		var completed: Data?
		for begin in stride(from: 0, to: pieceLength, by: BlockRequest.standardLength) {
			let block = payload.subdata(in: begin..<(begin + BlockRequest.standardLength))
			if case let .pieceReady(index, data) = picker.receive(pieceIndex: 0, begin: begin, block: block) {
				#expect(index == 0)
				completed = data
			}
		}
		let assembled = try #require(completed)
		#expect(assembled == payload.prefix(pieceLength))
		#expect(Data(Insecure.SHA1.hash(data: assembled)) == metainfo.pieceHashes[0])
	}

	@Test("Rejects blocks with the wrong size or offset")
	func rejectsBadBlocks() {
		let (picker, _) = makePicker(pieces: 4)
		#expect(isIgnored(picker.receive(pieceIndex: 0, begin: 1, block: Data(count: 16_384))))
		#expect(isIgnored(picker.receive(pieceIndex: 0, begin: 0, block: Data(count: 100))))
		#expect(isIgnored(picker.receive(pieceIndex: 99, begin: 0, block: Data(count: 16_384))))
	}

	@Test("Releases a disconnected peer's requests for someone else")
	func releasesRequests() {
		let (picker, metainfo) = makePicker(pieces: 4)
		var peerBits = BitField(bitCount: metainfo.pieceCount)
		peerBits.setAll()

		let first = ObjectIdentifier(NSObject())
		let taken = picker.pick(for: first, peerBitfield: peerBits, limit: 4)
		#expect(picker.outstandingRequestCount(for: first) == taken.count)

		picker.releaseRequests(from: first)
		#expect(picker.outstandingRequestCount(for: first) == 0)

		let second = ObjectIdentifier(NSObject())
		let retaken = picker.pick(for: second, peerBitfield: peerBits, limit: 4)
		#expect(Set(retaken) == Set(taken))
	}

	@Test("Prefers rarer pieces once the random-start phase is over")
	func prefersRarePieces() {
		let (picker, metainfo) = makePicker(pieces: 12)
		// Get past the random-piece phase.
		for index in 0..<4 { picker.markVerified(piece: index) }

		var common = BitField(bitCount: metainfo.pieceCount)
		for index in 4..<12 { common[index] = true }
		for _ in 0..<5 { picker.addAvailability(bitfield: common) }

		var rare = BitField(bitCount: metainfo.pieceCount)
		rare[9] = true
		picker.addAvailability(bitfield: rare)
		#expect(picker.availabilityCount(piece: 9) == 6)

		var scarce = BitField(bitCount: metainfo.pieceCount)
		scarce[7] = true
		// Piece 7 is held by only one peer in this construction.
		for index in 4..<12 where index != 7 { picker.addAvailability(piece: index) }

		let peer = ObjectIdentifier(NSObject())
		let requests = picker.pick(for: peer, peerBitfield: common, limit: 1)
		#expect(requests.first?.pieceIndex == 7)
	}

	@Test("Skipped files are excluded from what the torrent wants")
	func honoursSkipPriority() {
		let (picker, metainfo) = makePicker(pieces: 10)
		var priorities = [PiecePriority](repeating: .normal, count: metainfo.pieceCount)
		for index in 5..<10 { priorities[index] = .skip }
		picker.setPriorities(priorities)

		var peerBits = BitField(bitCount: metainfo.pieceCount)
		peerBits.setAll()
		let requests = picker.pick(for: ObjectIdentifier(NSObject()), peerBitfield: peerBits, limit: 64)
		#expect(requests.allSatisfy { $0.pieceIndex < 5 })

		for index in 0..<5 { picker.markVerified(piece: index) }
		#expect(picker.isComplete)
	}

	@Test("A corrupt piece is discarded and can be fetched again")
	func refetchesCorruptPiece() {
		let (picker, metainfo) = makePicker(pieces: 4, pieceLength: 16_384)
		var peerBits = BitField(bitCount: metainfo.pieceCount)
		peerBits.setAll()
		let peer = ObjectIdentifier(NSObject())

		_ = picker.pick(for: peer, peerBitfield: peerBits, limit: 1)
		picker.markCorrupt(piece: 0)
		#expect(picker.failureCount(piece: 0) == 1)
		#expect(!picker.have[0])

		let again = picker.pick(for: peer, peerBitfield: peerBits, limit: 8)
		#expect(again.contains { $0.pieceIndex == 0 })
	}

	private func isIgnored(_ outcome: PiecePicker.BlockOutcome) -> Bool {
		if case .ignored = outcome { return true }
		return false
	}
}

@Suite("Storage")
struct StorageTests {

	@Test("Writes and reads back a single-file torrent")
	func singleFileRoundTrip() async throws {
		let payload = Fixtures.payload(byteCount: 50_000)
		let (metainfo, _) = Fixtures.singleFileTorrent(payload: payload, pieceLength: 16_384)
		let directory = Fixtures.temporaryDirectory()
		let storage = TorrentStorage(metainfo: metainfo, downloadDirectory: directory)

		for index in 0..<metainfo.pieceCount {
			let range = metainfo.byteRange(ofPiece: index)
			try await storage.write(piece: index, data: payload.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)))
		}

		let block = try await storage.read(BlockRequest(pieceIndex: 1, begin: 0, length: 16_384))
		#expect(block == payload.subdata(in: 16_384..<32_768))

		let onDisk = try Data(contentsOf: directory.appendingPathComponent("sample.bin"))
		#expect(onDisk == payload)
		await storage.close()
	}

	@Test("Splits pieces that straddle file boundaries")
	func multiFileBoundaries() async throws {
		// 300-byte files with 128-byte pieces guarantees pieces spanning files.
		let (metainfo, payload) = Fixtures.multiFileTorrent(fileSizes: [300, 300, 300], pieceLength: 128)
		let directory = Fixtures.temporaryDirectory()
		let storage = TorrentStorage(metainfo: metainfo, downloadDirectory: directory)

		for index in 0..<metainfo.pieceCount {
			let range = metainfo.byteRange(ofPiece: index)
			try await storage.write(piece: index, data: payload.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)))
		}
		await storage.flush()

		for file in metainfo.files {
			let url = await storage.url(for: file)
			let contents = try Data(contentsOf: url)
			let expected = payload.subdata(in: Int(file.offset)..<Int(file.offset + file.length))
			#expect(contents == expected, "File \(file.relativePath) differs")
		}

		// A read spanning all three files must reassemble correctly.
		let spanning = try await storage.read(BlockRequest(pieceIndex: 0, begin: 0, length: 128))
		#expect(spanning == payload.prefix(128))
		await storage.close()
	}

	@Test("Skipped files are not written to disk")
	func skipsDeselectedFiles() async throws {
		let (metainfo, payload) = Fixtures.multiFileTorrent(fileSizes: [256, 256], pieceLength: 128)
		let directory = Fixtures.temporaryDirectory()
		let storage = TorrentStorage(metainfo: metainfo, downloadDirectory: directory)
		await storage.setSkippedFiles([1])

		for index in 0..<metainfo.pieceCount {
			let range = metainfo.byteRange(ofPiece: index)
			try await storage.write(piece: index, data: payload.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)))
		}
		await storage.flush()

		let kept = await storage.url(for: metainfo.files[0])
		let skipped = await storage.url(for: metainfo.files[1])
		#expect(FileManager.default.fileExists(atPath: kept.path))
		#expect(!FileManager.default.fileExists(atPath: skipped.path))
		await storage.close()
	}
}

@Suite("Trackers")
struct TrackerTests {

	@Test("Parses a compact HTTP announce response")
	func parsesCompactResponse() throws {
		var peers = Data()
		peers.append(contentsOf: [127, 0, 0, 1, 0x1A, 0xE1])
		peers.append(contentsOf: [192, 168, 1, 10, 0xC8, 0xD5])

		let body = Bencode.encode(.dictionary([
			"interval": .integer(1_800),
			"min interval": .integer(900),
			"complete": .integer(12),
			"incomplete": .integer(34),
			"peers": .bytes(peers),
		]))

		let response = try HTTPTracker.parse(body)
		#expect(response.interval == 1_800)
		#expect(response.minimumInterval == 900)
		#expect(response.seeders == 12)
		#expect(response.leechers == 34)
		#expect(response.peers.count == 2)
		#expect(response.peers[0] == PeerAddress(host: "127.0.0.1", port: 6881))
	}

	@Test("Surfaces a tracker failure as an error")
	func surfacesFailure() {
		let body = Bencode.encode(.dictionary([
			"failure reason": .bytes(Data("torrent not registered".utf8)),
		]))
		#expect(throws: TrackerError.self) { try HTTPTracker.parse(body) }
	}

	@Test("Parses the dictionary form of the peer list")
	func parsesDictionaryPeers() throws {
		let body = Bencode.encode(.dictionary([
			"interval": .integer(600),
			"peers": .list([
				.dictionary(["ip": .bytes(Data("10.1.2.3".utf8)), "port": .integer(51_413)]),
				.dictionary(["ip": .bytes(Data("10.1.2.4".utf8)), "port": .integer(0)]),
			]),
		]))
		let response = try HTTPTracker.parse(body)
		#expect(response.peers == [PeerAddress(host: "10.1.2.3", port: 51_413)])
	}

	@Test("Chooses the right client for each tracker scheme")
	func choosesClient() throws {
		#expect(try TrackerFactory.make(url: "http://a.example/announce") is HTTPTracker)
		#expect(try TrackerFactory.make(url: "https://a.example/announce") is HTTPTracker)
		#expect(try TrackerFactory.make(url: "udp://a.example:1337/announce") is UDPTracker)
		#expect(throws: TrackerError.self) { try TrackerFactory.make(url: "wss://a.example") }
	}

	@Test("Info-hashes are percent-encoded byte by byte")
	func encodesInfoHash() {
		let hash = InfoHash(raw: Data([0x12, 0x34, 0x56] + Array(repeating: UInt8(0x61), count: 17)))!
		#expect(hash.urlEncoded.hasPrefix("%124V"))
		#expect(hash.urlEncoded.hasSuffix(String(repeating: "a", count: 17)))
	}
}

@Suite("DHT routing")
struct RoutingTableTests {

	@Test("Distance is XOR and the closest node wins")
	func distanceOrdering() {
		let local = NodeID(raw: Data(repeating: 0, count: 20))!
		var table = RoutingTable(localID: local)

		let near = NodeID(raw: Data([0x00] + Array(repeating: UInt8(0), count: 18) + [0x01]))!
		let far = NodeID(raw: Data([0xFF] + Array(repeating: UInt8(0), count: 19)))!
		table.insert(DHTNode(id: near, address: PeerAddress(host: "1.1.1.1", port: 1)))
		table.insert(DHTNode(id: far, address: PeerAddress(host: "2.2.2.2", port: 2)))

		#expect(table.closest(to: local, count: 1).first?.id == near)
		#expect(table.nodeCount == 2)
	}

	@Test("Buckets hold at most eight nodes")
	func bucketsAreBounded() {
		let local = NodeID(raw: Data(repeating: 0x00, count: 20))!
		var table = RoutingTable(localID: local)

		// All of these share zero leading bits with us, so they land in one bucket.
		for index in 0..<20 {
			let id = NodeID(raw: Data([0x80, UInt8(index)] + Array(repeating: UInt8(0), count: 18)))!
			table.insert(DHTNode(id: id, address: PeerAddress(host: "10.0.0.\(index + 1)", port: 6881)))
		}
		#expect(table.nodeCount == RoutingTable.bucketSize)
	}

	@Test("Compact node info round-trips")
	func compactRoundTrip() {
		let nodes = [
			DHTNode(id: .random(), address: PeerAddress(host: "8.8.8.8", port: 6881)),
			DHTNode(id: .random(), address: PeerAddress(host: "1.2.3.4", port: 51_413)),
		]
		let decoded = RoutingTable.decodeCompact(RoutingTable.encodeCompact(nodes))
		#expect(decoded.count == 2)
		#expect(decoded[0].id == nodes[0].id)
		#expect(decoded[1].address == nodes[1].address)
	}

	@Test("Nodes are evicted after repeated failures")
	func evictsBadNodes() {
		let local = NodeID.random()
		var table = RoutingTable(localID: local)
		let node = DHTNode(id: .random(), address: PeerAddress(host: "9.9.9.9", port: 6881))
		table.insert(node)

		for _ in 0..<3 { table.recordFailure(id: node.id) }
		#expect(table.nodeCount == 0)
	}
}
