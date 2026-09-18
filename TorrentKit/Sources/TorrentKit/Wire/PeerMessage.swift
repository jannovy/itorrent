import Foundation

/// A block request: piece index, byte offset within the piece, and length.
public struct BlockRequest: Hashable, Sendable {
	public static let standardLength = 16 * 1024

	public let pieceIndex: Int
	public let begin: Int
	public let length: Int

	public init(pieceIndex: Int, begin: Int, length: Int) {
		self.pieceIndex = pieceIndex
		self.begin = begin
		self.length = length
	}

	public var blockIndex: Int { begin / Self.standardLength }
}

/// A message in the BitTorrent peer wire protocol (BEP 3), plus the extension
/// message from BEP 10.
public enum PeerMessage: Sendable, Equatable {
	case keepAlive
	case choke
	case unchoke
	case interested
	case notInterested
	case have(pieceIndex: Int)
	case bitfield(Data)
	case request(BlockRequest)
	case piece(pieceIndex: Int, begin: Int, block: Data)
	case cancel(BlockRequest)
	/// DHT port announcement (BEP 5).
	case port(UInt16)
	/// Extended message (BEP 10); id 0 is the extension handshake.
	case extended(id: UInt8, payload: Data)

	enum Identifier: UInt8 {
		case choke = 0, unchoke = 1, interested = 2, notInterested = 3
		case have = 4, bitfield = 5, request = 6, piece = 7, cancel = 8, port = 9
		case extended = 20
	}
}

public enum PeerMessageError: Error {
	case truncated
	case unknownIdentifier(UInt8)
	case oversized(Int)
}

public extension PeerMessage {

	/// Serialises to the wire format: 4-byte big-endian length prefix, then the
	/// payload. A zero-length message is the keep-alive.
	func encoded() -> Data {
		var body = Data()

		switch self {
		case .keepAlive:
			return Data([0, 0, 0, 0])

		case .choke: body.append(Identifier.choke.rawValue)
		case .unchoke: body.append(Identifier.unchoke.rawValue)
		case .interested: body.append(Identifier.interested.rawValue)
		case .notInterested: body.append(Identifier.notInterested.rawValue)

		case let .have(pieceIndex):
			body.append(Identifier.have.rawValue)
			body.appendBigEndian(UInt32(pieceIndex))

		case let .bitfield(bits):
			body.append(Identifier.bitfield.rawValue)
			body.append(bits)

		case let .request(request):
			body.append(Identifier.request.rawValue)
			body.appendBigEndian(UInt32(request.pieceIndex))
			body.appendBigEndian(UInt32(request.begin))
			body.appendBigEndian(UInt32(request.length))

		case let .piece(pieceIndex, begin, block):
			body.append(Identifier.piece.rawValue)
			body.appendBigEndian(UInt32(pieceIndex))
			body.appendBigEndian(UInt32(begin))
			body.append(block)

		case let .cancel(request):
			body.append(Identifier.cancel.rawValue)
			body.appendBigEndian(UInt32(request.pieceIndex))
			body.appendBigEndian(UInt32(request.begin))
			body.appendBigEndian(UInt32(request.length))

		case let .port(port):
			body.append(Identifier.port.rawValue)
			body.appendBigEndian(port)

		case let .extended(id, payload):
			body.append(Identifier.extended.rawValue)
			body.append(id)
			body.append(payload)
		}

		var output = Data()
		output.appendBigEndian(UInt32(body.count))
		output.append(body)
		return output
	}

	/// Decodes one message body (the bytes after the length prefix).
	static func decode(body: Data) throws -> PeerMessage {
		guard !body.isEmpty else { return .keepAlive }
		let bytes = [UInt8](body)
		guard let identifier = Identifier(rawValue: bytes[0]) else {
			throw PeerMessageError.unknownIdentifier(bytes[0])
		}
		let payload = body.dropFirst()

		func integer(at offset: Int) throws -> Int {
			let base = payload.startIndex + offset
			guard base + 4 <= payload.endIndex else { throw PeerMessageError.truncated }
			return Int(
				UInt32(payload[base]) << 24 | UInt32(payload[base + 1]) << 16
					| UInt32(payload[base + 2]) << 8 | UInt32(payload[base + 3])
			)
		}

		switch identifier {
		case .choke: return .choke
		case .unchoke: return .unchoke
		case .interested: return .interested
		case .notInterested: return .notInterested

		case .have:
			return .have(pieceIndex: try integer(at: 0))

		case .bitfield:
			return .bitfield(Data(payload))

		case .request:
			return .request(BlockRequest(
				pieceIndex: try integer(at: 0),
				begin: try integer(at: 4),
				length: try integer(at: 8)
			))

		case .piece:
			let pieceIndex = try integer(at: 0)
			let begin = try integer(at: 4)
			let block = payload.dropFirst(8)
			return .piece(pieceIndex: pieceIndex, begin: begin, block: Data(block))

		case .cancel:
			return .cancel(BlockRequest(
				pieceIndex: try integer(at: 0),
				begin: try integer(at: 4),
				length: try integer(at: 8)
			))

		case .port:
			guard payload.count >= 2 else { throw PeerMessageError.truncated }
			let base = payload.startIndex
			return .port(UInt16(payload[base]) << 8 | UInt16(payload[base + 1]))

		case .extended:
			guard let id = payload.first else { throw PeerMessageError.truncated }
			return .extended(id: id, payload: Data(payload.dropFirst()))
		}
	}
}

/// The 68-byte BitTorrent handshake.
public struct PeerHandshake: Sendable, Equatable {
	public static let protocolName = "BitTorrent protocol"
	public static let byteCount = 68

	/// The twenty bytes every plaintext handshake opens with: the length prefix
	/// and the protocol name. Used to tell a plaintext peer from an encrypted
	/// one before either has said anything else.
	public static let protocolHeader = Data([UInt8(protocolName.utf8.count)]) + Data(protocolName.utf8)

	public let infoHash: InfoHash
	public let peerID: Data
	public let reserved: Data

	public init(infoHash: InfoHash, peerID: Data, reserved: Data = PeerHandshake.defaultReservedBytes) {
		self.infoHash = infoHash
		self.peerID = peerID
		self.reserved = reserved
	}

	/// Advertises the extension protocol (bit 20, BEP 10) and DHT (bit 0 of the
	/// last byte, BEP 5).
	public static var defaultReservedBytes: Data {
		var bytes = [UInt8](repeating: 0, count: 8)
		bytes[5] |= 0x10
		bytes[7] |= 0x01
		return Data(bytes)
	}

	public var supportsExtensionProtocol: Bool {
		reserved.count == 8 && reserved[reserved.startIndex + 5] & 0x10 != 0
	}

	public var supportsDHT: Bool {
		reserved.count == 8 && reserved[reserved.startIndex + 7] & 0x01 != 0
	}

	public func encoded() -> Data {
		var data = Data()
		data.append(UInt8(Self.protocolName.utf8.count))
		data.append(contentsOf: Array(Self.protocolName.utf8))
		data.append(reserved)
		data.append(infoHash.raw)
		data.append(peerID)
		return data
	}

	public init?(data: Data) {
		guard data.count >= Self.byteCount else { return nil }
		let bytes = [UInt8](data.prefix(Self.byteCount))
		guard bytes[0] == UInt8(Self.protocolName.utf8.count),
		      String(decoding: bytes[1...19], as: UTF8.self) == Self.protocolName,
		      let infoHash = InfoHash(raw: Data(bytes[28..<48]))
		else { return nil }

		self.reserved = Data(bytes[20..<28])
		self.infoHash = infoHash
		self.peerID = Data(bytes[48..<68])
	}
}

extension Data {
	mutating func appendBigEndian(_ value: UInt32) {
		append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
	}

	mutating func appendBigEndian(_ value: UInt16) {
		append(contentsOf: [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
	}

	mutating func appendBigEndian(_ value: UInt64) {
		append(contentsOf: (0..<8).reversed().map { UInt8(value >> (8 * UInt64($0)) & 0xFF) })
	}

	func bigEndianUInt32(at offset: Int) -> UInt32? {
		let base = startIndex + offset
		guard base + 4 <= endIndex else { return nil }
		return UInt32(self[base]) << 24 | UInt32(self[base + 1]) << 16 | UInt32(self[base + 2]) << 8 | UInt32(self[base + 3])
	}

	func bigEndianUInt16(at offset: Int) -> UInt16? {
		let base = startIndex + offset
		guard base + 2 <= endIndex else { return nil }
		return UInt16(self[base]) << 8 | UInt16(self[base + 1])
	}
}
