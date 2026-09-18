import Foundation
import Testing
@testable import TorrentKit

@Suite("uTP", .timeLimit(.minutes(2)))
struct UTPTests {

	// MARK: - Packets

	@Test("A packet round-trips through the wire format")
	func encodesAndDecodes() throws {
		let original = UTPPacket(
			kind: .data,
			connectionID: 0xBEEF,
			timestamp: 123_456_789,
			timestampDifference: 987_654,
			windowSize: 65_536,
			sequenceNumber: 42,
			acknowledgementNumber: 41,
			payload: Data("hello".utf8)
		)

		let decoded = try #require(UTPPacket(data: original.encoded()))
		#expect(decoded == original)
	}

	@Test("A selective acknowledgement survives the round trip")
	func encodesSelectiveAcks() throws {
		var original = UTPPacket(kind: .state, connectionID: 7, sequenceNumber: 1, acknowledgementNumber: 5)
		original.selectiveAck = Data([0b0000_0101, 0, 0, 0])

		let decoded = try #require(UTPPacket(data: original.encoded()))
		#expect(decoded.selectiveAck == Data([0b0000_0101, 0, 0, 0]))
		#expect(decoded.payload.isEmpty)
	}

	@Test("Unknown extensions are skipped rather than rejected")
	func skipsUnknownExtensions() throws {
		var data = Data()
		data.append(UTPPacket.Kind.data.rawValue << 4 | 1)
		data.append(0x42)                      // an extension we do not know
		data.appendBigEndian(UInt16(1))        // connection id
		data.appendBigEndian(UInt32(0))        // timestamp
		data.appendBigEndian(UInt32(0))        // timestamp difference
		data.appendBigEndian(UInt32(0))        // window
		data.appendBigEndian(UInt16(3))        // seq
		data.appendBigEndian(UInt16(2))        // ack
		data.append(0)                         // no further extensions
		data.append(2)                         // length
		data.append(contentsOf: [0xAA, 0xBB])  // its payload
		data.append(contentsOf: [1, 2, 3])     // ours

		let packet = try #require(UTPPacket(data: data))
		#expect(packet.payload == Data([1, 2, 3]))
		#expect(packet.sequenceNumber == 3)
	}

	@Test("A truncated packet is rejected")
	func rejectsTruncatedPackets() {
		#expect(UTPPacket(data: Data([0x41, 0, 0, 1])) == nil)
	}

	@Test("A packet of the wrong version is rejected")
	func rejectsWrongVersion() {
		var data = UTPPacket(kind: .data, connectionID: 1).encoded()
		data[data.startIndex] = 0x02
		#expect(UTPPacket(data: data) == nil)
	}

	@Test("Sequence numbers compare across the wrap-around")
	func comparesSequenceNumbers() {
		#expect(utpSequence(65_535, isLessThan: 0))
		#expect(utpSequence(65_530, isLessThan: 5))
		#expect(!utpSequence(5, isLessThan: 65_530))
		#expect(utpSequence(7, isAtOrBefore: 7))
	}

	// MARK: - Congestion control

	@Test("A delay below the target opens the window, one above closes it")
	func ledbatRespondsToDelay() {
		var control = LEDBAT()

		// Establish a baseline, then stay at it: no queue, so the window grows.
		control.onAck(bytesAcked: 1400, delayMicroseconds: 10_000)
		let start = control.window
		for _ in 0..<50 {
			control.onAck(bytesAcked: 1400, delayMicroseconds: 10_000)
		}
		#expect(control.window > start, "a path with no queuing should open up")

		// Now the same path with 300 ms of queuing on top: well past the 100 ms
		// target, so the window must give way.
		let beforeCongestion = control.window
		for _ in 0..<50 {
			control.onAck(bytesAcked: 1400, delayMicroseconds: 310_000)
		}
		#expect(control.window < beforeCongestion, "queuing delay should close the window")
	}

	@Test("Loss halves the window and a timeout collapses it")
	func ledbatBacksOff() {
		var control = LEDBAT()
		for _ in 0..<200 {
			control.onAck(bytesAcked: 1400, delayMicroseconds: 10_000)
		}
		let grown = control.window

		control.onLoss()
		#expect(control.window <= grown / 2 + 1)

		control.onTimeout()
		#expect(control.window == LEDBAT.minimumWindow)
	}

	@Test("The window never falls below one packet")
	func ledbatKeepsAFloor() {
		var control = LEDBAT()
		for _ in 0..<100 { control.onLoss() }
		#expect(control.window == LEDBAT.minimumWindow)
	}

	@Test("Round-trip estimates settle and back off")
	func estimatesRoundTrips() {
		var estimator = RTTEstimator()
		for _ in 0..<20 { estimator.record(sample: 0.2) }
		#expect(abs(estimator.smoothed - 0.2) < 0.01)
		// The floor keeps a fast path from retransmitting into its own queue.
		#expect(estimator.timeout >= RTTEstimator.minimumTimeout)

		let before = estimator.timeout
		estimator.backOff()
		#expect(estimator.timeout > before)
	}

	// MARK: - Connections over a real socket

	/// Two sockets on loopback, with the plumbing every test here needs.
	private final class Pair {
		let server = UTPSocket()
		let client = UTPSocket()
		let accepted = Box<UTPConnection?>(nil)
		let received = Box<Data>(Data())

		init() throws {
			try server.start(port: 0)
			try client.start(port: 0)
			server.onIncomingConnection = { [accepted, received] connection in
				accepted.value = connection
				connection.onData = { data in received.value.append(data) }
			}
		}

		func dial() -> UTPConnection {
			client.queue.sync { client.dial(to: PeerAddress(host: "127.0.0.1", port: server.localPort)) }
		}

		func stop() {
			client.stop()
			server.stop()
		}
	}

	/// A tiny lock-protected box; the socket's callbacks land on its own queue.
	private final class Box<Value>: @unchecked Sendable {
		private let lock = NSLock()
		private var storage: Value
		init(_ value: Value) { storage = value }
		var value: Value {
			get { lock.withLock { storage } }
			set { lock.withLock { storage = newValue } }
		}
	}

	private func waitUntil(
		_ what: String,
		timeout: TimeInterval = 30,
		_ condition: () -> Bool
	) async throws {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if condition() { return }
			try await Task.sleep(nanoseconds: 20_000_000)
		}
		throw UTPFailure.timedOut(what)
	}

	@Test("A connection is established in both directions")
	func connects() async throws {
		let pair = try Pair()
		defer { pair.stop() }

		let connected = Box(false)
		let connection = pair.dial()
		pair.client.queue.async { connection.onConnect = { connected.value = true } }

		try await waitUntil("the handshake") { connected.value && pair.accepted.value != nil }
		#expect(pair.accepted.value?.isOpen == true)
	}

	@Test("A connect callback attached after the peer answered still fires")
	func deliversAConnectThatAlreadyHappened() async throws {
		let pair = try Pair()
		defer { pair.stop() }

		let connection = pair.dial()
		// Wait for the reply to have been processed before subscribing at all.
		// A peer on loopback answers a SYN faster than a caller can attach its
		// callbacks, and an event fired into a nil closure is an event lost.
		try await waitUntil("the connection to open") {
			pair.client.queue.sync { connection.isOpen }
		}

		let connected = Box(false)
		pair.client.queue.sync { connection.onConnect = { connected.value = true } }

		try await waitUntil("the late connect callback") { connected.value }
		#expect(connected.value)
	}

	@Test("A megabyte arrives intact and in order")
	func transfersData() async throws {
		let pair = try Pair()
		defer { pair.stop() }

		let payload = Fixtures.payload(byteCount: 1_000_000)
		let connection = pair.dial()
		try await waitUntil("the handshake") { pair.accepted.value != nil }

		pair.client.queue.async { connection.write(payload) }

		try await waitUntil("a megabyte to arrive") { pair.received.value.count == payload.count }
		#expect(pair.received.value == payload, "every byte, in the order it was written")
	}

	@Test("Data written before the handshake completes is not lost")
	func queuesEarlyWrites() async throws {
		let pair = try Pair()
		defer { pair.stop() }

		let payload = Fixtures.payload(byteCount: 40_000)
		// Written immediately, while the SYN is still in the air.
		let connection = pair.dial()
		pair.client.queue.async { connection.write(payload) }

		try await waitUntil("the early write to arrive") { pair.received.value.count == payload.count }
		#expect(pair.received.value == payload)
	}

	@Test("A lossy network still delivers everything, in order")
	func survivesPacketLoss() async throws {
		let pair = try Pair()
		defer { pair.stop() }

		// Drop one data packet in eight, in both directions. Without working
		// retransmission and gap handling this test cannot pass at all.
		let counter = Box(0)
		let dropper: @Sendable (UTPPacket) -> Bool = { packet in
			guard packet.kind == .data else { return false }
			counter.value += 1
			return counter.value % 8 == 0
		}
		pair.client.queue.sync { pair.client.shouldDropOutgoingPacket = dropper }
		pair.server.queue.sync { pair.server.shouldDropOutgoingPacket = dropper }

		let payload = Fixtures.payload(byteCount: 300_000)
		let connection = pair.dial()
		try await waitUntil("the handshake") { pair.accepted.value != nil }
		pair.client.queue.async { connection.write(payload) }

		try await waitUntil("the lossy transfer", timeout: 60) {
			pair.received.value.count == payload.count
		}
		#expect(pair.received.value == payload, "loss must not corrupt or reorder the stream")
		#expect(counter.value > 8, "the test should actually have dropped something")
	}

	@Test("Closing one end ends the stream at the other")
	func closes() async throws {
		let pair = try Pair()
		defer { pair.stop() }

		let closed = Box(false)
		let connection = pair.dial()
		try await waitUntil("the handshake") { pair.accepted.value != nil }
		pair.server.queue.sync {
			pair.accepted.value?.onClose = { _ in closed.value = true }
		}

		pair.client.queue.async { connection.close() }
		try await waitUntil("the peer to notice the close") { closed.value }
		#expect(closed.value)
	}
}

enum UTPFailure: Error, CustomStringConvertible {
	case timedOut(String)
	var description: String {
		if case let .timedOut(what) = self { return "Timed out waiting for \(what)" }
		return "failure"
	}
}
