import CryptoKit
import Foundation
@testable import TorrentKit

/// Builds real torrents from real bytes, so the tests exercise the same paths a
/// downloaded torrent does rather than hand-written stubs.
enum Fixtures {

	static func payload(byteCount: Int, seed: UInt8 = 7) -> Data {
		var value = seed
		return Data((0..<byteCount).map { _ in
			value = value &* 31 &+ 17
			return value
		})
	}

	static func singleFileTorrent(
		name: String = "sample.bin",
		payload: Data,
		pieceLength: Int
	) -> (metainfo: TorrentMetainfo, payload: Data) {
		var hashes = Data()
		for start in stride(from: 0, to: payload.count, by: pieceLength) {
			let end = min(payload.count, start + pieceLength)
			hashes.append(Data(Insecure.SHA1.hash(data: payload.subdata(in: start..<end))))
		}

		let info = BencodeValue.dictionary([
			"name": .bytes(Data(name.utf8)),
			"piece length": .integer(pieceLength),
			"pieces": .bytes(hashes),
			"length": .integer(payload.count),
		])
		let metainfo = try! TorrentMetainfo(rawInfoDictionary: Bencode.encode(info))
		return (metainfo, payload)
	}

	static func multiFileTorrent(
		name: String = "bundle",
		fileSizes: [Int],
		pieceLength: Int
	) -> (metainfo: TorrentMetainfo, payload: Data) {
		var payload = Data()
		for (index, size) in fileSizes.enumerated() {
			payload.append(Self.payload(byteCount: size, seed: UInt8(truncatingIfNeeded: index &+ 1)))
		}

		var hashes = Data()
		for start in stride(from: 0, to: payload.count, by: pieceLength) {
			let end = min(payload.count, start + pieceLength)
			hashes.append(Data(Insecure.SHA1.hash(data: payload.subdata(in: start..<end))))
		}

		let files = fileSizes.enumerated().map { index, size in
			BencodeValue.dictionary([
				"length": .integer(size),
				"path": .list([.bytes(Data("dir\(index % 2)".utf8)), .bytes(Data("file\(index).dat".utf8))]),
			])
		}
		let info = BencodeValue.dictionary([
			"name": .bytes(Data(name.utf8)),
			"piece length": .integer(pieceLength),
			"pieces": .bytes(hashes),
			"files": .list(files),
		])
		let metainfo = try! TorrentMetainfo(rawInfoDictionary: Bencode.encode(info))
		return (metainfo, payload)
	}

	/// A complete `.torrent` file, including the announce fields.
	static func torrentFileData(
		payload: Data,
		pieceLength: Int,
		announce: String = "http://tracker.example/announce",
		announceList: [[String]]? = nil
	) -> Data {
		var hashes = Data()
		for start in stride(from: 0, to: payload.count, by: pieceLength) {
			let end = min(payload.count, start + pieceLength)
			hashes.append(Data(Insecure.SHA1.hash(data: payload.subdata(in: start..<end))))
		}
		var root: [String: BencodeValue] = [
			"announce": .bytes(Data(announce.utf8)),
			"comment": .bytes(Data("fixture".utf8)),
			"created by": .bytes(Data("iTorrentTests".utf8)),
			"creation date": .integer(1_700_000_000),
			"info": .dictionary([
				"name": .bytes(Data("sample.bin".utf8)),
				"piece length": .integer(pieceLength),
				"pieces": .bytes(hashes),
				"length": .integer(payload.count),
			]),
		]
		if let announceList {
			root["announce-list"] = .list(announceList.map { tier in
				.list(tier.map { .bytes(Data($0.utf8)) })
			})
		}
		return Bencode.encode(.dictionary(root))
	}

	static func temporaryDirectory() -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("torrentkit-tests", isDirectory: true)
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}
}
