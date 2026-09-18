import Foundation
import Testing
@testable import TorrentKit

@Suite("Bencode")
struct BencodeTests {

	@Test("Decodes the four bencode types")
	func decodesPrimitives() throws {
		#expect(try Bencode.decode(Data("i42e".utf8)) == .integer(42))
		#expect(try Bencode.decode(Data("i-13e".utf8)) == .integer(-13))
		#expect(try Bencode.decode(Data("4:spam".utf8)) == .bytes(Data("spam".utf8)))
		#expect(try Bencode.decode(Data("0:".utf8)) == .bytes(Data()))
		#expect(try Bencode.decode(Data("li1ei2ee".utf8)) == .list([.integer(1), .integer(2)]))
		#expect(try Bencode.decode(Data("d3:bar4:spam3:fooi42ee".utf8)) == .dictionary([
			"bar": .bytes(Data("spam".utf8)),
			"foo": .integer(42),
		]))
	}

	@Test("Round-trips with canonical key ordering")
	func roundTripsCanonically() throws {
		let value = BencodeValue.dictionary([
			"zebra": .integer(1),
			"alpha": .list([.bytes(Data("x".utf8))]),
			"middle": .dictionary(["k": .integer(0)]),
		])
		let encoded = Bencode.encode(value)
		#expect(String(decoding: encoded, as: UTF8.self) == "d5:alphal1:xe6:middled1:ki0ee5:zebrai1ee")
		#expect(try Bencode.decode(encoded) == value)
	}

	@Test("Preserves binary strings that are not valid UTF-8")
	func preservesBinary() throws {
		var raw = Data("3:".utf8)
		raw.append(contentsOf: [0xFF, 0x00, 0xFE])
		let decoded = try Bencode.decode(raw)
		#expect(decoded.dataValue == Data([0xFF, 0x00, 0xFE]))
	}

	@Test("Rejects malformed input instead of guessing")
	func rejectsMalformed() {
		#expect(throws: (any Error).self) { try Bencode.decode(Data("i42".utf8)) }
		#expect(throws: (any Error).self) { try Bencode.decode(Data("5:abc".utf8)) }
		#expect(throws: (any Error).self) { try Bencode.decode(Data("li1e".utf8)) }
		#expect(throws: (any Error).self) { try Bencode.decode(Data("i42eextra".utf8)) }
		#expect(throws: (any Error).self) { try Bencode.decode(Data("x".utf8)) }
	}

	@Test("Reports the byte range of each top-level value")
	func reportsRanges() throws {
		let data = Data("d4:infod6:lengthi5eee".utf8)
		let (value, ranges) = try Bencode.decodeDictionaryWithRanges(data)
		let infoRange = try #require(ranges["info"])
		#expect(value["info"]?["length"]?.integerValue == 5)
		#expect(String(decoding: data.subdata(in: infoRange), as: UTF8.self) == "d6:lengthi5ee")
	}
}
