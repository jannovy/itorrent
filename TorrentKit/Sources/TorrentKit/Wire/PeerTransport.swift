import Foundation
import Network

/// A reliable, ordered byte stream to a peer — TCP or µTP.
///
/// `PeerConnection` frames the BitTorrent protocol and does not care which of
/// the two carries it, which is the whole reason this exists: µTP is not a
/// different protocol, it is the same protocol over a transport that yields to
/// the rest of the household's traffic.
///
/// Every callback is delivered on the queue passed to `start`, in order.
public protocol PeerTransport: AnyObject {
	func start(on queue: DispatchQueue)
	func send(_ data: Data)
	func cancel()

	var onReady: (() -> Void)? { get set }
	var onData: ((Data) -> Void)? { get set }
	var onClosed: ((PeerDisconnectReason) -> Void)? { get set }
}

/// TCP, via Network.framework.
final class TCPTransport: PeerTransport {
	private let connection: NWConnection
	private var queue = DispatchQueue(label: "itorrent.transport.tcp")
	private var isCancelled = false

	var onReady: (() -> Void)?
	var onData: ((Data) -> Void)?
	var onClosed: ((PeerDisconnectReason) -> Void)?

	init(to address: PeerAddress) {
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
	init(accepted connection: NWConnection) {
		self.connection = connection
	}

	func start(on queue: DispatchQueue) {
		self.queue = queue
		connection.stateUpdateHandler = { [weak self] state in
			guard let self else { return }
			self.queue.async { self.handle(state: state) }
		}
		connection.start(queue: queue)
	}

	func send(_ data: Data) {
		connection.send(content: data, completion: .contentProcessed { [weak self] error in
			guard let self, let error else { return }
			self.queue.async { self.close(reason: .network(error.localizedDescription)) }
		})
	}

	func cancel() {
		isCancelled = true
		connection.stateUpdateHandler = nil
		connection.cancel()
	}

	private func handle(state: NWConnection.State) {
		switch state {
		case .ready:
			onReady?()
			receiveNext()
		case let .failed(error):
			close(reason: .network(error.localizedDescription))
		case .cancelled:
			close(reason: .localChoice)
		case let .waiting(error):
			// `waiting` means the path is unusable; for a short-lived peer
			// connection there is nothing to wait for.
			close(reason: .network(error.localizedDescription))
		default:
			break
		}
	}

	private func receiveNext() {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
			guard let self else { return }
			self.queue.async {
				if let error {
					self.close(reason: .network(error.localizedDescription))
					return
				}
				if let data, !data.isEmpty {
					self.onData?(data)
				}
				if isComplete {
					self.close(reason: .closedByPeer)
					return
				}
				guard !self.isCancelled else { return }
				self.receiveNext()
			}
		}
	}

	private func close(reason: PeerDisconnectReason) {
		guard !isCancelled else { return }
		isCancelled = true
		onClosed?(reason)
	}
}

/// µTP, via the session's shared UDP socket.
///
/// The connection's callbacks arrive on the µTP socket's queue and are hopped
/// onto the peer's own queue. Both are serial and the hop is an ordinary async
/// dispatch, so the byte order the stream depends on is preserved — which is
/// exactly what an actor hop would not guarantee.
///
/// An outbound connection is not dialled until `start`, so handing one of these
/// out costs nothing and needs no lock: everything touching the connection
/// happens on the socket's queue, in order.
final class UTPTransport: PeerTransport {
	private enum Source {
		case dial(socket: UTPSocket, address: PeerAddress)
		case accepted(UTPConnection)
	}

	private let source: Source
	private let socketQueue: DispatchQueue
	/// Only ever touched on `socketQueue`.
	private var connection: UTPConnection?
	private var queue = DispatchQueue(label: "itorrent.transport.utp")
	private var isCancelled = false

	var onReady: (() -> Void)?
	var onData: ((Data) -> Void)?
	var onClosed: ((PeerDisconnectReason) -> Void)?

	/// Wraps a connection a peer opened to us.
	init(connection: UTPConnection, socketQueue: DispatchQueue) {
		self.source = .accepted(connection)
		self.socketQueue = socketQueue
	}

	/// Prepares to dial a peer. Nothing goes on the wire until `start`.
	init(socket: UTPSocket, address: PeerAddress) {
		self.source = .dial(socket: socket, address: address)
		self.socketQueue = socket.queue
	}

	func start(on queue: DispatchQueue) {
		self.queue = queue
		socketQueue.async { [weak self] in
			guard let self, !self.isCancelled else { return }

			let connection: UTPConnection
			switch self.source {
			case let .accepted(existing):
				connection = existing
			case let .dial(socket, address):
				connection = socket.dial(to: address)
			}
			self.connection = connection

			// An inbound connection is already open by the time we see it.
			let wasOpen = connection.isOpen

			connection.onConnect = { [weak self] in
				guard let self else { return }
				self.queue.async { self.onReady?() }
			}
			connection.onData = { [weak self] data in
				guard let self else { return }
				self.queue.async { self.onData?(data) }
			}
			connection.onClose = { [weak self] reason in
				guard let self else { return }
				self.queue.async {
					self.close(reason: reason.map { .network($0) } ?? .closedByPeer)
				}
			}
			if wasOpen {
				self.queue.async { self.onReady?() }
			}
		}
	}

	func send(_ data: Data) {
		socketQueue.async { [weak self] in
			self?.connection?.write(data)
		}
	}

	func cancel() {
		isCancelled = true
		socketQueue.async { [weak self] in
			self?.connection?.close()
		}
	}

	private func close(reason: PeerDisconnectReason) {
		guard !isCancelled else { return }
		isCancelled = true
		onClosed?(reason)
	}
}
