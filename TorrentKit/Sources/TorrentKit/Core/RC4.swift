import Foundation

/// RC4, the stream cipher MSE uses.
///
/// RC4 is broken for anything that needs to stay secret, and that is not what
/// it is doing here: MSE exists to stop an ISP's traffic shaper from
/// recognising BitTorrent by its plaintext handshake, not to protect the
/// payload — which is a public file being handed to strangers. The protocol
/// specifies RC4, so RC4 is what interoperates.
///
/// Stateful by nature: every byte advances the keystream, so one instance
/// belongs to one direction of one connection and must see that direction's
/// bytes exactly once, in order.
final class RC4 {
	private var state: [UInt8]
	private var i: UInt8 = 0
	private var j: UInt8 = 0

	init(key: Data) {
		var state = [UInt8](0...255)
		let keyBytes = [UInt8](key)
		guard !keyBytes.isEmpty else {
			self.state = state
			return
		}

		var j: UInt8 = 0
		for i in 0..<256 {
			j = j &+ state[i] &+ keyBytes[i % keyBytes.count]
			state.swapAt(i, Int(j))
		}
		self.state = state
	}

	/// XORs `data` with the keystream, advancing it.
	func process(_ data: Data) -> Data {
		guard !data.isEmpty else { return data }
		var output = [UInt8](repeating: 0, count: data.count)

		data.withUnsafeBytes { raw in
			let input = raw.bindMemory(to: UInt8.self)
			for index in 0..<input.count {
				i = i &+ 1
				j = j &+ state[Int(i)]
				state.swapAt(Int(i), Int(j))
				let k = state[Int(state[Int(i)] &+ state[Int(j)])]
				output[index] = input[index] ^ k
			}
		}
		return Data(output)
	}

	/// Throws away the head of the keystream.
	///
	/// RC4's first bytes leak key material, and MSE requires both sides to skip
	/// 1024 of them. Skipping a different amount does not fail loudly — it just
	/// produces garbage on the wire — so this runs at construction.
	func discard(_ byteCount: Int) {
		for _ in 0..<byteCount {
			i = i &+ 1
			j = j &+ state[Int(i)]
			state.swapAt(Int(i), Int(j))
		}
	}

	/// A cipher ready for use: keyed, with the mandated 1024 bytes discarded.
	static func mseCipher(key: Data) -> RC4 {
		let cipher = RC4(key: key)
		cipher.discard(1024)
		return cipher
	}
}
