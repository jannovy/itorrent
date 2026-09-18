import Foundation

/// A decoded bencode value. Strings are kept as raw bytes because torrent
/// metadata routinely contains non-UTF-8 paths and binary blobs (piece hashes,
/// compact peer lists), which would be destroyed by an early string conversion.
public enum BencodeValue: Equatable, Sendable {
	case integer(Int)
	case bytes(Data)
	case list([BencodeValue])
	case dictionary([String: BencodeValue])
}

public extension BencodeValue {
	var integerValue: Int? {
		if case let .integer(value) = self { return value }
		return nil
	}

	var dataValue: Data? {
		if case let .bytes(value) = self { return value }
		return nil
	}

	/// Lossy on purpose: metadata that is not valid UTF-8 is still worth
	/// displaying, so invalid sequences become replacement characters rather
	/// than nil.
	var stringValue: String? {
		guard case let .bytes(value) = self else { return nil }
		return String(decoding: value, as: UTF8.self)
	}

	var listValue: [BencodeValue]? {
		if case let .list(value) = self { return value }
		return nil
	}

	var dictionaryValue: [String: BencodeValue]? {
		if case let .dictionary(value) = self { return value }
		return nil
	}

	subscript(key: String) -> BencodeValue? {
		dictionaryValue?[key]
	}
}

public enum BencodeError: Error, LocalizedError {
	case unexpectedEnd
	case invalidPrefix(UInt8, at: Int)
	case invalidInteger(String)
	case invalidLength
	case unterminatedValue
	case trailingGarbage(at: Int)
	case keyNotUTF8

	public var errorDescription: String? {
		switch self {
		case .unexpectedEnd: "Bencode data ended unexpectedly."
		case let .invalidPrefix(byte, offset): "Unexpected byte 0x\(String(byte, radix: 16)) at offset \(offset)."
		case let .invalidInteger(text): "Invalid bencode integer '\(text)'."
		case .invalidLength: "Invalid bencode string length."
		case .unterminatedValue: "Unterminated bencode value."
		case let .trailingGarbage(offset): "Unexpected trailing data at offset \(offset)."
		case .keyNotUTF8: "Dictionary key is not valid UTF-8."
		}
	}
}

public enum Bencode {

	// MARK: - Decoding

	public static func decode(_ data: Data) throws -> BencodeValue {
		var parser = Parser(data: [UInt8](data))
		let value = try parser.parseValue()
		guard parser.index == parser.data.count else {
			throw BencodeError.trailingGarbage(at: parser.index)
		}
		return value
	}

	/// Decodes a top-level dictionary and additionally reports the byte range
	/// each value occupies in the source data.
	///
	/// This is how the info-hash is computed without re-encoding: hashing our
	/// own re-serialisation would silently "fix" non-canonical torrents and
	/// produce a hash no peer agrees with.
	public static func decodeDictionaryWithRanges(
		_ data: Data
	) throws -> (value: [String: BencodeValue], ranges: [String: Range<Int>]) {
		var parser = Parser(data: [UInt8](data))
		let (dictionary, ranges) = try parser.parseDictionaryRecordingRanges()
		return (dictionary, ranges)
	}

	// MARK: - Encoding

	public static func encode(_ value: BencodeValue) -> Data {
		var output = Data()
		append(value, to: &output)
		return output
	}

	private static func append(_ value: BencodeValue, to output: inout Data) {
		switch value {
		case let .integer(number):
			output.append(contentsOf: Array("i\(number)e".utf8))

		case let .bytes(bytes):
			output.append(contentsOf: Array("\(bytes.count):".utf8))
			output.append(bytes)

		case let .list(items):
			output.append(UInt8(ascii: "l"))
			for item in items { append(item, to: &output) }
			output.append(UInt8(ascii: "e"))

		case let .dictionary(pairs):
			output.append(UInt8(ascii: "d"))
			// Bencode requires keys sorted as raw byte strings.
			for key in pairs.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
				append(.bytes(Data(key.utf8)), to: &output)
				append(pairs[key]!, to: &output)
			}
			output.append(UInt8(ascii: "e"))
		}
	}

	// MARK: - Parser

	fileprivate struct Parser {
		let data: [UInt8]
		var index = 0

		mutating func parseValue() throws -> BencodeValue {
			guard index < data.count else { throw BencodeError.unexpectedEnd }

			switch data[index] {
			case UInt8(ascii: "i"):
				return .integer(try parseInteger())
			case UInt8(ascii: "l"):
				return .list(try parseList())
			case UInt8(ascii: "d"):
				return .dictionary(try parseDictionary())
			case UInt8(ascii: "0")...UInt8(ascii: "9"):
				return .bytes(try parseBytes())
			default:
				throw BencodeError.invalidPrefix(data[index], at: index)
			}
		}

		mutating func parseInteger() throws -> Int {
			index += 1 // 'i'
			guard let end = data[index...].firstIndex(of: UInt8(ascii: "e")) else {
				throw BencodeError.unterminatedValue
			}
			let text = String(decoding: data[index..<end], as: UTF8.self)
			guard let number = Int(text) else { throw BencodeError.invalidInteger(text) }
			index = end + 1
			return number
		}

		mutating func parseBytes() throws -> Data {
			guard let colon = data[index...].firstIndex(of: UInt8(ascii: ":")) else {
				throw BencodeError.unterminatedValue
			}
			let lengthText = String(decoding: data[index..<colon], as: UTF8.self)
			guard let length = Int(lengthText), length >= 0 else { throw BencodeError.invalidLength }
			let start = colon + 1
			let end = start + length
			guard end <= data.count else { throw BencodeError.unexpectedEnd }
			index = end
			return Data(data[start..<end])
		}

		mutating func parseList() throws -> [BencodeValue] {
			index += 1 // 'l'
			var items: [BencodeValue] = []
			while true {
				guard index < data.count else { throw BencodeError.unterminatedValue }
				if data[index] == UInt8(ascii: "e") {
					index += 1
					return items
				}
				items.append(try parseValue())
			}
		}

		mutating func parseDictionary() throws -> [String: BencodeValue] {
			index += 1 // 'd'
			var pairs: [String: BencodeValue] = [:]
			while true {
				guard index < data.count else { throw BencodeError.unterminatedValue }
				if data[index] == UInt8(ascii: "e") {
					index += 1
					return pairs
				}
				let key = try parseKey()
				pairs[key] = try parseValue()
			}
		}

		mutating func parseDictionaryRecordingRanges() throws -> ([String: BencodeValue], [String: Range<Int>]) {
			guard index < data.count, data[index] == UInt8(ascii: "d") else {
				throw BencodeError.invalidPrefix(data.first ?? 0, at: index)
			}
			index += 1
			var pairs: [String: BencodeValue] = [:]
			var ranges: [String: Range<Int>] = [:]
			while true {
				guard index < data.count else { throw BencodeError.unterminatedValue }
				if data[index] == UInt8(ascii: "e") {
					index += 1
					return (pairs, ranges)
				}
				let key = try parseKey()
				let start = index
				pairs[key] = try parseValue()
				ranges[key] = start..<index
			}
		}

		private mutating func parseKey() throws -> String {
			let raw = try parseBytes()
			guard let key = String(data: raw, encoding: .utf8) else { throw BencodeError.keyNotUTF8 }
			return key
		}
	}
}
