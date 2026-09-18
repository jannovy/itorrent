import Foundation
import Network

/// BEP 15 UDP tracker protocol.
///
/// The exchange is two round trips: `connect` yields a connection id valid for
/// one minute, then `announce` uses it. The id is cached so back-to-back
/// announces to the same tracker only cost one round trip.
public final class UDPTracker: TrackerClient, @unchecked Sendable {
	private enum Action: UInt32 {
		case connect = 0, announce = 1, scrape = 2, error = 3
	}

	private static let magicConnectionID: UInt64 = 0x0417_2710_1980
	// Connect plus two exchanges must stay inside TrackerManager's own
	// backstop, otherwise the manager kills the announce before the UDP layer
	// gets to report a useful error.
	private static let responseTimeout: TimeInterval = 10
	/// A UDP "connection" only has to resolve the host and pick a route, so a
	/// slow one is a dead one. Cellular networks in particular can leave the
	/// endpoint sitting in `.preparing` indefinitely.
	private static let connectTimeout: TimeInterval = 8

	public let url: String
	private let host: String
	private let port: UInt16

	public init(url: String, host: String, port: UInt16) {
		self.url = url
		self.host = host
		self.port = port == 0 ? 80 : port
	}

	public func announce(_ request: AnnounceRequest) async throws -> AnnounceResponse {
		let socket = UDPSocket(host: host, port: port)
		defer { socket.close() }
		try await socket.connect(timeout: Self.connectTimeout)

		let connectionID = try await obtainConnectionID(using: socket)
		let transactionID = UInt32.random(in: .min ... .max)

		var payload = Data()
		payload.appendBigEndian(connectionID)
		payload.appendBigEndian(Action.announce.rawValue)
		payload.appendBigEndian(transactionID)
		payload.append(request.infoHash.raw)
		payload.append(request.peerID.raw)
		payload.appendBigEndian(UInt64(max(0, request.downloaded)))
		payload.appendBigEndian(UInt64(max(0, request.left)))
		payload.appendBigEndian(UInt64(max(0, request.uploaded)))
		payload.appendBigEndian(Self.eventCode(request.event))
		payload.appendBigEndian(UInt32(0)) // IP address: let the tracker use the source address
		payload.appendBigEndian(request.key)
		payload.appendBigEndian(UInt32(bitPattern: Int32(request.numberWanted)))
		payload.appendBigEndian(request.port)

		let response = try await socket.exchange(payload, timeout: Self.responseTimeout)
		return try parseAnnounce(response, transactionID: transactionID)
	}

	/// Performs the BEP 15 connect handshake.
	///
	/// The id this returns is bound to the socket's source endpoint, so it is
	/// deliberately not cached across announces: every announce opens a fresh
	/// socket on a new ephemeral port, and a tracker that enforces the binding
	/// would reject a reused id.
	private func obtainConnectionID(using socket: UDPSocket) async throws -> UInt64 {
		let transactionID = UInt32.random(in: .min ... .max)
		var payload = Data()
		payload.appendBigEndian(Self.magicConnectionID)
		payload.appendBigEndian(Action.connect.rawValue)
		payload.appendBigEndian(transactionID)

		let response = try await socket.exchange(payload, timeout: Self.responseTimeout)
		guard response.count >= 16,
		      let action = response.bigEndianUInt32(at: 0),
		      let echoed = response.bigEndianUInt32(at: 4),
		      echoed == transactionID
		else { throw TrackerError.malformedResponse }

		if action == Action.error.rawValue {
			throw TrackerError.rejected(Self.errorMessage(response))
		}
		guard action == Action.connect.rawValue else { throw TrackerError.malformedResponse }

		var connectionID: UInt64 = 0
		for offset in 8..<16 {
			connectionID = connectionID << 8 | UInt64(response[response.startIndex + offset])
		}
		return connectionID
	}

	private func parseAnnounce(_ response: Data, transactionID: UInt32) throws -> AnnounceResponse {
		guard response.count >= 8,
		      let action = response.bigEndianUInt32(at: 0),
		      let echoed = response.bigEndianUInt32(at: 4),
		      echoed == transactionID
		else { throw TrackerError.malformedResponse }

		if action == Action.error.rawValue {
			throw TrackerError.rejected(Self.errorMessage(response))
		}
		guard action == Action.announce.rawValue, response.count >= 20 else {
			throw TrackerError.malformedResponse
		}

		let interval = TimeInterval(response.bigEndianUInt32(at: 8) ?? 1800)
		let leechers = Int(response.bigEndianUInt32(at: 12) ?? 0)
		let seeders = Int(response.bigEndianUInt32(at: 16) ?? 0)
		let peers = PeerAddress.decodeCompact(response.dropFirst(20), isIPv6: false)

		return AnnounceResponse(
			interval: max(60, interval),
			seeders: seeders,
			leechers: leechers,
			peers: peers
		)
	}

	private static func eventCode(_ event: AnnounceEvent) -> UInt32 {
		switch event {
		case .periodic: 0
		case .completed: 1
		case .started: 2
		case .stopped: 3
		}
	}

	private static func errorMessage(_ response: Data) -> String {
		let text = String(decoding: response.dropFirst(8), as: UTF8.self)
		return text.isEmpty ? "The tracker returned an error." : text
	}
}

/// A one-shot UDP request/response socket.
final class UDPSocket: @unchecked Sendable {
	private let connection: NWConnection
	private let queue = DispatchQueue(label: "itorrent.udp")

	init(host: String, port: UInt16) {
		let endpoint = NWEndpoint.hostPort(
			host: NWEndpoint.Host(host),
			port: NWEndpoint.Port(rawValue: port) ?? 80
		)
		connection = NWConnection(to: endpoint, using: .udp)
	}

	/// Resolves the host and waits for the endpoint to become usable.
	///
	/// A send on a non-ready UDP connection is silently queued and can outlive
	/// the response timeout, so the caller waits for readiness first. The wait
	/// is bounded and cancellable: cancelling tears the connection down, which
	/// drives the state handler and resumes the continuation.
	func connect(timeout: TimeInterval) async throws {
		try await withTimeout(seconds: timeout) { [connection, queue] in
			try await withTaskCancellationHandler {
				try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
					let resumed = OSAllocatedUnfairLockBox(false)
					connection.stateUpdateHandler = { state in
						switch state {
						case .ready:
							if resumed.setTrueIfFalse() { continuation.resume() }
						case let .failed(error):
							if resumed.setTrueIfFalse() { continuation.resume(throwing: error) }
						case let .waiting(error):
							if resumed.setTrueIfFalse() { continuation.resume(throwing: error) }
						case .cancelled:
							if resumed.setTrueIfFalse() { continuation.resume(throwing: TrackerError.interrupted) }
						default:
							break
						}
					}
					connection.start(queue: queue)
				}
			} onCancel: {
				connection.cancel()
			}
		}
	}

	func exchange(_ payload: Data, timeout: TimeInterval) async throws -> Data {
		try await withTimeout(seconds: timeout) { [connection] in
			try await withTaskCancellationHandler {
				try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
					let resumed = OSAllocatedUnfairLockBox(false)
					connection.send(content: payload, completion: .contentProcessed { error in
						if let error, resumed.setTrueIfFalse() {
							continuation.resume(throwing: error)
						}
					})
					connection.receiveMessage { data, _, _, error in
						guard resumed.setTrueIfFalse() else { return }
						if let error {
							continuation.resume(throwing: error)
						} else if let data, !data.isEmpty {
							continuation.resume(returning: data)
						} else {
							continuation.resume(throwing: TrackerError.malformedResponse)
						}
					}
				}
			} onCancel: {
				// Cancelling the connection completes the pending receive with
				// an error, which resumes the continuation above.
				connection.cancel()
			}
		}
	}

	func close() {
		connection.stateUpdateHandler = nil
		connection.cancel()
	}
}

/// Guards a continuation against the double-resume that Network.framework's
/// overlapping send/receive callbacks can otherwise cause.
final class OSAllocatedUnfairLockBox: @unchecked Sendable {
	private let lock = NSLock()
	private var value: Bool

	init(_ value: Bool) {
		self.value = value
	}

	/// Returns true exactly once, to the first caller.
	func setTrueIfFalse() -> Bool {
		lock.lock()
		defer { lock.unlock() }
		if value { return false }
		value = true
		return true
	}
}
