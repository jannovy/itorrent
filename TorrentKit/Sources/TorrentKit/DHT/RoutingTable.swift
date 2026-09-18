import Foundation

/// A 160-bit Kademlia node id.
public struct NodeID: Hashable, Sendable, Comparable {
	public let raw: Data

	public init?(raw: Data) {
		guard raw.count == 20 else { return nil }
		self.raw = raw
	}

	public init(infoHash: InfoHash) {
		self.raw = infoHash.raw
	}

	public static func random() -> NodeID {
		NodeID(raw: Data((0..<20).map { _ in UInt8.random(in: 0...255) }))!
	}

	public func distance(to other: NodeID) -> Data {
		Data(zip(raw, other.raw).map(^))
	}

	/// Number of leading bits shared with `other`; this is the bucket index in
	/// the routing table.
	public func sharedPrefixLength(with other: NodeID) -> Int {
		for (offset, byte) in distance(to: other).enumerated() where byte != 0 {
			return offset * 8 + byte.leadingZeroBitCount
		}
		return 160
	}

	public static func < (lhs: NodeID, rhs: NodeID) -> Bool {
		lhs.raw.lexicographicallyPrecedes(rhs.raw)
	}

	public var hex: String { raw.hexEncodedString() }
}

public struct DHTNode: Hashable, Sendable {
	public let id: NodeID
	public var address: PeerAddress
	public var lastSeen: Date
	public var failedQueries: Int

	public init(id: NodeID, address: PeerAddress, lastSeen: Date = Date(), failedQueries: Int = 0) {
		self.id = id
		self.address = address
		self.lastSeen = lastSeen
		self.failedQueries = failedQueries
	}

	/// Kademlia calls a node "good" while it still answers; three consecutive
	/// failures is the conventional eviction threshold.
	public var isQuestionable: Bool { failedQueries > 0 }
	public var isBad: Bool { failedQueries >= 3 }

	public static func == (lhs: DHTNode, rhs: DHTNode) -> Bool { lhs.id == rhs.id }
	public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A Kademlia routing table with 160 buckets indexed by shared prefix length.
///
/// This is the flattened form of the classic split-on-demand table: bucket `i`
/// holds nodes sharing exactly `i` leading bits with us, which gives the same
/// distance distribution without the bookkeeping of splitting.
public struct RoutingTable {
	public static let bucketSize = 8

	public let localID: NodeID
	private var buckets: [[DHTNode]] = Array(repeating: [], count: 161)

	public init(localID: NodeID) {
		self.localID = localID
	}

	public var nodeCount: Int { buckets.reduce(0) { $0 + $1.count } }

	public var allNodes: [DHTNode] { buckets.flatMap { $0 } }

	@discardableResult
	public mutating func insert(_ node: DHTNode) -> Bool {
		guard node.id != localID, node.address.isRoutable else { return false }
		let index = min(160, localID.sharedPrefixLength(with: node.id))

		if let existing = buckets[index].firstIndex(where: { $0.id == node.id }) {
			buckets[index][existing].address = node.address
			buckets[index][existing].lastSeen = Date()
			buckets[index][existing].failedQueries = 0
			return true
		}

		if buckets[index].count < Self.bucketSize {
			buckets[index].append(node)
			return true
		}

		// Full bucket: evict the worst node, but only if it is actually bad.
		// Kademlia's stability guarantee comes from preferring old live nodes.
		if let worst = buckets[index].firstIndex(where: \.isBad) {
			buckets[index][worst] = node
			return true
		}
		return false
	}

	public mutating func recordSuccess(id: NodeID) {
		let index = min(160, localID.sharedPrefixLength(with: id))
		guard let position = buckets[index].firstIndex(where: { $0.id == id }) else { return }
		buckets[index][position].failedQueries = 0
		buckets[index][position].lastSeen = Date()
	}

	public mutating func recordFailure(id: NodeID) {
		let index = min(160, localID.sharedPrefixLength(with: id))
		guard let position = buckets[index].firstIndex(where: { $0.id == id }) else { return }
		buckets[index][position].failedQueries += 1
		if buckets[index][position].isBad {
			buckets[index].remove(at: position)
		}
	}

	/// The `count` nodes closest to `target` by XOR distance.
	public func closest(to target: NodeID, count: Int = RoutingTable.bucketSize) -> [DHTNode] {
		allNodes
			.filter { !$0.isBad }
			.sorted { lhs, rhs in
				lhs.id.distance(to: target).lexicographicallyPrecedes(rhs.id.distance(to: target))
			}
			.prefix(count)
			.map { $0 }
	}

	/// Compact node info (BEP 5): 20-byte id followed by a 6-byte endpoint.
	public static func encodeCompact(_ nodes: [DHTNode]) -> Data {
		var data = Data()
		for node in nodes {
			guard let endpoint = node.address.encodeCompact() else { continue }
			data.append(node.id.raw)
			data.append(endpoint)
		}
		return data
	}

	public static func decodeCompact(_ data: Data) -> [DHTNode] {
		var nodes: [DHTNode] = []
		let bytes = [UInt8](data)
		var index = 0
		while index + 26 <= bytes.count {
			guard let id = NodeID(raw: Data(bytes[index..<(index + 20)])) else { break }
			let host = bytes[(index + 20)..<(index + 24)].map(String.init).joined(separator: ".")
			let port = UInt16(bytes[index + 24]) << 8 | UInt16(bytes[index + 25])
			let address = PeerAddress(host: host, port: port)
			if address.isRoutable {
				nodes.append(DHTNode(id: id, address: address))
			}
			index += 26
		}
		return nodes
	}
}
