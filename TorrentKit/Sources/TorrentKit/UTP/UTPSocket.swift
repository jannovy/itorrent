import Foundation

/// Multiplexes every µTP connection over one UDP port.
///
/// µTP shares the port number the client announces to trackers, so a peer that
/// cannot reach us over TCP can try the same address over UDP. All connections
/// live on one socket and are told apart by their connection id, which is also
/// why this is a BSD socket rather than `NWConnection`: Network.framework
/// models UDP as one object per remote endpoint.
final class UTPSocket: @unchecked Sendable {

	/// How often retransmission timers are checked. Fast enough for the 500 ms
	/// minimum timeout, slow enough to be invisible on a phone's battery.
	private static let tickInterval: TimeInterval = 0.05

	let queue = DispatchQueue(label: "itorrent.utp")

	private var datagrams: DatagramSocket?
	private var connections: [ConnectionKey: UTPConnection] = [:]
	private var timer: DispatchSourceTimer?
	private var isRunning = false

	/// Called on `queue` for every connection a peer opens to us.
	var onIncomingConnection: ((UTPConnection) -> Void)?

	/// Test hook: return true to pretend a packet was lost in the network.
	var shouldDropOutgoingPacket: ((UTPPacket) -> Bool)?

	private struct ConnectionKey: Hashable {
		let host: String
		let port: UInt16
		let connectionID: UInt16
	}

	private(set) var localPort: UInt16 = 0

	init() {}

	func start(port: UInt16) throws {
		try queue.sync {
			guard !isRunning else { return }
			let socket = try DatagramSocket(port: port)
			socket.onDatagram = { [weak self] data, from in
				// DatagramSocket delivers on its own queue; everything about a
				// connection belongs to ours.
				self?.queue.async { self?.handle(data, from: from) }
			}
			datagrams = socket
			localPort = socket.localPort
			isRunning = true
			startTimer()
		}
	}

	func stop() {
		queue.sync {
			isRunning = false
			timer?.cancel()
			timer = nil
			for connection in connections.values { connection.reset() }
			connections.removeAll()
			datagrams?.close()
			datagrams = nil
			localPort = 0
		}
	}

	private func startTimer() {
		let timer = DispatchSource.makeTimerSource(queue: queue)
		timer.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval)
		timer.setEventHandler { [weak self] in self?.tick() }
		self.timer = timer
		timer.resume()
	}

	private func tick() {
		let now = Date()
		for connection in connections.values {
			connection.tick(now: now)
		}
		reapClosedConnections()
	}

	private func reapClosedConnections() {
		for (key, connection) in connections where connection.state == .closed {
			connections[key] = nil
		}
	}

	// MARK: - Dialling

	/// Opens a connection to a peer and sends its SYN.
	///
	/// Must be called on `queue`: the connection table belongs to it, and the
	/// alternative — a `sync` hop from the session actor — would block the
	/// actor that publishes the whole UI behind whatever the socket is doing.
	func dial(to remote: PeerAddress) -> UTPConnection {
		dispatchPrecondition(condition: .onQueue(queue))

		// The initiator picks its receive id at random and sends on the next
		// one up, which is how both sides end up with a matching pair.
		var recvID = UInt16.random(in: 1...(UInt16.max - 1))
		while connections[ConnectionKey(host: remote.host, port: remote.port, connectionID: recvID)] != nil {
			recvID = UInt16.random(in: 1...(UInt16.max - 1))
		}

		let connection = makeConnection(
			remote: remote,
			recvID: recvID,
			sendID: recvID &+ 1,
			isInitiator: true
		)
		connection.connect()
		return connection
	}

	private func makeConnection(
		remote: PeerAddress,
		recvID: UInt16,
		sendID: UInt16,
		isInitiator: Bool
	) -> UTPConnection {
		let connection = UTPConnection(
			remote: remote,
			recvID: recvID,
			sendID: sendID,
			isInitiator: isInitiator,
			transmit: { [weak self] packet, destination in
				self?.transmit(packet, to: destination)
			}
		)
		connections[ConnectionKey(host: remote.host, port: remote.port, connectionID: recvID)] = connection
		return connection
	}

	private func transmit(_ packet: UTPPacket, to remote: PeerAddress) {
		if let shouldDropOutgoingPacket, shouldDropOutgoingPacket(packet) { return }
		datagrams?.send(packet.encoded(), to: remote)
	}

	// MARK: - Receiving

	private func handle(_ data: Data, from remote: PeerAddress) {
		guard let packet = UTPPacket(data: data) else { return }

		let key = ConnectionKey(host: remote.host, port: remote.port, connectionID: packet.connectionID)
		if let connection = connections[key] {
			connection.receive(packet)
			if connection.state == .closed { connections[key] = nil }
			return
		}

		guard packet.kind == .syn else {
			// Nothing here by that id. A reset tells the peer to stop resending
			// rather than leaving it to time out.
			if packet.kind != .reset { sendReset(to: remote, connectionID: packet.connectionID) }
			return
		}

		// The peer's SYN names the id it will listen on; we send on that one
		// and receive on the next.
		let connection = makeConnection(
			remote: remote,
			recvID: packet.connectionID &+ 1,
			sendID: packet.connectionID,
			isInitiator: false
		)
		connection.acceptSyn(packet)
		onIncomingConnection?(connection)
	}

	private func sendReset(to remote: PeerAddress, connectionID: UInt16) {
		let reset = UTPPacket(
			kind: .reset,
			connectionID: connectionID,
			timestamp: utpNowMicroseconds(),
			sequenceNumber: UInt16.random(in: 0...UInt16.max)
		)
		datagrams?.send(reset.encoded(), to: remote)
	}
}
