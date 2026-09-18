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
	/// The encrypted handshake did not work out. Worth distinguishing: a peer
	/// that cannot do MSE is not a broken peer, it is one to redial in the
	/// clear.
	case encryptionFailed(String)

	public var isFailure: Bool {
		if case .closedByPeer = self { return false }
		if case .localChoice = self { return false }
		return true
	}

	public var allowsPlaintextRetry: Bool {
		if case .encryptionFailed = self { return true }
		return false
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

		var isIncoming: Bool {
			if case .incoming = self { return true }
			return false
		}
	}

	/// A bitfield for a 4 TB torrent is ~500 KB; anything past a few megabytes
	/// is a malformed or hostile peer.
	private static let maximumMessageLength = 2 * 1024 * 1024
	private static let handshakeTimeout: TimeInterval = 15
	private static let idleTimeout: TimeInterval = 120

	/// What to do about MSE on an inbound connection before we have seen enough
	/// bytes to tell an encrypted handshake from a plaintext one.
	private enum InboundMode {
		case undecided
		case plaintext
		case encrypted
	}

	public let address: PeerAddress
	public let role: Role

	private let localPeerID: PeerID
	private let encryption: EncryptionPolicy
	/// Inbound connections do not name their torrent in the clear, so the
	/// handshake is matched against everything we are running.
	private let knownInfoHashes: @Sendable () -> [InfoHash]

	private let queue: DispatchQueue
	private let transport: PeerTransport
	private var buffer = Data()
	private var didHandshake = false
	private var didFinish = false

	private var handshakeEngine: MSEHandshake?
	private var inboundMode: InboundMode = .undecided
	/// Set once MSE has negotiated RC4; nil means the stream is in the clear,
	/// whether or not an obfuscated handshake preceded it.
	private var encryptor: RC4?
	private var decryptor: RC4?
	private var continuation: AsyncStream<PeerEvent>.Continuation?
	private var timeoutWorkItem: DispatchWorkItem?
	private var lastActivity = Date()

	private let counters = ByteCounters()

	/// Dials a peer over TCP.
	public convenience init(
		address: PeerAddress,
		role: Role,
		localPeerID: PeerID,
		encryption: EncryptionPolicy = .disabled
	) {
		self.init(
			transport: TCPTransport(to: address),
			address: address,
			role: role,
			localPeerID: localPeerID,
			encryption: encryption,
			queueLabel: "itorrent.peer.\(address.description)"
		)
	}

	/// Wraps an already-built transport, which is how a µTP connection — or an
	/// inbound TCP one the listener accepted — becomes a peer.
	init(
		transport: PeerTransport,
		address: PeerAddress,
		role: Role,
		localPeerID: PeerID,
		encryption: EncryptionPolicy,
		knownInfoHashes: @escaping @Sendable () -> [InfoHash] = { [] },
		queueLabel: String
	) {
		self.address = address
		self.role = role
		self.localPeerID = localPeerID
		self.encryption = encryption
		self.knownInfoHashes = knownInfoHashes
		self.queue = DispatchQueue(label: queueLabel)
		self.transport = transport
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
				self.transport.onReady = { [weak self] in self?.handleReady() }
				self.transport.onData = { [weak self] data in self?.handleIncoming(data) }
				self.transport.onClosed = { [weak self] reason in self?.finish(reason: reason) }
				self.armTimeout(after: Self.handshakeTimeout, reason: .timeout)
				self.transport.start(on: self.queue)
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

	/// - Parameter encrypted: false only for the MSE handshake itself, which is
	///   obfuscated by its own construction and must not go through the cipher.
	private func transmit(_ data: Data, encrypted: Bool = true) {
		let data = encrypted ? (encryptor?.process(data) ?? data) : data
		counters.addSent(data.count)
		transport.send(data)
	}

	// MARK: - Receiving

	/// The transport is up: on an outgoing connection, open the conversation.
	private func handleReady() {
		guard !didFinish else { return }
		lastActivity = Date()
		guard case let .outgoing(infoHash) = role else { return }

		let handshake = PeerHandshake(infoHash: infoHash, peerID: localPeerID.raw).encoded()
		guard encryption != .disabled else {
			transmit(handshake)
			return
		}
		// The BitTorrent handshake travels as MSE's initial payload rather than
		// after it, which saves a round trip and leaves nothing recognisable in
		// the opening bytes.
		let engine = MSEHandshake(
			role: .initiator(infoHash: infoHash, payload: handshake),
			policy: encryption
		)
		handshakeEngine = engine
		transmit(engine.begin(), encrypted: false)
	}

	private func handleIncoming(_ data: Data) {
		guard !didFinish else { return }
		counters.addReceived(data.count)
		lastActivity = Date()
		ingest(data)
	}

	/// Routes freshly arrived bytes: through the MSE handshake while one is in
	/// progress, through the cipher once one has been negotiated, and straight
	/// into the framing buffer otherwise.
	private func ingest(_ data: Data) {
		if let engine = handshakeEngine {
			advance(engine, with: data)
			return
		}
		if case .undecided = inboundMode, role.isIncoming, encryption != .disabled {
			decideInboundMode(with: data)
			return
		}
		buffer.append(decryptor?.process(data) ?? data)
		drainBuffer()
	}

	/// Tells an encrypted handshake from a plaintext one.
	///
	/// A plaintext handshake opens with the protocol string, and the odds of an
	/// MSE public key doing the same are one in 2^160 — so the first twenty
	/// bytes settle it, and nothing has to be guessed from a single byte.
	private func decideInboundMode(with data: Data) {
		buffer.append(data)
		guard buffer.count >= PeerHandshake.protocolHeader.count else { return }

		if buffer.prefix(PeerHandshake.protocolHeader.count) == PeerHandshake.protocolHeader {
			guard encryption != .required else {
				finish(reason: .protocolViolation("Plaintext handshake refused"))
				return
			}
			inboundMode = .plaintext
			drainBuffer()
			return
		}

		inboundMode = .encrypted
		let engine = MSEHandshake(
			role: .receiver(candidates: knownInfoHashes),
			policy: encryption
		)
		handshakeEngine = engine
		let pending = buffer
		buffer = Data()
		advance(engine, with: pending)
	}

	private func advance(_ engine: MSEHandshake, with data: Data) {
		let progress = engine.consume(data)
		if !progress.outgoing.isEmpty {
			transmit(progress.outgoing, encrypted: false)
		}

		switch progress.outcome {
		case .needMoreData:
			return

		case let .failed(reason):
			Log.peer.debug("MSE handshake with \(self.address.description, privacy: .public) failed: \(reason, privacy: .public)")
			handshakeEngine = nil
			finish(reason: .encryptionFailed(reason))

		case let .completed(completion):
			handshakeEngine = nil
			encryptor = completion.encrypt
			decryptor = completion.decrypt
			Log.peer.debug("MSE handshake with \(self.address.description, privacy: .public) completed")
			buffer.append(completion.leftover)
			drainBuffer()
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

		// Anything that goes wrong while the encrypted handshake is still in
		// flight is a failure *of* that handshake, whatever the socket called
		// it. A peer with encryption switched off does not answer politely: it
		// reads our public key as a malformed handshake and hangs up, which
		// arrives here as an ordinary close. Reporting it as such would retire
		// a peer that plaintext would have reached.
		var reason = reason
		if handshakeEngine != nil, !didHandshake {
			if case .localChoice = reason {} else {
				reason = .encryptionFailed("Connection lost during the encrypted handshake")
			}
		}
		timeoutWorkItem?.cancel()
		timeoutWorkItem = nil
		transport.cancel()
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

	private let queue = DispatchQueue(label: "itorrent.listener")
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
