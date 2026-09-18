import CryptoKit
import Foundation
import Testing
@testable import TorrentKit

@Suite("Metainfo")
struct MetainfoTests {

	@Test("Parses a single-file torrent")
	func parsesSingleFile() throws {
		let payload = Fixtures.payload(byteCount: 40_000)
		let data = Fixtures.torrentFileData(payload: payload, pieceLength: 16_384)
		let metainfo = try TorrentMetainfo(fileContents: data)

		#expect(metainfo.name == "sample.bin")
		#expect(metainfo.totalLength == 40_000)
		#expect(metainfo.pieceLength == 16_384)
		#expect(metainfo.pieceCount == 3)
		#expect(metainfo.files.count == 1)
		#expect(metainfo.isMultiFile == false)
		#expect(metainfo.comment == "fixture")
		#expect(metainfo.trackerTiers == [["http://tracker.example/announce"]])
	}

	@Test("Computes the info-hash over the original bytes, not a re-encoding")
	func computesInfoHashFromSourceBytes() throws {
		let payload = Fixtures.payload(byteCount: 1_000)
		let data = Fixtures.torrentFileData(payload: payload, pieceLength: 512)
		let metainfo = try TorrentMetainfo(fileContents: data)

		let (_, ranges) = try Bencode.decodeDictionaryWithRanges(data)
		let infoRange = try #require(ranges["info"])
		let expected = Data(Insecure.SHA1.hash(data: data.subdata(in: infoRange)))
		#expect(metainfo.infoHash.raw == expected)
	}

	@Test("Assigns sequential offsets to multi-file torrents")
	func assignsOffsets() throws {
		let (metainfo, _) = Fixtures.multiFileTorrent(fileSizes: [100, 250, 30], pieceLength: 128)
		#expect(metainfo.files.map(\.offset) == [0, 100, 350])
		#expect(metainfo.totalLength == 380)
		#expect(metainfo.files[1].relativePath == "dir1/file1.dat")
		#expect(metainfo.isMultiFile)
	}

	@Test("Last piece is shorter than the others")
	func lastPieceIsShort() {
		let (metainfo, _) = Fixtures.singleFileTorrent(payload: Fixtures.payload(byteCount: 2_500), pieceLength: 1_024)
		#expect(metainfo.pieceCount == 3)
		#expect(metainfo.pieceSize(at: 0) == 1_024)
		#expect(metainfo.pieceSize(at: 2) == 452)
		#expect(metainfo.byteRange(ofPiece: 2) == 2_048..<2_500)
	}

	@Test("Rejects a torrent whose piece count does not match its length")
	func rejectsInconsistentTorrent() {
		let info = BencodeValue.dictionary([
			"name": .bytes(Data("x".utf8)),
			"piece length": .integer(1_024),
			"pieces": .bytes(Data(repeating: 0, count: 20)),
			"length": .integer(10_000),
		])
		#expect(throws: MetainfoError.self) {
			try TorrentMetainfo(rawInfoDictionary: Bencode.encode(info))
		}
	}

	@Test("Refuses metadata that does not match the requested info-hash")
	func refusesMismatchedMetadata() {
		let (metainfo, _) = Fixtures.singleFileTorrent(payload: Fixtures.payload(byteCount: 100), pieceLength: 64)
		let wrongHash = InfoHash(hex: String(repeating: "ab", count: 20))!
		#expect(throws: MetainfoError.self) {
			try TorrentMetainfo(rawInfoDictionary: metainfo.rawInfoDictionary, expectedInfoHash: wrongHash)
		}
	}

	@Test("Strips path components that would escape the download folder")
	func stripsTraversal() throws {
		let info = BencodeValue.dictionary([
			"name": .bytes(Data("bundle".utf8)),
			"piece length": .integer(1_024),
			"pieces": .bytes(Data(repeating: 0, count: 20)),
			"files": .list([
				.dictionary([
					"length": .integer(10),
					"path": .list([.bytes(Data("..".utf8)), .bytes(Data("..".utf8)), .bytes(Data("evil.sh".utf8))]),
				]),
			]),
		])
		let metainfo = try TorrentMetainfo(rawInfoDictionary: Bencode.encode(info))
		#expect(metainfo.files[0].path == ["evil.sh"])
	}

	@Test("Re-exports a torrent file that parses back to the same info-hash")
	func reExportsTorrentFile() throws {
		let payload = Fixtures.payload(byteCount: 5_000)
		let original = try TorrentMetainfo(
			fileContents: Fixtures.torrentFileData(payload: payload, pieceLength: 1_024)
		)
		let exported = try TorrentMetainfo(fileContents: original.torrentFileData())
		#expect(exported.infoHash == original.infoHash)
		#expect(exported.name == original.name)
	}
}
