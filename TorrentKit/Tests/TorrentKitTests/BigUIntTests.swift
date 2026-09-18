import Foundation
import Testing
@testable import TorrentKit

@Suite("Big integers")
struct BigUIntTests {

	private func value(_ hex: String) -> BigUInt {
		BigUInt(bigEndianBytes: Data(hexEncoded: hex.count % 2 == 0 ? hex : "0" + hex)!)
	}

	private func hex(_ value: BigUInt, bytes: Int) -> String {
		value.bigEndianBytes(count: bytes).hexEncodedString()
	}

	@Test("Round-trips big-endian bytes, leading zeroes and all")
	func roundTripsBytes() {
		let raw = Data(hexEncoded: "00ff00ff00ff00ff00ff00ff")!
		let parsed = BigUInt(bigEndianBytes: raw)
		#expect(parsed.bigEndianBytes(count: 12) == raw)

		// Padding out to a wider field must not change the value.
		#expect(parsed.bigEndianBytes(count: 16) == Data(hexEncoded: "00000000" + "00ff00ff00ff00ff00ff00ff")!)
	}

	@Test("Multiplies numbers wider than a limb")
	func multiplies() {
		// 2^96 - 1 squared, checked against Python.
		let a = value("ffffffffffffffffffffffff")
		let product = a * a
		#expect(hex(product, bytes: 24) == "fffffffffffffffffffffffe000000000000000000000001")
	}

	@Test("Takes a remainder with a multi-limb modulus")
	func takesRemainders() {
		// Checked against Python: (2^200 - 1) % (2^64 + 13)
		let dividend = value(String(repeating: "f", count: 50))
		let modulus = value("1000000000000000d")
		let remainder = dividend.remainder(dividingBy: modulus)
		#expect(hex(remainder, bytes: 9) == "00fffffffffff76b0c")
	}

	@Test("A remainder smaller than the modulus is returned unchanged")
	func passesThroughSmallValues() {
		let small = value("0102")
		let modulus = value("ffffffffffffffffff")
		#expect(small.remainder(dividingBy: modulus) == small)
	}

	@Test("Modular exponentiation matches a known vector")
	func exponentiates() {
		// 2^255 mod (2^128 + 51), checked against Python.
		let result = BigUInt(2).power(value("ff"), modulus: value("100000000000000000000000000000033"))
		#expect(hex(result, bytes: 17) == "008000000000000000000000000000052e")
	}

	@Test("A Diffie-Hellman exchange over the MSE prime agrees both ways")
	func diffieHellmanAgrees() {
		let prime = BigUInt(bigEndianBytes: MSE.primeBytes)
		let generator = BigUInt(2)

		let secretA = BigUInt(bigEndianBytes: Data((0..<20).map { _ in UInt8.random(in: 0...255) }))
		let secretB = BigUInt(bigEndianBytes: Data((0..<20).map { _ in UInt8.random(in: 0...255) }))

		let publicA = generator.power(secretA, modulus: prime)
		let publicB = generator.power(secretB, modulus: prime)

		let sharedFromA = publicB.power(secretA, modulus: prime)
		let sharedFromB = publicA.power(secretB, modulus: prime)

		#expect(sharedFromA == sharedFromB)
		#expect(sharedFromA.bigEndianBytes(count: 96).count == 96)
		#expect(!sharedFromA.isZero)
	}

	@Test("A 768-bit exchange is fast enough to do per connection")
	func isFastEnoughForAHandshake() {
		let prime = BigUInt(bigEndianBytes: MSE.primeBytes)
		let secret = BigUInt(bigEndianBytes: Data((0..<20).map { _ in UInt8.random(in: 0...255) }))

		let started = Date()
		_ = BigUInt(2).power(secret, modulus: prime)
		let elapsed = Date().timeIntervalSince(started)

		// Fifty peers must not cost seconds of CPU on a phone.
		#expect(elapsed < 0.1, "one modular exponentiation took \(elapsed)s")
	}
}
