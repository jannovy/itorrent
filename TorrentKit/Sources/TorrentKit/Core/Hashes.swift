import CryptoKit
import Foundation

/// A 20-byte BitTorrent info-hash.
public struct InfoHash: Hashable, Sendable, CustomStringConvertible {
	public static let byteCount = 20

	public let raw: Data

	public init?(raw: Data) {
		guard raw.count == Self.byteCount else { return nil }
		self.raw = raw
	}

	public init?(hex: String) {
		guard let data = Data(hexEncoded: hex), data.count == Self.byteCount else { return nil }
		self.raw = data
	}

	/// Magnet links may carry the hash base32-encoded (BEP 9 allows both).
	public init?(base32: String) {
		guard let data = Data(base32Encoded: base32), data.count == Self.byteCount else { return nil }
		self.raw = data
	}

	public static func sha1(of data: Data) -> InfoHash {
		InfoHash(raw: Data(Insecure.SHA1.hash(data: data)))!
	}

	public var hex: String { raw.hexEncodedString() }

	/// Trackers expect the hash percent-encoded byte-by-byte, not as hex.
	public var urlEncoded: String { raw.percentEncodedForTracker() }

	public var description: String { hex }

	/// Shortened form for UI, e.g. `a1b2c3d4…9f0e`.
	public var abbreviated: String {
		let text = hex
		return "\(text.prefix(8))…\(text.suffix(4))"
	}
}

/// Our own 20-byte peer id. Uses the Azureus-style convention: `-SW0100-` plus
/// twelve random bytes, so remote clients can identify us in their peer lists.
public struct PeerID: Hashable, Sendable {
	public static let clientPrefix = "-IT1000-"

	public let raw: Data

	public init?(raw: Data) {
		guard raw.count == 20 else { return nil }
		self.raw = raw
	}

	public static func random() -> PeerID {
		var data = Data(Self.clientPrefix.utf8)
		data.append(contentsOf: (0..<(20 - data.count)).map { _ in UInt8.random(in: 0...255) })
		return PeerID(raw: data)!
	}

	public var urlEncoded: String { raw.percentEncodedForTracker() }

	/// Best-effort client name, e.g. `qBittorrent 4.6.3` or `Transmission 4.0.5`.
	public var clientName: String {
		PeerIDDecoder.clientName(for: raw)
	}
}

public extension Data {
	init?(hexEncoded string: String) {
		let characters = Array(string.utf8)
		guard characters.count % 2 == 0 else { return nil }
		var bytes = [UInt8]()
		bytes.reserveCapacity(characters.count / 2)
		var index = 0
		while index < characters.count {
			guard let high = Self.nibble(characters[index]), let low = Self.nibble(characters[index + 1]) else {
				return nil
			}
			bytes.append(high << 4 | low)
			index += 2
		}
		self.init(bytes)
	}

	private static func nibble(_ character: UInt8) -> UInt8? {
		switch character {
		case UInt8(ascii: "0")...UInt8(ascii: "9"): character - UInt8(ascii: "0")
		case UInt8(ascii: "a")...UInt8(ascii: "f"): character - UInt8(ascii: "a") + 10
		case UInt8(ascii: "A")...UInt8(ascii: "F"): character - UInt8(ascii: "A") + 10
		default: nil
		}
	}

	func hexEncodedString() -> String {
		map { String(format: "%02x", $0) }.joined()
	}

	init?(base32Encoded string: String) {
		let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
		var lookup = [UInt8: UInt8]()
		for (index, character) in alphabet.enumerated() { lookup[character] = UInt8(index) }

		var bytes = [UInt8]()
		var buffer: UInt32 = 0
		var bitsInBuffer: UInt32 = 0

		for character in string.uppercased().utf8 {
			if character == UInt8(ascii: "=") { break }
			guard let value = lookup[character] else { return nil }
			buffer = buffer << 5 | UInt32(value)
			bitsInBuffer += 5
			if bitsInBuffer >= 8 {
				bitsInBuffer -= 8
				bytes.append(UInt8((buffer >> bitsInBuffer) & 0xFF))
			}
		}
		self.init(bytes)
	}

	/// Percent-encodes every byte that is not an RFC 3986 unreserved character.
	/// `URLComponents` cannot be used here: it insists on valid UTF-8, while
	/// info-hashes are arbitrary binary.
	func percentEncodedForTracker() -> String {
		var output = ""
		output.reserveCapacity(count * 3)
		for byte in self {
			switch byte {
			case UInt8(ascii: "a")...UInt8(ascii: "z"),
			     UInt8(ascii: "A")...UInt8(ascii: "Z"),
			     UInt8(ascii: "0")...UInt8(ascii: "9"),
			     UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
				output.append(Character(UnicodeScalar(byte)))
			default:
				output += String(format: "%%%02X", byte)
			}
		}
		return output
	}
}

enum PeerIDDecoder {
	private static let azureusStyle: [String: String] = [
		"AZ": "Azureus", "BT": "BitTorrent", "DE": "Deluge", "LT": "libtorrent",
		"lt": "libTorrent", "qB": "qBittorrent", "TR": "Transmission", "UT": "µTorrent",
		"UM": "µTorrent Mac", "UW": "µTorrent Web", "KT": "KTorrent", "TL": "Tribler",
		"FD": "Free Download Manager", "WW": "WebTorrent", "IT": "iTorrent", "BL": "BitComet",
		"RT": "Retriever", "PI": "PicoTorrent", "XL": "Xunlei", "AN": "Ares",
	]

	static func clientName(for peerID: Data) -> String {
		let bytes = [UInt8](peerID)
		guard bytes.count == 20 else { return "unknown" }

		// Azureus style: -XX1234-
		if bytes[0] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-") {
			let code = String(decoding: bytes[1...2], as: UTF8.self)
			let name = azureusStyle[code] ?? code
			let digits = bytes[3...6].map { Character(UnicodeScalar($0)) }
			let version = versionString(from: digits)
			return version.isEmpty ? name : "\(name) \(version)"
		}

		// Shadow style: a single letter followed by version characters.
		if let first = bytes.first, (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(first) {
			let code = String(UnicodeScalar(first))
			if let name = azureusStyle[code] { return name }
		}

		let printable = bytes.prefix(8).filter { $0 >= 0x20 && $0 < 0x7F }
		return printable.isEmpty ? "unknown" : String(decoding: printable, as: UTF8.self)
	}

	private static func versionString(from digits: [Character]) -> String {
		let components = digits.map { character -> String in
			if let value = character.hexDigitValue { return String(value) }
			return String(character)
		}
		guard components.count == 4 else { return "" }
		// Trailing zero patch levels are noise in a peer list.
		if components[3] == "0" {
			return "\(components[0]).\(components[1]).\(components[2])"
		}
		return "\(components[0]).\(components[1]).\(components[2]).\(components[3])"
	}
}
