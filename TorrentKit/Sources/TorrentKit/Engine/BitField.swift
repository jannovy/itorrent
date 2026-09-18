import Foundation

/// A BitTorrent bitfield: bit 0 is the most significant bit of byte 0.
public struct BitField: Equatable, Sendable {
	public private(set) var bytes: Data
	public let bitCount: Int
	public private(set) var setBitCount: Int

	public init(bitCount: Int) {
		self.bitCount = max(0, bitCount)
		self.bytes = Data(repeating: 0, count: (self.bitCount + 7) / 8)
		self.setBitCount = 0
	}

	public init?(bytes: Data, bitCount: Int) {
		let required = (bitCount + 7) / 8
		guard bytes.count >= required else { return nil }
		self.bitCount = bitCount
		self.bytes = bytes.prefix(required)
		// Spare bits in the final byte must be zero; peers that set them are
		// either buggy or probing, and trusting them inflates our piece count.
		if bitCount % 8 != 0, let last = self.bytes.last {
			let mask = UInt8(0xFF) << UInt8(8 - bitCount % 8)
			if last & ~mask != 0 { return nil }
		}
		self.setBitCount = self.bytes.reduce(0) { $0 + $1.nonzeroBitCount }
	}

	public subscript(index: Int) -> Bool {
		get {
			guard index >= 0, index < bitCount else { return false }
			return bytes[bytes.startIndex + index / 8] & (0x80 >> UInt8(index % 8)) != 0
		}
		set {
			guard index >= 0, index < bitCount else { return }
			let position = bytes.startIndex + index / 8
			let mask = UInt8(0x80) >> UInt8(index % 8)
			let wasSet = bytes[position] & mask != 0
			guard wasSet != newValue else { return }
			if newValue {
				bytes[position] |= mask
				setBitCount += 1
			} else {
				bytes[position] &= ~mask
				setBitCount -= 1
			}
		}
	}

	public var isComplete: Bool { setBitCount == bitCount && bitCount > 0 }
	public var isEmpty: Bool { setBitCount == 0 }
	public var completionFraction: Double {
		bitCount == 0 ? 0 : Double(setBitCount) / Double(bitCount)
	}

	public mutating func setAll() {
		for index in 0..<bitCount { self[index] = true }
	}
}
