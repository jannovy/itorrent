import Darwin
import Foundation

/// A plain IPv4 UDP socket.
///
/// The DHT talks to thousands of short-lived remote addresses from one local
/// port. Network.framework models UDP as a connection per remote endpoint,
/// which would mean thousands of `NWConnection` objects; a BSD socket with a
/// dispatch read source is both simpler and far cheaper here.
final class DatagramSocket: @unchecked Sendable {
	private let descriptor: Int32
	private let queue = DispatchQueue(label: "swarm.dht.socket")
	private var readSource: DispatchSourceRead?
	private var isClosed = false

	private(set) var localPort: UInt16 = 0

	/// Called on the socket queue for every datagram received.
	var onDatagram: ((Data, PeerAddress) -> Void)?

	init(port: UInt16) throws {
		descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
		guard descriptor >= 0 else { throw DatagramSocketError.cannotCreate(errno) }

		var reuse: Int32 = 1
		setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

		var address = sockaddr_in()
		address.sin_family = sa_family_t(AF_INET)
		address.sin_port = port.bigEndian
		address.sin_addr.s_addr = INADDR_ANY
		address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

		let bindResult = withUnsafePointer(to: &address) { pointer in
			pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
				bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
			}
		}
		guard bindResult == 0 else {
			Darwin.close(descriptor)
			throw DatagramSocketError.cannotBind(errno)
		}

		localPort = Self.boundPort(of: descriptor) ?? port

		var flags = fcntl(descriptor, F_GETFL, 0)
		flags |= O_NONBLOCK
		_ = fcntl(descriptor, F_SETFL, flags)

		startReading()
	}

	private static func boundPort(of descriptor: Int32) -> UInt16? {
		var address = sockaddr_in()
		var length = socklen_t(MemoryLayout<sockaddr_in>.size)
		let result = withUnsafeMutablePointer(to: &address) { pointer in
			pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
				getsockname(descriptor, sockaddrPointer, &length)
			}
		}
		guard result == 0 else { return nil }
		return UInt16(bigEndian: address.sin_port)
	}

	private func startReading() {
		let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
		source.setEventHandler { [weak self] in self?.drain() }
		source.setCancelHandler { [descriptor] in Darwin.close(descriptor) }
		readSource = source
		source.resume()
	}

	private func drain() {
		var buffer = [UInt8](repeating: 0, count: 2048)
		while !isClosed {
			var remote = sockaddr_in()
			var length = socklen_t(MemoryLayout<sockaddr_in>.size)
			let received = withUnsafeMutablePointer(to: &remote) { pointer in
				pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
					recvfrom(descriptor, &buffer, buffer.count, 0, sockaddrPointer, &length)
				}
			}
			guard received > 0 else { return } // EWOULDBLOCK ends the drain
			let data = Data(buffer[0..<received])
			let host = Self.formatIPv4(remote.sin_addr.s_addr)
			let peer = PeerAddress(host: host, port: UInt16(bigEndian: remote.sin_port))
			onDatagram?(data, peer)
		}
	}

	func send(_ data: Data, to peer: PeerAddress) {
		queue.async { [weak self] in
			guard let self, !self.isClosed else { return }
			var address = sockaddr_in()
			address.sin_family = sa_family_t(AF_INET)
			address.sin_port = peer.port.bigEndian
			address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
			guard inet_pton(AF_INET, peer.host, &address.sin_addr) == 1 else { return }

			_ = data.withUnsafeBytes { rawBuffer in
				withUnsafePointer(to: &address) { pointer in
					pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
						sendto(
							self.descriptor,
							rawBuffer.baseAddress,
							rawBuffer.count,
							0,
							sockaddrPointer,
							socklen_t(MemoryLayout<sockaddr_in>.size)
						)
					}
				}
			}
		}
	}

	func close() {
		queue.async { [weak self] in
			guard let self, !self.isClosed else { return }
			self.isClosed = true
			self.onDatagram = nil
			self.readSource?.cancel()
			self.readSource = nil
		}
	}

	private static func formatIPv4(_ address: in_addr_t) -> String {
		let value = UInt32(bigEndian: address)
		return "\(value >> 24 & 0xFF).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
	}
}

enum DatagramSocketError: Error {
	case cannotCreate(Int32)
	case cannotBind(Int32)
}

/// Resolves a hostname to IPv4 addresses. DHT bootstrap nodes are given as
/// names, and the socket layer needs literals.
enum HostResolver {
	static func resolveIPv4(host: String, port: UInt16) -> [PeerAddress] {
		var hints = addrinfo(
			ai_flags: 0,
			ai_family: AF_INET,
			ai_socktype: SOCK_DGRAM,
			ai_protocol: IPPROTO_UDP,
			ai_addrlen: 0,
			ai_canonname: nil,
			ai_addr: nil,
			ai_next: nil
		)
		var result: UnsafeMutablePointer<addrinfo>?
		guard getaddrinfo(host, String(port), &hints, &result) == 0, let head = result else { return [] }
		defer { freeaddrinfo(head) }

		var addresses: [PeerAddress] = []
		var cursor: UnsafeMutablePointer<addrinfo>? = head
		while let entry = cursor {
			if let sockaddrPointer = entry.pointee.ai_addr {
				sockaddrPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
					let value = UInt32(bigEndian: pointer.pointee.sin_addr.s_addr)
					let text = "\(value >> 24 & 0xFF).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
					addresses.append(PeerAddress(host: text, port: UInt16(bigEndian: pointer.pointee.sin_port)))
				}
			}
			cursor = entry.pointee.ai_next
		}
		return addresses
	}
}
