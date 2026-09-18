import Foundation
import Network

/// An IP endpoint of a remote peer.
public struct PeerAddress: Hashable, Sendable, CustomStringConvertible {
	public let host: String
	public let port: UInt16

	public init(host: String, port: UInt16) {
		self.host = host
		self.port = port
	}

	public init?(hostPortString: String) {
		// IPv6 literals are bracketed: [::1]:6881
		if hostPortString.hasPrefix("["), let closing = hostPortString.firstIndex(of: "]") {
			let host = String(hostPortString[hostPortString.index(after: hostPortString.startIndex)..<closing])
			let rest = hostPortString[hostPortString.index(after: closing)...]
			guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) else { return nil }
			self.init(host: host, port: port)
			return
		}
		let parts = hostPortString.split(separator: ":")
		guard parts.count == 2, let port = UInt16(parts[1]), !parts[0].isEmpty else { return nil }
		self.init(host: String(parts[0]), port: port)
	}

	public var description: String {
		host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
	}

	public var isIPv6: Bool { host.contains(":") }

	public var endpoint: NWEndpoint {
		NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 6881)
	}

	/// Filters out addresses that can never be a peer: the unspecified address
	/// and port zero.
	///
	/// Loopback is deliberately allowed. Connecting to ourselves is caught by
	/// the peer-id check in the handshake, and excluding loopback here would
	/// also rule out same-device testing and local peer discovery.
	public var isRoutable: Bool {
		guard port > 0 else { return false }
		return !host.isEmpty && host != "0.0.0.0" && host != "::"
	}
}

public extension PeerAddress {
	/// Decodes BEP 23 compact peer lists: 6 bytes per IPv4 peer, 18 per IPv6.
	static func decodeCompact(_ data: Data, isIPv6: Bool = false) -> [PeerAddress] {
		let stride = isIPv6 ? 18 : 6
		guard data.count >= stride else { return [] }
		var peers: [PeerAddress] = []
		let bytes = [UInt8](data)
		var index = 0
		while index + stride <= bytes.count {
			let addressBytes = Array(bytes[index..<(index + stride - 2)])
			let port = UInt16(bytes[index + stride - 2]) << 8 | UInt16(bytes[index + stride - 1])
			let host = isIPv6 ? formatIPv6(addressBytes) : addressBytes.map(String.init).joined(separator: ".")
			let peer = PeerAddress(host: host, port: port)
			if peer.isRoutable { peers.append(peer) }
			index += stride
		}
		return peers
	}

	func encodeCompact() -> Data? {
		guard !isIPv6 else { return nil }
		let parts = host.split(separator: ".").compactMap { UInt8($0) }
		guard parts.count == 4 else { return nil }
		return Data(parts + [UInt8(port >> 8), UInt8(port & 0xFF)])
	}

	private static func formatIPv6(_ bytes: [UInt8]) -> String {
		stride(from: 0, to: bytes.count, by: 2)
			.map { String(format: "%x", UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])) }
			.joined(separator: ":")
	}
}
