import Foundation
import Testing
@testable import TorrentKit

@Suite("MSE handshake")
struct MSETests {

	private static let infoHash = InfoHash(hex: "0123456789abcdef0123456789abcdef01234567")!

	/// Runs two handshakes against each other, optionally chopping the stream
	/// into fixed-size pieces to prove the state machine survives fragmentation.
	private func negotiate(
		initiatorPolicy: EncryptionPolicy = .preferred,
		receiverPolicy: EncryptionPolicy = .preferred,
		payload: Data = Data("\u{13}BitTorrent protocol".utf8),
		candidates: [InfoHash] = [MSETests.infoHash],
		chunkSize: Int? = nil
	) -> (initiator: MSEHandshake.Outcome, receiver: MSEHandshake.Outcome) {
		let initiator = MSEHandshake(
			role: .initiator(infoHash: Self.infoHash, payload: payload),
			policy: initiatorPolicy
		)
		let receiver = MSEHandshake(
			role: .receiver(candidates: { candidates }),
			policy: receiverPolicy
		)

		var toReceiver = initiator.begin()
		var toInitiator = Data()
		var initiatorOutcome = MSEHandshake.Outcome.needMoreData
		var receiverOutcome = MSEHandshake.Outcome.needMoreData

		func deliver(_ data: inout Data, to side: MSEHandshake, into other: inout Data) -> MSEHandshake.Outcome {
			var outcome = MSEHandshake.Outcome.needMoreData
			let chunks = chunkSize.map { size in
				stride(from: 0, to: data.count, by: size).map { start in
					data.subdata(in: start..<min(data.count, start + size))
				}
			} ?? (data.isEmpty ? [] : [data])

			for chunk in chunks {
				let progress = side.consume(chunk)
				other.append(progress.outgoing)
				outcome = progress.outcome
				if case .failed = outcome { break }
				if case .completed = outcome { break }
			}
			data = Data()
			return outcome
		}

		// Six passes is far more than the four legs the protocol actually has.
		for _ in 0..<6 {
			if case .needMoreData = receiverOutcome, !toReceiver.isEmpty {
				receiverOutcome = deliver(&toReceiver, to: receiver, into: &toInitiator)
			}
			if case .needMoreData = initiatorOutcome, !toInitiator.isEmpty {
				initiatorOutcome = deliver(&toInitiator, to: initiator, into: &toReceiver)
			}
			if case .completed = initiatorOutcome, case .completed = receiverOutcome { break }
			if case .failed = initiatorOutcome { break }
			if case .failed = receiverOutcome { break }
		}
		return (initiatorOutcome, receiverOutcome)
	}

	private func completion(_ outcome: MSEHandshake.Outcome) -> MSEHandshake.Completion? {
		if case let .completed(completion) = outcome { return completion }
		return nil
	}

	@Test("Both sides complete and agree on RC4")
	func completesTheHandshake() {
		let (initiator, receiver) = negotiate()

		let a = completion(initiator)
		let b = completion(receiver)
		#expect(a != nil, "initiator did not finish: \(initiator)")
		#expect(b != nil, "receiver did not finish: \(receiver)")
		#expect(a?.method.contains(.rc4) == true)
		#expect(b?.method.contains(.rc4) == true)
	}

	@Test("The receiver learns which torrent was asked for")
	func resolvesTheInfoHash() {
		let (_, receiver) = negotiate()
		#expect(completion(receiver)?.infoHash == Self.infoHash)
	}

	@Test("The initiator's payload rides along inside the handshake")
	func carriesTheInitialPayload() {
		let payload = Data("\u{13}BitTorrent protocol-and-then-some".utf8)
		let (_, receiver) = negotiate(payload: payload)
		#expect(completion(receiver)?.leftover == payload)
	}

	@Test("The negotiated ciphers decrypt each other in both directions")
	func cipherStreamsMatch() throws {
		let (initiator, receiver) = negotiate()
		let a = try #require(completion(initiator))
		let b = try #require(completion(receiver))

		let fromA = Data("a message from the side that dialled".utf8)
		let encrypted = try #require(a.encrypt).process(fromA)
		#expect(encrypted != fromA, "the bytes should not go out in the clear")
		#expect(try #require(b.decrypt).process(encrypted) == fromA)

		let fromB = Data("and one coming back the other way".utf8)
		let returned = try #require(b.encrypt).process(fromB)
		#expect(try #require(a.decrypt).process(returned) == fromB)
	}

	@Test("Random padding of any length is skipped correctly")
	func toleratesRandomPadding() {
		// The pad lengths are random per handshake, so this is a search for the
		// case where the sync marker lands awkwardly rather than one example.
		for _ in 0..<25 {
			let (initiator, receiver) = negotiate()
			#expect(completion(initiator) != nil)
			#expect(completion(receiver) != nil)
		}
	}

	@Test("A stream delivered one byte at a time still completes")
	func survivesFragmentation() {
		let (initiator, receiver) = negotiate(chunkSize: 1)
		#expect(completion(initiator) != nil)
		#expect(completion(receiver) != nil)
	}

	@Test("A stream delivered in odd-sized chunks still completes")
	func survivesOddChunking() {
		for size in [3, 7, 64, 97] {
			let (initiator, receiver) = negotiate(chunkSize: size)
			#expect(completion(initiator) != nil, "failed at chunk size \(size)")
			#expect(completion(receiver) != nil, "failed at chunk size \(size)")
		}
	}

	@Test("A handshake for a torrent we do not have is refused")
	func refusesUnknownTorrents() {
		let other = InfoHash(hex: "ffffffffffffffffffffffffffffffffffffffff")!
		let (_, receiver) = negotiate(candidates: [other])

		guard case let .failed(reason) = receiver else {
			Issue.record("the receiver should have refused, got \(receiver)")
			return
		}
		#expect(reason.contains("do not have"))
	}

	@Test("A receiver that requires encryption still negotiates RC4")
	func worksWhenEncryptionIsRequired() {
		let (initiator, receiver) = negotiate(initiatorPolicy: .required, receiverPolicy: .required)
		#expect(completion(initiator)?.method.contains(.rc4) == true)
		#expect(completion(receiver)?.method.contains(.rc4) == true)
	}

	@Test("Nothing recognisable as BitTorrent appears in the first bytes")
	func hidesTheProtocolHeader() {
		let payload = Data("\u{13}BitTorrent protocol".utf8)
		let initiator = MSEHandshake(
			role: .initiator(infoHash: Self.infoHash, payload: payload),
			policy: .preferred
		)
		let receiver = MSEHandshake(role: .receiver(candidates: { [Self.infoHash] }), policy: .preferred)

		var onTheWire = initiator.begin()
		let reply = receiver.consume(onTheWire)
		onTheWire += initiator.consume(reply.outgoing).outgoing

		// This is the entire point of MSE: a traffic shaper looking for the
		// plaintext header must not find it.
		#expect(onTheWire.range(of: Data("BitTorrent protocol".utf8)) == nil)
	}
}
