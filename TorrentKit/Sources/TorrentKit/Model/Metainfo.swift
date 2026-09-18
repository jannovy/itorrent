import Foundation

/// One file inside a torrent, resolved to its absolute position in the
/// torrent's flat byte stream so the storage layer can map pieces onto files.
public struct TorrentFile: Hashable, Sendable, Identifiable {
	public let index: Int
	public let path: [String]
	public let length: Int64
	public let offset: Int64
	/// BEP 47 padding files exist only to align real files to piece boundaries
	/// and must never be shown or written as user content.
	public let isPadding: Bool

	public var id: Int { index }
	public var name: String { path.last ?? "" }
	public var relativePath: String { path.joined(separator: "/") }
	public var range: Range<Int64> { offset..<(offset + length) }
}

public struct TorrentMetainfo: Sendable, Equatable {
	public let infoHash: InfoHash
	public let name: String
	public let pieceLength: Int
	public let pieceHashes: [Data]
	public let files: [TorrentFile]
	public let totalLength: Int64
	public let isPrivate: Bool
	public let comment: String?
	public let createdBy: String?
	public let creationDate: Date?
	/// Tiered announce list (BEP 12); a single-tracker torrent yields one tier.
	public let trackerTiers: [[String]]
	public let webSeeds: [String]
	/// The raw bencoded `info` dictionary, needed to serve BEP 9 metadata
	/// requests and to write the torrent back to disk.
	public let rawInfoDictionary: Data

	public var pieceCount: Int { pieceHashes.count }
	public var isMultiFile: Bool { files.count > 1 }
	public var contentFiles: [TorrentFile] { files.filter { !$0.isPadding } }

	public func pieceSize(at index: Int) -> Int {
		guard index == pieceCount - 1 else { return pieceLength }
		let remainder = Int(totalLength % Int64(pieceLength))
		return remainder == 0 ? pieceLength : remainder
	}

	public func byteRange(ofPiece index: Int) -> Range<Int64> {
		let start = Int64(index) * Int64(pieceLength)
		return start..<(start + Int64(pieceSize(at: index)))
	}
}

public enum MetainfoError: Error, LocalizedError {
	case missingInfoDictionary
	case missingField(String)
	case malformedPieces
	case emptyTorrent
	case infoHashMismatch

	public var errorDescription: String? {
		switch self {
		case .missingInfoDictionary: "The torrent has no 'info' dictionary."
		case let .missingField(name): "The torrent is missing the '\(name)' field."
		case .malformedPieces: "The piece hash list is malformed."
		case .emptyTorrent: "The torrent contains no files."
		case .infoHashMismatch: "The downloaded metadata does not match the requested info-hash."
		}
	}
}

public extension TorrentMetainfo {

	/// Parses a `.torrent` file.
	init(fileContents data: Data) throws {
		let (root, ranges) = try Bencode.decodeDictionaryWithRanges(data)
		guard let infoRange = ranges["info"], case .dictionary? = root["info"] else {
			throw MetainfoError.missingInfoDictionary
		}
		let rawInfo = data.subdata(in: infoRange)

		var tiers: [[String]] = []
		if let announceList = root["announce-list"]?.listValue {
			for tier in announceList {
				let urls = tier.listValue?.compactMap(\.stringValue) ?? []
				if !urls.isEmpty { tiers.append(urls) }
			}
		}
		if tiers.isEmpty, let announce = root["announce"]?.stringValue, !announce.isEmpty {
			tiers = [[announce]]
		}

		var webSeeds: [String] = []
		if let list = root["url-list"]?.listValue {
			webSeeds = list.compactMap(\.stringValue)
		} else if let single = root["url-list"]?.stringValue {
			webSeeds = [single]
		}

		try self.init(
			rawInfoDictionary: rawInfo,
			trackerTiers: tiers,
			webSeeds: webSeeds,
			comment: root["comment"]?.stringValue,
			createdBy: root["created by"]?.stringValue,
			creationDate: root["creation date"]?.integerValue.map { Date(timeIntervalSince1970: TimeInterval($0)) }
		)
	}

	/// Builds metainfo from a bare `info` dictionary, which is what a magnet
	/// link download produces (BEP 9).
	init(
		rawInfoDictionary: Data,
		trackerTiers: [[String]] = [],
		webSeeds: [String] = [],
		comment: String? = nil,
		createdBy: String? = nil,
		creationDate: Date? = nil,
		expectedInfoHash: InfoHash? = nil
	) throws {
		let infoHash = InfoHash.sha1(of: rawInfoDictionary)
		if let expectedInfoHash, expectedInfoHash != infoHash {
			throw MetainfoError.infoHashMismatch
		}

		guard let info = try Bencode.decode(rawInfoDictionary).dictionaryValue else {
			throw MetainfoError.missingInfoDictionary
		}
		guard let pieceLength = info["piece length"]?.integerValue, pieceLength > 0 else {
			throw MetainfoError.missingField("piece length")
		}
		guard let piecesBlob = info["pieces"]?.dataValue, piecesBlob.count % 20 == 0 else {
			throw MetainfoError.malformedPieces
		}
		let name = info["name"]?.stringValue ?? infoHash.hex

		var hashes: [Data] = []
		hashes.reserveCapacity(piecesBlob.count / 20)
		for start in stride(from: 0, to: piecesBlob.count, by: 20) {
			hashes.append(piecesBlob.subdata(in: start..<(start + 20)))
		}

		var files: [TorrentFile] = []
		var offset: Int64 = 0

		if let fileList = info["files"]?.listValue, !fileList.isEmpty {
			for (index, entry) in fileList.enumerated() {
				guard let length = entry["length"]?.integerValue else {
					throw MetainfoError.missingField("files[\(index)].length")
				}
				// `path.utf-8` is a mojibake-repair field some clients add; it
				// is more reliable than `path` when both exist.
				let rawPath = entry["path.utf-8"]?.listValue ?? entry["path"]?.listValue ?? []
				let components = rawPath.compactMap(\.stringValue).map(Self.sanitise).filter { !$0.isEmpty }
				let attributes = entry["attr"]?.stringValue ?? ""
				let isPadding = attributes.contains("p") || components.first == ".pad" || components.last?.hasPrefix("_____padding") == true

				files.append(TorrentFile(
					index: index,
					path: components.isEmpty ? ["file\(index)"] : components,
					length: Int64(length),
					offset: offset,
					isPadding: isPadding
				))
				offset += Int64(length)
			}
		} else {
			guard let length = info["length"]?.integerValue else {
				throw MetainfoError.missingField("length")
			}
			files = [TorrentFile(index: 0, path: [Self.sanitise(name)], length: Int64(length), offset: 0, isPadding: false)]
			offset = Int64(length)
		}

		guard offset > 0 else { throw MetainfoError.emptyTorrent }

		let expectedPieces = Int((offset + Int64(pieceLength) - 1) / Int64(pieceLength))
		guard expectedPieces == hashes.count else { throw MetainfoError.malformedPieces }

		self.infoHash = infoHash
		self.name = name
		self.pieceLength = pieceLength
		self.pieceHashes = hashes
		self.files = files
		self.totalLength = offset
		self.isPrivate = (info["private"]?.integerValue ?? 0) == 1
		self.comment = comment
		self.createdBy = createdBy
		self.creationDate = creationDate
		self.trackerTiers = trackerTiers
		self.webSeeds = webSeeds
		self.rawInfoDictionary = rawInfoDictionary
	}

	/// Re-serialises a complete `.torrent` file so downloads started from a
	/// magnet link can be exported and resumed without the network.
	func torrentFileData() -> Data {
		var root: [String: BencodeValue] = [:]
		if let info = try? Bencode.decode(rawInfoDictionary) {
			root["info"] = info
		}
		if let first = trackerTiers.first?.first {
			root["announce"] = .bytes(Data(first.utf8))
		}
		if !trackerTiers.isEmpty {
			root["announce-list"] = .list(trackerTiers.map { tier in
				.list(tier.map { .bytes(Data($0.utf8)) })
			})
		}
		if let comment { root["comment"] = .bytes(Data(comment.utf8)) }
		if let createdBy { root["created by"] = .bytes(Data(createdBy.utf8)) }
		if let creationDate { root["creation date"] = .integer(Int(creationDate.timeIntervalSince1970)) }
		return Bencode.encode(.dictionary(root))
	}

	/// Strips path components that would let a hostile torrent escape its
	/// download directory.
	private static func sanitise(_ component: String) -> String {
		var cleaned = component.replacingOccurrences(of: "/", with: "_")
		cleaned = cleaned.replacingOccurrences(of: "\0", with: "")
		if cleaned == ".." || cleaned == "." { return "" }
		return cleaned
	}
}
