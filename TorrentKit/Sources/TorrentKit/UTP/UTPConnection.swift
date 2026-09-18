import Foundation

/// One µTP connection: a reliable, ordered byte stream over UDP.
///
/// Everything runs on the owning `UTPSocket`'s serial queue, which is also
/// where packets arrive, so the connection needs no locking. It is deliberately
/// callback-shaped rather than async: a byte stream reordered by an actor hop
/// is unrecoverable, exactly as for the TCP path.
final class UTPConnection {

	enum State {
		case connecting
		case connected
		/// We have sent a FIN and are waiting for it to be acknowledged.
		case closing
		case closed
	}

	/// Payload per packet. 1400 leaves room for the µTP, UDP and IP headers
	/// inside the 1500-byte ethernet MTU that survives almost every path.
	static let maximumSegmentSize = 1400
	/// How much out-of-order data to hold while waiting for the gap to fill.
	static let maximumReceiveBuffer = 1024 * 1024
	private static let connectTimeout: TimeInterval = 6
	private static let idleTimeout: TimeInterval = 120
	/// Three duplicate acks mean a packet was dropped rather than reordered.
	private static let duplicateAcksBeforeResend = 3
	private static let maximumRetransmissions = 6

	struct Outgoing {
		let packet: UTPPacket
		var sentAt: Date
		var transmissions: Int
		var byteCount: Int
	}

	let remote: PeerAddress
	/// Packets we send carry `sendID`; packets addressed to us carry `recvID`.
	let sendID: UInt16
	let recvID: UInt16
	let isInitiator: Bool

	private(set) var state: State = .connecting

	// Callbacks, all delivered on the socket's queue.
	var onConnect: (() -> Void)? {
		didSet { flushPendingConnect() }
	}

	/// Bytes and the close notification can both arrive before whoever owns
	/// this connection has had a chance to subscribe — an inbound peer's first
	/// packet often follows its SYN immediately — so both are held until there
	/// is somebody to hand them to. Dropping them would lose the handshake.
	var onData: ((Data) -> Void)? {
		didSet { flushPendingDelivery() }
	}

	var onClose: ((String?) -> Void)? {
		didSet { flushPendingDelivery() }
	}

	private var pendingDelivery = Data()
	private var pendingClose: String??
	private var pendingConnect = false
	private let transmit: (UTPPacket, PeerAddress) -> Void

	// Send side.
	private var sequenceNumber: UInt16
	private var unacknowledged: [UInt16: Outgoing] = [:]
	/// Kept as a running total rather than summed on demand: `flush` consults
	/// it once per packet, and a full window is a thousand of them.
	private var inFlightByteCount = 0
	private var pendingWrites = Data()
	private var lastAckReceived: UInt16 = 0
	private var duplicateAckCount = 0

	// Receive side.
	private var acknowledgementNumber: UInt16 = 0
	private var reordered: [UInt16: Data] = [:]
	private var reorderedByteCount = 0
	private var didReceiveFin = false
	private var finSequenceNumber: UInt16?

	// Control.
	private var congestion = LEDBAT()
	private var rtt = RTTEstimator()
	private var peerWindow: UInt32 = 64 * 1024
	/// The last one-way delay we measured of the peer, echoed back so its own
	/// congestion control has something to work with.
	private var replyMicroseconds: UInt32 = 0
	private var lastActivity = Date()
	private var createdAt = Date()

	init(
		remote: PeerAddress,
		recvID: UInt16,
		sendID: UInt16,
		isInitiator: Bool,
		transmit: @escaping (UTPPacket, PeerAddress) -> Void
	) {
		self.remote = remote
		self.recvID = recvID
		self.sendID = sendID
		self.isInitiator = isInitiator
		self.transmit = transmit
		// Both sides start at 1; the spec only requires that a SYN's sequence
		// number be known to the peer, and 1 keeps the arithmetic readable.
		self.sequenceNumber = 1
	}

	var isOpen: Bool {
		if case .connected = state { return true }
		return false
	}

	var bytesInFlight: Int { inFlightByteCount }

	// MARK: - Opening

	/// Dials: sends the SYN whose connection id names the stream.
	func connect() {
		guard case .connecting = state, isInitiator else { return }
		let syn = makePacket(kind: .syn, connectionID: recvID, sequenceNumber: sequenceNumber)
		store(syn, byteCount: 1)
		sequenceNumber &+= 1
		send(syn)
	}

	/// Answers a SYN: the connection is live as soon as the acknowledgement is
	/// on its way.
	func acceptSyn(_ packet: UTPPacket) {
		acknowledgementNumber = packet.sequenceNumber
		peerWindow = packet.windowSize
		state = .connected
		sendState()
		notifyConnected()
	}

	// MARK: - Writing

	func write(_ data: Data) {
		guard state == .connected || state == .connecting else { return }
		pendingWrites.append(data)
		flush()
	}

	/// Turns queued bytes into packets, as far as the windows allow.
	private func flush() {
		guard state == .connected else { return }

		while !pendingWrites.isEmpty {
			let allowed = min(congestion.window, Int(peerWindow))
			let available = allowed - bytesInFlight
			guard available >= 1 else { return }

			let length = min(Self.maximumSegmentSize, min(pendingWrites.count, available))
			let chunk = Data(pendingWrites.prefix(length))
			pendingWrites.removeFirst(length)

			let packet = makePacket(
				kind: .data,
				connectionID: sendID,
				sequenceNumber: sequenceNumber,
				payload: chunk
			)
			store(packet, byteCount: chunk.count)
			sequenceNumber &+= 1
			send(packet)
		}
	}

	// MARK: - Receiving

	func receive(_ packet: UTPPacket, at now: Date = Date()) {
		lastActivity = now
		peerWindow = packet.windowSize
		// What we measure here is sent back so the peer can run LEDBAT on it;
		// what *we* run LEDBAT on is the figure the peer put in this packet.
		replyMicroseconds = utpNowMicroseconds() &- packet.timestamp

		switch packet.kind {
		case .reset:
			close(reason: "The peer reset the connection")
			return

		case .syn:
			// A repeated SYN means our acknowledgement was lost.
			if state == .connected { sendState() }
			return

		case .state:
			if case .connecting = state, isInitiator {
				// The reply's sequence number is the first one the peer will
				// use, so the last one we have in order is the one before it.
				acknowledgementNumber = packet.sequenceNumber &- 1
				state = .connected
				processAcks(packet, now: now)
				notifyConnected()
				flush()
				return
			}
			processAcks(packet, now: now)
			flush()
			return

		case .data, .fin:
			processAcks(packet, now: now)
			if packet.kind == .fin {
				didReceiveFin = true
				finSequenceNumber = packet.sequenceNumber
			}
			acceptPayload(packet)
			flush()
			checkForEndOfStream()
		}
	}

	private func acceptPayload(_ packet: UTPPacket) {
		let expected = acknowledgementNumber &+ 1

		if packet.sequenceNumber == expected {
			if !packet.payload.isEmpty { deliver(packet.payload) }
			acknowledgementNumber = packet.sequenceNumber
			drainReorderBuffer()
			sendState()
			return
		}

		if utpSequence(packet.sequenceNumber, isAtOrBefore: acknowledgementNumber) {
			// Already delivered; the peer missed our acknowledgement.
			sendState()
			return
		}

		// A gap: hold the packet until the missing one turns up, and say so in
		// the acknowledgement so the peer resends only what is actually lost.
		if reordered[packet.sequenceNumber] == nil,
		   reorderedByteCount + packet.payload.count <= Self.maximumReceiveBuffer {
			reordered[packet.sequenceNumber] = packet.payload
			reorderedByteCount += packet.payload.count
		}
		sendState()
	}

	private func drainReorderBuffer() {
		while let payload = reordered.removeValue(forKey: acknowledgementNumber &+ 1) {
			reorderedByteCount -= payload.count
			acknowledgementNumber &+= 1
			if !payload.isEmpty { deliver(payload) }
		}
	}

	private func checkForEndOfStream() {
		guard didReceiveFin, let fin = finSequenceNumber else { return }
		// Everything before the FIN has been delivered.
		guard utpSequence(fin, isAtOrBefore: acknowledgementNumber &+ 1) else { return }
		close(reason: nil)
	}

	// MARK: - Acknowledgements

	private func processAcks(_ packet: UTPPacket, now: Date) {
		var ackedBytes = 0
		var isDuplicate = true

		for (sequence, entry) in unacknowledged
			where utpSequence(sequence, isAtOrBefore: packet.acknowledgementNumber) {
			ackedBytes += entry.byteCount
			isDuplicate = false
			inFlightByteCount -= entry.byteCount
			// Karn's algorithm: a retransmitted packet cannot tell us the round
			// trip, because there is no way to know which copy was answered.
			if entry.transmissions == 1 {
				rtt.record(sample: now.timeIntervalSince(entry.sentAt))
			}
			unacknowledged[sequence] = nil
		}

		if let bitmask = packet.selectiveAck {
			ackedBytes += applySelectiveAck(bitmask, after: packet.acknowledgementNumber, now: now)
		}

		if ackedBytes > 0 {
			congestion.onAck(bytesAcked: ackedBytes, delayMicroseconds: packet.timestampDifference, now: now)
		}

		if isDuplicate, packet.acknowledgementNumber == lastAckReceived, !unacknowledged.isEmpty {
			duplicateAckCount += 1
			if duplicateAckCount == Self.duplicateAcksBeforeResend {
				resend(sequence: packet.acknowledgementNumber &+ 1, now: now)
				congestion.onLoss()
			}
		} else {
			duplicateAckCount = 0
			lastAckReceived = packet.acknowledgementNumber
		}
	}

	/// The bitmask covers packets after the gap: bit 0 is `ack_nr + 2`.
	private func applySelectiveAck(_ bitmask: Data, after ackNumber: UInt16, now: Date) -> Int {
		var acked = 0
		for (byteIndex, byte) in bitmask.enumerated() {
			for bit in 0..<8 where byte & (1 << UInt8(bit)) != 0 {
				let sequence = ackNumber &+ UInt16(2 + byteIndex * 8 + bit)
				guard let entry = unacknowledged.removeValue(forKey: sequence) else { continue }
				acked += entry.byteCount
				inFlightByteCount -= entry.byteCount
				if entry.transmissions == 1 {
					rtt.record(sample: now.timeIntervalSince(entry.sentAt))
				}
			}
		}
		// A selective ack proves later packets arrived while an earlier one did
		// not, which is the clearest loss signal there is.
		if acked > 0, !unacknowledged.isEmpty {
			resend(sequence: ackNumber &+ 1, now: now)
			congestion.onLoss()
		}
		return acked
	}

	private func buildSelectiveAck() -> Data? {
		guard !reordered.isEmpty else { return nil }
		// Four bytes covers the next 32 packets, which is as far ahead as a
		// gap is worth describing.
		var bitmask = [UInt8](repeating: 0, count: 4)
		for offset in 0..<32 where reordered[acknowledgementNumber &+ UInt16(2 + offset)] != nil {
			bitmask[offset / 8] |= 1 << UInt8(offset % 8)
		}
		return bitmask.contains(where: { $0 != 0 }) ? Data(bitmask) : nil
	}

	// MARK: - Retransmission

	/// Called by the socket a few times a second.
	func tick(now: Date = Date()) {
		switch state {
		case .closed:
			return

		case .connecting:
			if now.timeIntervalSince(createdAt) > Self.connectTimeout {
				close(reason: "The peer did not answer")
				return
			}

		case .connected, .closing:
			if now.timeIntervalSince(lastActivity) > Self.idleTimeout {
				close(reason: "Idle")
				return
			}
		}

		guard let oldest = unacknowledged.values.min(by: { $0.sentAt < $1.sentAt }) else {
			flush()
			return
		}
		guard now.timeIntervalSince(oldest.sentAt) > rtt.timeout else { return }

		guard oldest.transmissions < Self.maximumRetransmissions else {
			close(reason: "The peer stopped responding")
			return
		}

		// Nothing came back in a whole timeout: assume the window is gone.
		congestion.onTimeout()
		rtt.backOff()
		resend(sequence: oldest.packet.sequenceNumber, now: now)
	}

	private func resend(sequence: UInt16, now: Date) {
		guard var entry = unacknowledged[sequence] else { return }
		entry.sentAt = now
		entry.transmissions += 1
		unacknowledged[sequence] = entry
		send(entry.packet)
	}

	// MARK: - Closing

	func close() {
		guard state == .connected else {
			close(reason: nil)
			return
		}
		let fin = makePacket(kind: .fin, connectionID: sendID, sequenceNumber: sequenceNumber)
		store(fin, byteCount: 1)
		sequenceNumber &+= 1
		send(fin)
		state = .closing
		// Nothing waits for the FIN to be acknowledged: the peer either got it
		// or will time the connection out, and holding the object open past
		// the torrent's interest in it helps nobody.
		close(reason: nil)
	}

	func reset() {
		guard state != .closed else { return }
		send(makePacket(kind: .reset, connectionID: sendID, sequenceNumber: sequenceNumber))
		close(reason: "Reset")
	}

	private func close(reason: String?) {
		guard state != .closed else { return }
		state = .closed
		unacknowledged.removeAll()
		inFlightByteCount = 0
		reordered.removeAll()

		guard onClose != nil, pendingDelivery.isEmpty else {
			pendingClose = .some(reason)
			return
		}
		onClose?(reason)
	}

	/// The peer can answer a SYN before the owner has subscribed — and an
	/// inbound connection is open before the owner exists at all — so the event
	/// waits rather than being fired into a nil callback, exactly as the bytes
	/// behind it do.
	private func notifyConnected() {
		guard let onConnect else {
			pendingConnect = true
			return
		}
		onConnect()
	}

	private func flushPendingConnect() {
		guard pendingConnect, let onConnect else { return }
		pendingConnect = false
		onConnect()
	}

	private func deliver(_ payload: Data) {
		guard let onData, pendingDelivery.isEmpty else {
			pendingDelivery.append(payload)
			return
		}
		onData(payload)
	}

	/// Hands over anything that arrived before there was a listener, keeping
	/// the order the bytes came in and the close behind them.
	private func flushPendingDelivery() {
		if let onData, !pendingDelivery.isEmpty {
			let data = pendingDelivery
			pendingDelivery = Data()
			onData(data)
		}
		if let onClose, pendingDelivery.isEmpty, let reason = pendingClose {
			pendingClose = nil
			onClose(reason)
		}
	}

	// MARK: - Packet plumbing

	private func makePacket(
		kind: UTPPacket.Kind,
		connectionID: UInt16,
		sequenceNumber: UInt16,
		payload: Data = Data()
	) -> UTPPacket {
		UTPPacket(
			kind: kind,
			connectionID: connectionID,
			timestamp: utpNowMicroseconds(),
			timestampDifference: replyMicroseconds,
			windowSize: UInt32(max(0, Self.maximumReceiveBuffer - reorderedByteCount)),
			sequenceNumber: sequenceNumber,
			acknowledgementNumber: acknowledgementNumber,
			selectiveAck: nil,
			payload: payload
		)
	}

	private func sendState() {
		var packet = makePacket(kind: .state, connectionID: sendID, sequenceNumber: sequenceNumber)
		packet.selectiveAck = buildSelectiveAck()
		send(packet)
	}

	private func store(_ packet: UTPPacket, byteCount: Int) {
		unacknowledged[packet.sequenceNumber] = Outgoing(
			packet: packet,
			sentAt: Date(),
			transmissions: 1,
			byteCount: byteCount
		)
		inFlightByteCount += byteCount
	}

	private func send(_ packet: UTPPacket) {
		// Timestamps and acknowledgement numbers are only worth anything when
		// they are current, so they are refreshed at the moment of sending —
		// which matters most for a retransmission minted seconds ago.
		var packet = packet
		packet.timestamp = utpNowMicroseconds()
		packet.timestampDifference = replyMicroseconds
		packet.acknowledgementNumber = acknowledgementNumber
		transmit(packet, remote)
	}
}
