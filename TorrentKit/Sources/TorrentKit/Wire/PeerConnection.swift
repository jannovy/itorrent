import Foundation
import Network

public enum PeerEvent: Sendable {
	/// The handshake has been exchanged (outgoing) or received (incoming).
	case handshake(PeerHandshake)
	case message(PeerMessage)
	case disconnected(PeerDisconnectReason)
}

public enum PeerDisconnectReason: Sendable {
	case closedByPeer
	case timeout
	case protocolViolation(String)
	case network(String)
	case localChoice

	public var isFailure: Bool {
		if case .closedByPeer = self { return false }
		if case .localChoice = self { return false }
		return true
	}
}

/// A single TCP connection to a peer, framing the BitTorrent wire protocol.
///
/// All mutable state lives on `queue`, a serial dispatch queue, and events are
/// published through an `AsyncStream`. Doing the framing on a serial queue
/// rather than inside an actor is deliberate: actor hops from Network.framework
/// callbacks are not order-preserving, and a byte stream reordered by even one
/// chunk is unrecoverable.
public final class PeerConnection: @unchecked Sendable {

	public enum Role: Sendable {
		case outgoing(infoHash: InfoHash)
		case incoming
	}

	/// A bitfield for a 4 TB torrent is ~500 KB; anything past a few megabytes
	/// is a malformed or hostile peer.
	private static let maximumMessageLength = 2 * 1024 * 1024
	private static let handshakeTimeout: TimeInterval = 15
	private static let idleTimeout: TimeInterval = 120

	public let address: PeerAddress
	public let role: Role

	private let localPeerID: PeerID
	private let queue: DispatchQueue
	private let connection: NWConnection
	private var buffer = Data()
	private var didHandshake = false
	private var didFinish = false
	private var continuation: AsyncStream<PeerEvent>.Continuation?
	private var timeoutWorkItem: DispatchWorkItem?
	private var lastActivity = Date()

	private let counters = ByteCounters()

	public init(address: PeerAddress, role: Role, localPeerID: PeerID) {
		self.address = address
		self.role = role
		self.localPeerID = localPeerID
		self.queue = DispatchQueue(label: "swarm.peer.\(address.description)")

		let parameters = NWParameters.tcp
		parameters.prohibitExpensivePaths = false
		if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
			tcp.noDelay = true
			tcp.connectionTimeout = 10
			tcp.enableKeepalive = true
			tcp.keepaliveIdle = 60
		}
		self.connection = NWConnection(to: address.endpoint, using: parameters)
	}

	/// Wraps a connection handed over by `PeerListener`.
	public init(incoming connection: NWConnection, address: PeerAddress, localPeerID: PeerID) {
		self.address = address
		self.role = .incoming
		self.localPeerID = localPeerID
		self.queue = DispatchQueue(label: "swarm.peer.in.\(address.description)")
		self.connection = connection
	}

	public var bytesReceived: Int64 { counters.received }
	public var bytesSent: Int64 { counters.sent }

	// MARK: - Lifecycle

	public func start() -> AsyncStream<PeerEvent> {
		AsyncStream { continuation in
			queue.async { [weak self] in
				guard let self else {
					continuation.finish()
					return
				}
				self.continuation = continuation
				continuation.onTermination = { [weak self] _ in
					self?.close(reason: .localChoice)
				}
				self.connection.stateUpdateHandler = { [weak self] state in
					self?.queue.async { self?.handle(state: state) }
				}
				self.armTimeout(after: Self.handshakeTimeout, reason: .timeout)
				self.connection.start(queue: self.queue)
			}
		}
	}

	public func close(reason: PeerDisconnectReason = .localChoice) {
		queue.async { [weak self] in self?.finish(reason: reason) }
	}

	// MARK: - Sending

	public func send(_ message: PeerMessage) {
		let data = message.encoded()
		queue.async { [weak self] in
			guard let self, !self.didFinish else { return }
			self.transmit(data)
		}
	}

	public func send(_ messages: [PeerMessage]) {
		guard !messages.isEmpty else { return }
		var data = Data()
		for message in messages { data.append(message.encoded()) }
		queue.async { [weak self] in
			guard let self, !self.didFinish else { return }
			self.transmit(data)
		}
	}

	/// Completes an incoming handshake once the session has matched the
	/// info-hash to a torrent it is actually running.
	public func acceptIncomingHandshake(infoHash: InfoHash) {
		queue.async { [weak self] in
			guard let self, !self.didFinish else { return }
			self.transmit(PeerHandshake(infoHash: infoHash, peerID: self.localPeerID.raw).encoded())
		}
	}

	private func transmit(_ data: Data) {
		connection.send(content: data, completion: .contentProcessed { [weak self] error in
			guard let self else { return }
			if let error {
				self.queue.async { self.finish(reason: .network(error.localizedDescription)) }
			} else {
				self.counters.addSent(data.count)
			}
		})
	}

	// MARK: - Receiving

	private func handle(state: NWConnection.State) {
		switch state {
		case .ready:
			lastActivity = Date()
			if case let .outgoing(infoHash) = role {
				transmit(PeerHandshake(infoHash: infoHash, peerID: localPeerID.raw).encoded())
			}
			receiveNext()

		case let .failed(error):
			finish(reason: .network(error.localizedDescription))

		case .cancelled:
			finish(reason: .localChoice)

		case let .waiting(error):
			// `waiting` means the path is unusable; for a short-lived peer
			// connection there is nothing to wait for.
			finish(reason: .network(error.localizedDescription))

		default:
			break
		}
	}

	private func receiveNext() {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
			guard let self else { return }
			self.queue.async {
				if let error {
					self.finish(reason: .network(error.localizedDescription))
					return
				}
				if let data, !data.isEmpty {
					self.counters.addReceived(data.count)
					self.lastActivity = Date()
					self.buffer.append(data)
					self.drainBuffer()
				}
				if isComplete {
					self.finish(reason: .closedByPeer)
					return
				}
				guard !self.didFinish else { return }
				self.receiveNext()
			}
		}
	}

	private func drainBuffer() {
		while !didFinish {
			if !didHandshake {
				guard buffer.count >= PeerHandshake.byteCount else { return }
				guard let handshake = PeerHandshake(data: buffer) else {
					finish(reason: .protocolViolation("Malformed handshake"))
					return
				}
				if case let .outgoing(expected) = role, handshake.infoHash != expected {
					finish(reason: .protocolViolation("Handshake info-hash mismatch"))
					return
				}
				consume(PeerHandshake.byteCount)
				didHandshake = true
				armTimeout(after: Self.idleTimeout, reason: .timeout)
				continuation?.yield(.handshake(handshake))
				continue
			}

			guard buffer.count >= 4, let length = buffer.bigEndianUInt32(at: 0) else { return }
			guard length <= UInt32(Self.maximumMessageLength) else {
				finish(reason: .protocolViolation("Message of \(length) bytes exceeds the limit"))
				return
			}
			let total = 4 + Int(length)
			guard buffer.count >= total else { return }

			let bodyStart = buffer.startIndex + 4
			let body = buffer.subdata(in: bodyStart..<(buffer.startIndex + total))
			consume(total)

			do {
				let message = try PeerMessage.decode(body: body)
				continuation?.yield(.message(message))
			} catch PeerMessageError.unknownIdentifier {
				// Unknown message ids are reserved for future extensions and
				// must be skipped, not treated as an error.
				continue
			} catch {
				finish(reason: .protocolViolation("Undecodable message"))
				return
			}
		}
	}

	/// Drops `count` bytes from the front of the receive buffer.
	///
	/// `Data.removeFirst` advances `startIndex` rather than rebasing, so the
	/// backing store is kept and every later absolute index is off by the
	/// amount consumed so far. The buffer is rebased once the offset grows,
	/// which also stops a long-lived connection from pinning megabytes of
	/// already-consumed bytes.
	private func consume(_ count: Int) {
		buffer.removeFirst(count)
		if buffer.isEmpty {
			buffer = Data()
		} else if buffer.startIndex > 256 * 1024 {
			buffer = Data(buffer)
		}
	}

	// MARK: - Timeouts

	private func armTimeout(after interval: TimeInterval, reason: PeerDisconnectReason) {
		timeoutWorkItem?.cancel()
		let item = DispatchWorkItem { [weak self] in
			guard let self, !self.didFinish else { return }
			if Date().timeIntervalSince(self.lastActivity) >= interval {
				self.finish(reason: reason)
			} else {
				self.armTimeout(after: interval, reason: reason)
			}
		}
		timeoutWorkItem = item
		queue.asyncAfter(deadline: .now() + interval, execute: item)
	}

	private func finish(reason: PeerDisconnectReason) {
		guard !didFinish else { return }
		didFinish = true
		timeoutWorkItem?.cancel()
		timeoutWorkItem = nil
		connection.stateUpdateHandler = nil
		connection.cancel()
		continuation?.yield(.disconnected(reason))
		continuation?.finish()
		continuation = nil
	}
}

/// Byte counters shared across queues; a lock is cheaper here than bouncing
/// every accounting update through the connection queue.
private final class ByteCounters: @unchecked Sendable {
	private let lock = NSLock()
	private var receivedBytes: Int64 = 0
	private var sentBytes: Int64 = 0

	var received: Int64 { lock.withLock { receivedBytes } }
	var sent: Int64 { lock.withLock { sentBytes } }

	func addReceived(_ count: Int) { lock.withLock { receivedBytes += Int64(count) } }
	func addSent(_ count: Int) { lock.withLock { sentBytes += Int64(count) } }
}

/// Sequential, hand-offable view of a peer's event stream.
///
/// `TorrentSession` reads the first event (the handshake) to work out which
/// torrent an inbound connection belongs to, then hands the rest to that
/// torrent. An `AsyncStream` has a single consumer, so the iterator is boxed
/// here and passed along rather than the stream being started twice.
public final class PeerEventChannel: @unchecked Sendable {
	private var iterator: AsyncStream<PeerEvent>.AsyncIterator

	public init(_ stream: AsyncStream<PeerEvent>) {
		self.iterator = stream.makeAsyncIterator()
	}

	public func next() async -> PeerEvent? {
		await iterator.next()
	}
}

/// Accepts inbound peer connections so we are reachable rather than
/// connect-only, which roughly doubles the peers a swarm will give us.
public final class PeerListener: @unchecked Sendable {
	public struct Incoming: Sendable {
		public let connection: NWConnection
		public let address: PeerAddress
	}

	private let queue = DispatchQueue(label: "swarm.listener")
	private var listener: NWListener?
	private var continuation: AsyncStream<Incoming>.Continuation?

	private let portLock = NSLock()
	private var boundPort: UInt16 = 0

	/// The port we are actually listening on, or zero until the listener is up.
	///
	/// Announcing port zero to a tracker makes us unreachable: the tracker hands
	/// our address to other peers with a port nobody can connect to, so every
	/// connection has to be one we dial ourselves.
	public var port: UInt16 {
		portLock.withLock { boundPort }
	}

	public init() {}

	public func start(preferredPort: UInt16) -> AsyncStream<Incoming> {
		AsyncStream { continuation in
			queue.async { [weak self] in
				guard let self else {
					continuation.finish()
					return
				}
				self.continuation = continuation
				do {
					let parameters = NWParameters.tcp
					parameters.allowLocalEndpointReuse = true
					let listener = try NWListener(
						using: parameters,
						on: NWEndpoint.Port(rawValue: preferredPort) ?? .any
					)
					listener.newConnectionHandler = { [weak self] connection in
						guard let self else { return }
						let address = Self.address(of: connection.endpoint)
						self.continuation?.yield(Incoming(connection: connection, address: address))
					}
					listener.stateUpdateHandler = { [weak self] state in
						guard let self else { return }
						if case .ready = state, let assigned = listener.port?.rawValue {
							self.portLock.withLock { self.boundPort = assigned }
						}
						if case .failed = state {
							self.continuation?.finish()
						}
					}
					self.listener = listener
					listener.start(queue: self.queue)
				} catch {
					continuation.finish()
				}
			}
		}
	}

	/// Waits for the listener to bind, so callers do not announce port zero.
	public func waitUntilReady(timeout: TimeInterval) async -> UInt16 {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			let current = port
			if current > 0 { return current }
			try? await Task.sleep(nanoseconds: 50_000_000)
		}
		return port
	}

	public func stop() {
		portLock.withLock { boundPort = 0 }
		queue.async { [weak self] in
			self?.listener?.cancel()
			self?.listener = nil
			self?.continuation?.finish()
			self?.continuation = nil
		}
	}

	static func address(of endpoint: NWEndpoint) -> PeerAddress {
		switch endpoint {
		case let .hostPort(host, port):
			var text = "\(host)"
			// NWEndpoint.Host prints scoped IPv6 as "fe80::1%en0".
			if let percent = text.firstIndex(of: "%") { text = String(text[text.startIndex..<percent]) }
			return PeerAddress(host: text, port: port.rawValue)
		default:
			return PeerAddress(host: "0.0.0.0", port: 0)
		}
	}
}
