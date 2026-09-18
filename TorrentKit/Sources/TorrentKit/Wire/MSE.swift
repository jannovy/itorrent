import CryptoKit
import Foundation

/// How much trouble to go to in order to hide that this is BitTorrent.
public enum EncryptionPolicy: String, Sendable, Codable, CaseIterable {
	/// Plaintext only. Fastest, and visible to anything inspecting the wire.
	case disabled
	/// Offer MSE, accept either. Falls back to plaintext for peers that
	/// cannot do it, which is what every other client defaults to.
	case preferred
	/// Refuse to speak plaintext at all, in or out.
	case required

	public var label: String {
		switch self {
		case .disabled: "Off"
		case .preferred: "Prefer encrypted"
		case .required: "Require encrypted"
		}
	}
}

/// Message Stream Encryption, the obfuscation layer every mainline client
/// speaks (also known as protocol encryption, or PE).
///
/// It is not a security feature and does not pretend to be: the key exchange is
/// unauthenticated, so anyone able to sit between two peers can read
/// everything. What it does is make the stream unrecognisable to equipment that
/// throttles or blocks BitTorrent by spotting the plaintext handshake, and it
/// is the difference between connecting to a peer configured to require
/// encryption and being refused by it.
public enum MSE {

	/// The 768-bit prime from the MSE specification, with generator 2.
	public static let primeBytes = Data(hexEncoded: """
		FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD1\
		29024E088A67CC74020BBEA63B139B22514A08798E3404DD\
		EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245\
		E485B576625E7EC6F44C42E9A63A36210000000000090563
		""")!

	static let generator = BigUInt(2)
	static let keyLength = 96
	/// Eight zero bytes, the "verification constant" both sides use to prove
	/// they derived the same secret and to find the end of the random padding.
	static let verificationConstant = Data(count: 8)
	static let maximumPadding = 512
	/// The initiator's payload is a BitTorrent handshake; anything much larger
	/// is a peer trying to make us allocate memory.
	static let maximumInitialPayload = 8192

	public struct CryptoMethod: OptionSet, Sendable {
		public let rawValue: UInt32
		public init(rawValue: UInt32) { self.rawValue = rawValue }

		public static let plaintext = CryptoMethod(rawValue: 0x01)
		public static let rc4 = CryptoMethod(rawValue: 0x02)
	}

	static func hash(_ label: String, _ parts: Data...) -> Data {
		var input = Data(label.utf8)
		for part in parts { input.append(part) }
		return Data(Insecure.SHA1.hash(data: input))
	}

	static func randomPadding() -> Data {
		Data((0..<Int.random(in: 0..<maximumPadding)).map { _ in UInt8.random(in: 0...255) })
	}

	static func xor(_ lhs: Data, _ rhs: Data) -> Data {
		Data(zip(lhs, rhs).map { $0 ^ $1 })
	}
}

/// One side of an MSE handshake.
///
/// Driven by `PeerConnection` on its serial queue: bytes in, bytes out, and
/// eventually a pair of ciphers plus whatever payload arrived behind the
/// handshake. It never touches the socket itself, which is what makes it
/// testable against a real counterpart rather than against a mock.
final class MSEHandshake {

	enum Role {
		/// We dialled, and we know which torrent we are asking for.
		case initiator(infoHash: InfoHash, payload: Data)
		/// Somebody dialled us: which torrent they want is encoded in the
		/// handshake, and only a torrent we actually hold can be matched.
		case receiver(candidates: @Sendable () -> [InfoHash])
	}

	enum Outcome {
		case needMoreData
		case completed(Completion)
		case failed(String)
	}

	struct Completion {
		/// Nil when plaintext was negotiated, which MSE permits: the handshake
		/// is still obfuscated, the payload that follows is not.
		let encrypt: RC4?
		let decrypt: RC4?
		/// Application bytes that arrived behind the handshake, decrypted.
		let leftover: Data
		let infoHash: InfoHash
		let method: MSE.CryptoMethod
	}

	struct Progress {
		var outgoing = Data()
		var outcome: Outcome = .needMoreData
	}

	private enum State {
		case awaitingRemoteKey
		/// Hunting for the marker that sits behind the peer's random padding.
		case syncingVerification
		/// Receiver only: the 20 bytes naming which torrent the peer wants.
		case readingTorrentSelector
		/// The verification constant, the crypto methods and the pad length.
		case readingCryptoHeader
		case readingPadding(length: Int)
		case readingPayloadLength
		case readingPayload(length: Int)
		case finished
	}

	private let role: Role
	private let policy: EncryptionPolicy
	private let privateKey: BigUInt
	private let publicKey: Data

	private var state: State = .awaitingRemoteKey
	private var buffer = Data()
	private var sharedSecret = Data()
	private var infoHash: InfoHash?
	private var encrypt: RC4?
	private var decrypt: RC4?
	private var method: MSE.CryptoMethod = .rc4
	/// What the peer's encrypted verification constant will look like, used to
	/// skip its random padding without advancing the real cipher.
	private var expectedVerification = Data()
	private var bytesSinceRemoteKey = 0

	init(role: Role, policy: EncryptionPolicy) {
		self.role = role
		self.policy = policy

		let secret = Data((0..<20).map { _ in UInt8.random(in: 0...255) })
		self.privateKey = BigUInt(bigEndianBytes: secret)
		self.publicKey = MSE.generator
			.power(privateKey, modulus: BigUInt(bigEndianBytes: MSE.primeBytes))
			.bigEndianBytes(count: MSE.keyLength)
	}

	/// The first bytes to put on the wire. Both sides open with their public
	/// key followed by random padding; only the initiator sends it unprompted.
	func begin() -> Data {
		guard case .initiator = role else { return Data() }
		return publicKey + MSE.randomPadding()
	}

	func consume(_ data: Data) -> Progress {
		buffer.append(data)
		if case .awaitingRemoteKey = state {} else { bytesSinceRemoteKey += data.count }

		var progress = Progress()
		while true {
			switch advance(&progress) {
			case .stop:
				return progress
			case .failed(let reason):
				progress.outcome = .failed(reason)
				return progress
			case .completed(let completion):
				progress.outcome = .completed(completion)
				state = .finished
				return progress
			case .keepGoing:
				continue
			}
		}
	}

	private enum Step {
		case keepGoing
		case stop
		case completed(Completion)
		case failed(String)
	}

	private func advance(_ progress: inout Progress) -> Step {
		switch state {
		case .awaitingRemoteKey:
			return readRemoteKey(&progress)
		case .syncingVerification:
			return synchronise()
		case .readingTorrentSelector:
			return readTorrentSelector()
		case .readingCryptoHeader:
			return readCryptoHeader()
		case let .readingPadding(length):
			return readPadding(length: length)
		case .readingPayloadLength:
			return readPayloadLength()
		case let .readingPayload(length):
			return readPayload(length: length, &progress)
		case .finished:
			return .stop
		}
	}

	// MARK: - Key exchange

	private func readRemoteKey(_ progress: inout Progress) -> Step {
		guard buffer.count >= MSE.keyLength else { return .stop }

		let remoteKey = Data(buffer.prefix(MSE.keyLength))
		buffer.removeFirst(MSE.keyLength)

		let shared = BigUInt(bigEndianBytes: remoteKey)
			.power(privateKey, modulus: BigUInt(bigEndianBytes: MSE.primeBytes))
		guard !shared.isZero else { return .failed("Degenerate Diffie-Hellman key") }
		sharedSecret = shared.bigEndianBytes(count: MSE.keyLength)

		switch role {
		case let .initiator(infoHash, payload):
			self.infoHash = infoHash
			prepareCiphers(infoHash: infoHash)
			progress.outgoing.append(initiatorRequest(infoHash: infoHash, payload: payload))
			// The peer's reply starts with its encrypted verification constant,
			// somewhere after padding of a length only it knows.
			let probe = RC4.mseCipher(key: MSE.hash("keyB", sharedSecret, infoHash.raw))
			expectedVerification = probe.process(MSE.verificationConstant)
			state = .syncingVerification

		case .receiver:
			progress.outgoing.append(publicKey + MSE.randomPadding())
			expectedVerification = MSE.hash("req1", sharedSecret)
			state = .syncingVerification
		}
		bytesSinceRemoteKey = buffer.count
		return .keepGoing
	}

	/// Skips the peer's random padding by hunting for a marker only a peer that
	/// derived the same secret could have produced.
	private func synchronise() -> Step {
		guard let found = buffer.range(of: expectedVerification) else {
			// Bounded so a peer cannot stream noise at us forever.
			if bytesSinceRemoteKey > MSE.maximumPadding + expectedVerification.count * 2 {
				return .failed("Never found the encryption sync point")
			}
			return .stop
		}

		let skipped = found.lowerBound - buffer.startIndex
		switch role {
		case .initiator:
			// The marker *is* the encrypted verification constant, so it stays
			// in the buffer: it still has to go through the real cipher for the
			// keystream to line up.
			buffer.removeFirst(skipped)
			state = .readingCryptoHeader
		case .receiver:
			// The marker is a plain hash sitting in front of the encrypted
			// part, so it is consumed here and never decrypted.
			buffer.removeFirst(skipped + expectedVerification.count)
			state = .readingTorrentSelector
		}
		return .keepGoing
	}

	// MARK: - The encrypted part of the handshake

	/// `HASH('req2', SKEY) xor HASH('req3', S)`: the info-hash, obfuscated so
	/// that watching the wire does not reveal which torrent is being traded.
	///
	/// It can only be undone by trying each torrent we hold, which is also what
	/// makes it safe — a peer asking for something we do not have cannot learn
	/// anything from us.
	private func readTorrentSelector() -> Step {
		guard case let .receiver(candidates) = role else { return .failed("Wrong role") }
		guard buffer.count >= 20 else { return .stop }

		let obfuscated = Data(buffer.prefix(20))
		buffer.removeFirst(20)
		let wanted = MSE.xor(obfuscated, MSE.hash("req3", sharedSecret))

		guard let matched = candidates().first(where: { MSE.hash("req2", $0.raw) == wanted }) else {
			return .failed("Encrypted handshake for a torrent we do not have")
		}
		infoHash = matched
		prepareCiphers(infoHash: matched)
		state = .readingCryptoHeader
		return .keepGoing
	}

	/// VC (8) + crypto_provide/select (4) + len(pad) (2).
	///
	/// The same shape in both directions: the initiator offers methods here and
	/// the receiver picks one, so a single reader covers both.
	private func readCryptoHeader() -> Step {
		guard buffer.count >= 14 else { return .stop }
		guard let decrypt else { return .failed("Missing cipher") }

		let plain = decrypt.process(Data(buffer.prefix(14)))
		buffer.removeFirst(14)
		guard plain.prefix(8) == MSE.verificationConstant else {
			return .failed("Verification constant mismatch")
		}

		let offered = MSE.CryptoMethod(rawValue: plain.bigEndianUInt32(at: 8) ?? 0)
		guard let agreed = agree(on: offered) else {
			return .failed("No mutually acceptable encryption method")
		}
		method = agreed

		let padLength = Int(plain.bigEndianUInt16(at: 12) ?? 0)
		guard padLength <= MSE.maximumPadding else { return .failed("Oversized padding") }
		state = .readingPadding(length: padLength)
		return .keepGoing
	}

	private func readPadding(length: Int) -> Step {
		guard buffer.count >= length else { return .stop }
		if length > 0 {
			// Padding is inside the encrypted stream and must be fed through
			// the cipher even though its contents are thrown away.
			_ = decrypt?.process(Data(buffer.prefix(length)))
			buffer.removeFirst(length)
		}

		switch role {
		case .initiator:
			return .completed(finish(payload: Data()))
		case .receiver:
			state = .readingPayloadLength
			return .keepGoing
		}
	}

	private func readPayloadLength() -> Step {
		guard buffer.count >= 2, let decrypt else { return .stop }
		let plain = decrypt.process(Data(buffer.prefix(2)))
		buffer.removeFirst(2)

		let length = Int(plain.bigEndianUInt16(at: 0) ?? 0)
		guard length <= MSE.maximumInitialPayload else { return .failed("Oversized initial payload") }
		state = .readingPayload(length: length)
		return .keepGoing
	}

	private func readPayload(length: Int, _ progress: inout Progress) -> Step {
		guard buffer.count >= length else { return .stop }
		var payload = Data()
		if length > 0, let decrypt {
			payload = decrypt.process(Data(buffer.prefix(length)))
			buffer.removeFirst(length)
		}

		progress.outgoing.append(receiverReply())
		return .completed(finish(payload: payload))
	}

	// MARK: - Building our half

	private func initiatorRequest(infoHash: InfoHash, payload: Data) -> Data {
		var message = MSE.hash("req1", sharedSecret)
		message += MSE.xor(MSE.hash("req2", infoHash.raw), MSE.hash("req3", sharedSecret))

		var encrypted = MSE.verificationConstant
		encrypted.appendBigEndian(provided().rawValue)
		// No padding of our own: the encrypted part is already opaque, and the
		// key exchange above already carried padding of a random length.
		encrypted.appendBigEndian(UInt16(0))
		encrypted.appendBigEndian(UInt16(payload.count))
		encrypted += payload

		message += encrypt?.process(encrypted) ?? encrypted
		return message
	}

	private func receiverReply() -> Data {
		var plain = MSE.verificationConstant
		plain.appendBigEndian(method.rawValue)
		plain.appendBigEndian(UInt16(0))
		return encrypt?.process(plain) ?? plain
	}

	private func provided() -> MSE.CryptoMethod {
		policy == .required ? .rc4 : [.rc4, .plaintext]
	}

	private func agree(on offered: MSE.CryptoMethod) -> MSE.CryptoMethod? {
		if offered.contains(.rc4) { return .rc4 }
		if offered.contains(.plaintext), policy != .required { return .plaintext }
		return nil
	}

	private func prepareCiphers(infoHash: InfoHash) {
		// Each direction has its own key, named for the side that encrypts with
		// it: the initiator writes with keyA and reads with keyB.
		let keyA = RC4.mseCipher(key: MSE.hash("keyA", sharedSecret, infoHash.raw))
		let keyB = RC4.mseCipher(key: MSE.hash("keyB", sharedSecret, infoHash.raw))

		switch role {
		case .initiator:
			encrypt = keyA
			decrypt = keyB
		case .receiver:
			encrypt = keyB
			decrypt = keyA
		}
	}

	private func finish(payload: Data) -> Completion {
		// Whatever is still buffered is application data that arrived behind
		// the handshake; it has to go through the cipher exactly once.
		var leftover = payload
		if !buffer.isEmpty {
			leftover += decrypt?.process(buffer) ?? buffer
			buffer = Data()
		}

		let usesRC4 = method.contains(.rc4)
		return Completion(
			encrypt: usesRC4 ? encrypt : nil,
			decrypt: usesRC4 ? decrypt : nil,
			leftover: leftover,
			infoHash: infoHash ?? InfoHash(raw: Data(count: 20))!,
			method: method
		)
	}
}
