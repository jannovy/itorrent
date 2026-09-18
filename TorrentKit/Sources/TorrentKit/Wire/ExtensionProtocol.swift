import Foundation

/// BEP 10 extension protocol: the handshake, plus the two extensions that
/// matter in practice — `ut_metadata` (BEP 9, how a magnet link becomes a real
/// torrent) and `ut_pex` (BEP 11, peer exchange).
public enum ExtensionProtocol {
	public static let handshakeID: UInt8 = 0

	public enum Name: String {
		case metadata = "ut_metadata"
		case peerExchange = "ut_pex"
	}

	/// Extension ids we advertise. They are ours to choose; peers echo back
	/// whatever ids *they* want us to use, which is why both sides are tracked.
	public enum LocalID {
		public static let metadata: UInt8 = 1
		public static let peerExchange: UInt8 = 2
	}

	public static func handshakePayload(
		metadataSize: Int?,
		listenPort: UInt16,
		clientVersion: String,
		supportsPeerExchange: Bool
	) -> Data {
		var extensions: [String: BencodeValue] = [
			Name.metadata.rawValue: .integer(Int(LocalID.metadata)),
		]
		if supportsPeerExchange {
			extensions[Name.peerExchange.rawValue] = .integer(Int(LocalID.peerExchange))
		}

		var root: [String: BencodeValue] = [
			"m": .dictionary(extensions),
			"v": .bytes(Data(clientVersion.utf8)),
			"reqq": .integer(250),
		]
		if let metadataSize { root["metadata_size"] = .integer(metadataSize) }
		if listenPort > 0 { root["p"] = .integer(Int(listenPort)) }
		return Bencode.encode(.dictionary(root))
	}

	public struct RemoteHandshake: Sendable {
		public var metadataID: UInt8?
		public var peerExchangeID: UInt8?
		public var metadataSize: Int?
		public var clientVersion: String?
		public var maximumOutstandingRequests: Int?

		public init(payload: Data) {
			guard let root = try? Bencode.decode(payload).dictionaryValue else { return }
			if let mapping = root["m"]?.dictionaryValue {
				// A value of 0 means "I no longer support this extension".
				if let id = mapping[Name.metadata.rawValue]?.integerValue, id > 0, id <= 255 {
					metadataID = UInt8(id)
				}
				if let id = mapping[Name.peerExchange.rawValue]?.integerValue, id > 0, id <= 255 {
					peerExchangeID = UInt8(id)
				}
			}
			metadataSize = root["metadata_size"]?.integerValue
			clientVersion = root["v"]?.stringValue
			maximumOutstandingRequests = root["reqq"]?.integerValue
		}
	}
}

// MARK: - BEP 9 metadata exchange

public enum MetadataMessage: Sendable {
	case request(piece: Int)
	case data(piece: Int, totalSize: Int, payload: Data)
	case reject(piece: Int)

	public static let pieceSize = 16 * 1024

	public func encoded() -> Data {
		switch self {
		case let .request(piece):
			return Bencode.encode(.dictionary(["msg_type": .integer(0), "piece": .integer(piece)]))

		case let .data(piece, totalSize, payload):
			var data = Bencode.encode(.dictionary([
				"msg_type": .integer(1),
				"piece": .integer(piece),
				"total_size": .integer(totalSize),
			]))
			// The raw metadata bytes are appended after the bencoded header.
			data.append(payload)
			return data

		case let .reject(piece):
			return Bencode.encode(.dictionary(["msg_type": .integer(2), "piece": .integer(piece)]))
		}
	}

	public init?(payload: Data) {
		// The header is a bencoded dict followed by binary data, so the dict
		// must be parsed with its extent recorded rather than by decoding the
		// whole payload (which would throw on the trailing bytes).
		guard let (header, length) = MetadataMessage.decodeHeader(payload) else { return nil }
		guard let type = header["msg_type"]?.integerValue, let piece = header["piece"]?.integerValue else { return nil }

		switch type {
		case 0:
			self = .request(piece: piece)
		case 1:
			let totalSize = header["total_size"]?.integerValue ?? 0
			self = .data(piece: piece, totalSize: totalSize, payload: payload.dropFirst(length))
		case 2:
			self = .reject(piece: piece)
		default:
			return nil
		}
	}

	private static func decodeHeader(_ payload: Data) -> ([String: BencodeValue], Int)? {
		// Walk forward until a prefix parses as a complete dictionary.
		var end = min(payload.count, 256)
		while end > 1 {
			if let dictionary = try? Bencode.decode(payload.prefix(end)).dictionaryValue {
				return (dictionary, end)
			}
			end -= 1
		}
		return nil
	}
}

/// Assembles the `info` dictionary from 16 KB chunks fetched from peers.
public final class MetadataDownload {
	public let infoHash: InfoHash
	public let totalSize: Int
	public let pieceCount: Int

	private var pieces: [Int: Data] = [:]
	private var inFlight: Set<Int> = []

	public init?(infoHash: InfoHash, totalSize: Int) {
		// A sane `info` dictionary is well under 16 MB; anything larger is a
		// peer trying to make us allocate.
		guard totalSize > 0, totalSize <= 16 * 1024 * 1024 else { return nil }
		self.infoHash = infoHash
		self.totalSize = totalSize
		self.pieceCount = (totalSize + MetadataMessage.pieceSize - 1) / MetadataMessage.pieceSize
	}

	public var progress: Double {
		pieceCount == 0 ? 0 : Double(pieces.count) / Double(pieceCount)
	}

	public var isComplete: Bool { pieces.count == pieceCount }

	/// Returns up to `limit` piece indices that are neither held nor requested.
	public func nextRequests(limit: Int) -> [Int] {
		guard limit > 0 else { return [] }
		var result: [Int] = []
		for index in 0..<pieceCount where pieces[index] == nil && !inFlight.contains(index) {
			result.append(index)
			inFlight.insert(index)
			if result.count == limit { break }
		}
		return result
	}

	public func markFailed(piece: Int) {
		inFlight.remove(piece)
	}

	public func store(piece index: Int, payload: Data) {
		guard index >= 0, index < pieceCount else { return }
		let expected = index == pieceCount - 1
			? totalSize - index * MetadataMessage.pieceSize
			: MetadataMessage.pieceSize
		guard payload.count == expected else {
			inFlight.remove(index)
			return
		}
		pieces[index] = payload
		inFlight.remove(index)
	}

	/// Returns the assembled `info` dictionary, but only if it hashes to the
	/// info-hash we asked for — otherwise a single malicious peer could feed us
	/// arbitrary metadata.
	public func assembledInfoDictionary() -> Data? {
		guard isComplete else { return nil }
		var data = Data(capacity: totalSize)
		for index in 0..<pieceCount {
			guard let piece = pieces[index] else { return nil }
			data.append(piece)
		}
		guard InfoHash.sha1(of: data) == infoHash else {
			pieces.removeAll()
			return nil
		}
		return data
	}
}

// MARK: - BEP 11 peer exchange

public enum PeerExchange {
	public static func decode(payload: Data) -> [PeerAddress] {
		guard let root = try? Bencode.decode(payload).dictionaryValue else { return [] }
		var peers: [PeerAddress] = []
		if let added = root["added"]?.dataValue {
			peers += PeerAddress.decodeCompact(added, isIPv6: false)
		}
		if let added6 = root["added6"]?.dataValue {
			peers += PeerAddress.decodeCompact(added6, isIPv6: true)
		}
		return peers
	}

	public static func encode(added: [PeerAddress], dropped: [PeerAddress]) -> Data {
		var addedData = Data()
		var addedFlags = Data()
		for peer in added {
			guard let compact = peer.encodeCompact() else { continue }
			addedData.append(compact)
			addedFlags.append(0)
		}
		var droppedData = Data()
		for peer in dropped {
			guard let compact = peer.encodeCompact() else { continue }
			droppedData.append(compact)
		}
		return Bencode.encode(.dictionary([
			"added": .bytes(addedData),
			"added.f": .bytes(addedFlags),
			"dropped": .bytes(droppedData),
		]))
	}
}
