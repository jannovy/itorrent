import Foundation

/// Just enough arbitrary-precision arithmetic for one Diffie-Hellman exchange.
///
/// MSE needs `g^x mod p` with a 768-bit prime, and that is the only thing this
/// type is for. It is deliberately not a general big-integer library: no
/// subtraction below zero, no signs, no division API beyond the remainder that
/// modular exponentiation needs.
///
/// Limbs are 32 bits, least significant first, with no leading zero limbs.
struct BigUInt: Equatable {
	private(set) var limbs: [UInt32]

	static let zero = BigUInt(limbs: [])

	private init(limbs: [UInt32]) {
		self.limbs = limbs
		normalize()
	}

	init(_ value: UInt32) {
		self.limbs = value == 0 ? [] : [value]
	}

	/// Reads a big-endian byte string, as every value in the MSE spec is given.
	init(bigEndianBytes bytes: Data) {
		var limbs: [UInt32] = []
		limbs.reserveCapacity((bytes.count + 3) / 4)

		var accumulator: UInt32 = 0
		var shift: UInt32 = 0
		for byte in bytes.reversed() {
			accumulator |= UInt32(byte) << shift
			shift += 8
			if shift == 32 {
				limbs.append(accumulator)
				accumulator = 0
				shift = 0
			}
		}
		if shift > 0 { limbs.append(accumulator) }
		self.limbs = limbs
		normalize()
	}

	/// Writes a big-endian byte string of exactly `byteCount` bytes.
	///
	/// The padding is not cosmetic: MSE hashes the shared secret, and a secret
	/// that happens to start with a zero byte must still hash as 96 bytes or
	/// the two sides derive different keys.
	func bigEndianBytes(count byteCount: Int) -> Data {
		var bytes = [UInt8](repeating: 0, count: byteCount)
		var position = byteCount - 1
		for limb in limbs {
			for shift in stride(from: 0, to: 32, by: 8) {
				guard position >= 0 else { break }
				bytes[position] = UInt8(truncatingIfNeeded: limb >> UInt32(shift))
				position -= 1
			}
		}
		return Data(bytes)
	}

	var isZero: Bool { limbs.isEmpty }

	private mutating func normalize() {
		while let last = limbs.last, last == 0 { limbs.removeLast() }
	}

	// MARK: - Comparison

	static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
		if lhs.limbs.count != rhs.limbs.count { return lhs.limbs.count < rhs.limbs.count }
		for index in stride(from: lhs.limbs.count - 1, through: 0, by: -1) where lhs.limbs[index] != rhs.limbs[index] {
			return lhs.limbs[index] < rhs.limbs[index]
		}
		return false
	}

	// MARK: - Multiplication

	static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
		guard !lhs.isZero, !rhs.isZero else { return .zero }

		var product = [UInt32](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
		for i in 0..<lhs.limbs.count {
			var carry: UInt64 = 0
			let left = UInt64(lhs.limbs[i])
			for j in 0..<rhs.limbs.count {
				let total = left * UInt64(rhs.limbs[j]) + UInt64(product[i + j]) + carry
				product[i + j] = UInt32(truncatingIfNeeded: total)
				carry = total >> 32
			}
			var index = i + rhs.limbs.count
			while carry > 0 {
				let total = UInt64(product[index]) + carry
				product[index] = UInt32(truncatingIfNeeded: total)
				carry = total >> 32
				index += 1
			}
		}
		return BigUInt(limbs: product)
	}

	// MARK: - Remainder

	/// Knuth's Algorithm D, remainder only.
	///
	/// Long division the schoolbook way would take one pass per *bit*; for the
	/// 1536-bit products this does per modular multiplication that is the
	/// difference between a handshake costing a millisecond and costing fifty.
	func remainder(dividingBy modulus: BigUInt) -> BigUInt {
		precondition(!modulus.isZero, "division by zero")
		if self < modulus { return self }

		// Single-limb divisor: Algorithm D needs at least two.
		if modulus.limbs.count == 1 {
			let divisor = UInt64(modulus.limbs[0])
			var rest: UInt64 = 0
			for limb in limbs.reversed() {
				rest = ((rest << 32) | UInt64(limb)) % divisor
			}
			return BigUInt(UInt32(truncatingIfNeeded: rest))
		}

		let n = modulus.limbs.count
		let m = limbs.count - n

		// Normalise so the divisor's top limb has its high bit set, which is
		// what makes the quotient estimate below accurate to within one.
		let shift = UInt32(modulus.limbs[n - 1].leadingZeroBitCount)
		let divisor = modulus.shiftedLeft(by: shift).limbs
		var remainder = shiftedLeft(by: shift).limbs
		// Algorithm D indexes one limb past the dividend.
		remainder.append(0)
		while remainder.count < m + n + 1 { remainder.append(0) }

		let base = UInt64(1) << 32
		let topDivisor = UInt64(divisor[n - 1])
		let secondDivisor = UInt64(divisor[n - 2])

		for j in stride(from: m, through: 0, by: -1) {
			let numerator = (UInt64(remainder[j + n]) << 32) | UInt64(remainder[j + n - 1])
			var estimate = numerator / topDivisor
			var rest = numerator % topDivisor

			while estimate >= base || estimate * secondDivisor > (rest << 32) | UInt64(remainder[j + n - 2]) {
				estimate -= 1
				rest += topDivisor
				if rest >= base { break }
			}

			// Multiply and subtract.
			var borrow: Int64 = 0
			var carry: UInt64 = 0
			for i in 0..<n {
				let product = estimate * UInt64(divisor[i]) + carry
				carry = product >> 32
				let subtrahend = Int64(UInt32(truncatingIfNeeded: product))
				let difference = Int64(remainder[j + i]) - subtrahend + borrow
				remainder[j + i] = UInt32(truncatingIfNeeded: difference)
				borrow = difference >> 32
			}
			let difference = Int64(remainder[j + n]) - Int64(carry) + borrow
			remainder[j + n] = UInt32(truncatingIfNeeded: difference)
			borrow = difference >> 32

			// The estimate was one too large; give the divisor back.
			if borrow != 0 {
				var carry: UInt64 = 0
				for i in 0..<n {
					let total = UInt64(remainder[j + i]) + UInt64(divisor[i]) + carry
					remainder[j + i] = UInt32(truncatingIfNeeded: total)
					carry = total >> 32
				}
				remainder[j + n] = UInt32(truncatingIfNeeded: UInt64(remainder[j + n]) + carry)
			}
		}

		return BigUInt(limbs: Array(remainder.prefix(n))).shiftedRight(by: shift)
	}

	private func shiftedLeft(by bits: UInt32) -> BigUInt {
		guard bits > 0, !isZero else { return self }
		var result = [UInt32](repeating: 0, count: limbs.count + 1)
		for (index, limb) in limbs.enumerated() {
			result[index] |= limb << bits
			result[index + 1] = limb >> (32 - bits)
		}
		return BigUInt(limbs: result)
	}

	private func shiftedRight(by bits: UInt32) -> BigUInt {
		guard bits > 0, !isZero else { return self }
		var result = [UInt32](repeating: 0, count: limbs.count)
		for index in 0..<limbs.count {
			result[index] = limbs[index] >> bits
			if index + 1 < limbs.count {
				result[index] |= limbs[index + 1] << (32 - bits)
			}
		}
		return BigUInt(limbs: result)
	}

	// MARK: - Modular exponentiation

	/// `self^exponent mod modulus`, left to right, square and multiply.
	func power(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
		guard !modulus.isZero else { return .zero }
		guard !exponent.isZero else { return BigUInt(1).remainder(dividingBy: modulus) }

		var result = BigUInt(1)
		let base = remainder(dividingBy: modulus)

		let bitCount = exponent.limbs.count * 32
		var started = false
		for position in stride(from: bitCount - 1, through: 0, by: -1) {
			let bit = (exponent.limbs[position / 32] >> UInt32(position % 32)) & 1
			if started {
				result = (result * result).remainder(dividingBy: modulus)
			}
			if bit == 1 {
				result = started ? (result * base).remainder(dividingBy: modulus) : base
				started = true
			}
		}
		return result
	}
}
