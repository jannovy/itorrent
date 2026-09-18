import CryptoKit
import Foundation

public enum DHTError: Error, LocalizedError {
	case notRunning
	case timedOut
	case remote(code: Int, message: String)
	case malformedResponse

	public var errorDescription: String? {
		switch self {
		case .notRunning: "The DHT is not running."
		case .timedOut: "The DHT node did not answer."
		case let .remote(code, message): "DHT error \(code): \(message)"
		case .malformedResponse: "Malformed DHT response."
		}
	}
}

/// A Mainline DHT node (BEP 5).
///
/// Runs both halves of the protocol: it performs iterative `get_peers` lookups
/// for our own torrents, and answers queries from other nodes so we get into
/// their routing tables — a node that only asks is quickly forgotten by the
/// network and stops receiving useful results.
public actor DHT {
	public static let bootstrapNodes: [(host: String, port: UInt16)] = [
		("router.bittorrent.com", 6881),
		("router.utorrent.com", 6881),
		("dht.transmissionbt.com", 6881),
		("dht.libtorrent.org", 25401),
	]

	private struct PendingQuery {
		let continuation: CheckedContinuation<[String: BencodeValue], Error>
		let nodeID: NodeID?
	}

	private struct StoredPeers {
		var peers: [PeerAddress: Date] = [:]
	}

	private let localID: NodeID
	private var routingTable: RoutingTable
	private var socket: DatagramSocket?
	private var pending: [Data: PendingQuery] = [:]
	private var transactionCounter: UInt16 = 0
	private var storage: [InfoHash: StoredPeers] = [:]
	private var tokenSecret = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
	private var previousTokenSecret: Data?
	private var secretRotatedAt = Date()
	private var bootstrapAddresses: [PeerAddress] = []
	private var announcedPort: UInt16 = 0

	public private(set) var isRunning = false

	public init(localID: NodeID = .random()) {
		self.localID = localID
		self.routingTable = RoutingTable(localID: localID)
	}

	public var nodeCount: Int { routingTable.nodeCount }
	public var isBootstrapped: Bool { routingTable.nodeCount >= 8 }
	public var localPort: UInt16 { socket?.localPort ?? 0 }

	// MARK: - Lifecycle

	public func start(port: UInt16, announcingPeerPort: UInt16) throws {
		guard !isRunning else { return }
		let socket = try DatagramSocket(port: port)
		socket.onDatagram = { [weak self] data, from in
			guard let self else { return }
			Task { await self.receive(data, from: from) }
		}
		self.socket = socket
		self.announcedPort = announcingPeerPort
		isRunning = true
	}

	public func stop() {
		isRunning = false
		socket?.close()
		socket = nil
		for (_, query) in pending {
			query.continuation.resume(throwing: DHTError.notRunning)
		}
		pending.removeAll()
	}

	public func setAnnouncedPeerPort(_ port: UInt16) {
		announcedPort = port
	}

	/// Nodes worth persisting between launches, so the next start skips the
	/// bootstrap round trip.
	public func exportNodes(limit: Int = 200) -> [PeerAddress] {
		routingTable.allNodes
			.filter { !$0.isBad }
			.sorted { $0.lastSeen > $1.lastSeen }
			.prefix(limit)
			.map(\.address)
	}

	public func bootstrap(savedNodes: [PeerAddress] = []) async {
		guard isRunning else { return }

		if bootstrapAddresses.isEmpty {
			bootstrapAddresses = await Self.resolveBootstrapNodes()
		}
		let seeds = savedNodes + bootstrapAddresses
		guard !seeds.isEmpty else { return }

		// Ping the seeds to learn their ids, then look ourselves up: the nodes
		// returned along the way are exactly the ones that belong in our table.
		await withTaskGroup(of: Void.self) { group in
			for address in seeds.prefix(24) {
				group.addTask { [weak self] in
					guard let self else { return }
					_ = try? await self.query(method: "find_node", arguments: [
						"id": .bytes(self.localIDRaw),
						"target": .bytes(NodeID.random().raw),
					], to: address, expectedID: nil)
				}
			}
		}
		_ = await lookup(target: localID, infoHash: nil, announce: false)
	}

	private nonisolated var localIDRaw: Data { localID.raw }

	private static func resolveBootstrapNodes() async -> [PeerAddress] {
		await withTaskGroup(of: [PeerAddress].self) { group in
			for node in bootstrapNodes {
				group.addTask {
					HostResolver.resolveIPv4(host: node.host, port: node.port)
				}
			}
			var addresses: [PeerAddress] = []
			for await resolved in group { addresses += resolved }
			return addresses
		}
	}

	// MARK: - Peer lookup

	/// Iterative `get_peers` lookup, optionally announcing ourselves as a peer
	/// at the end so other clients can find us.
	public func findPeers(infoHash: InfoHash, announce: Bool = true) async -> [PeerAddress] {
		guard isRunning else { return [] }
		return await lookup(target: NodeID(infoHash: infoHash), infoHash: infoHash, announce: announce)
	}

	private func lookup(target: NodeID, infoHash: InfoHash?, announce: Bool) async -> [PeerAddress] {
		let alpha = 3
		let maximumRounds = 10
		let deadline = Date().addingTimeInterval(45)

		var shortlist = routingTable.closest(to: target, count: 16)
		if shortlist.isEmpty {
			shortlist = bootstrapAddresses.prefix(8).map { DHTNode(id: .random(), address: $0) }
		}
		var queried: Set<PeerAddress> = []
		var tokens: [PeerAddress: Data] = [:]
		var foundPeers: Set<PeerAddress> = []
		var closestSeen = shortlist

		for _ in 0..<maximumRounds {
			guard Date() < deadline else { break }

			let batch = closestSeen
				.filter { !queried.contains($0.address) }
				.sorted { lhs, rhs in
					lhs.id.distance(to: target).lexicographicallyPrecedes(rhs.id.distance(to: target))
				}
				.prefix(alpha)
			guard !batch.isEmpty else { break }

			for node in batch { queried.insert(node.address) }

			let method = infoHash == nil ? "find_node" : "get_peers"
			var arguments: [String: BencodeValue] = ["id": .bytes(localID.raw)]
			if let infoHash {
				arguments["info_hash"] = .bytes(infoHash.raw)
			} else {
				arguments["target"] = .bytes(target.raw)
			}

			let responses = await withTaskGroup(of: (DHTNode, [String: BencodeValue]?).self) { group in
				for node in batch {
					group.addTask { [weak self] in
						guard let self else { return (node, nil) }
						let response = try? await self.query(
							method: method,
							arguments: arguments,
							to: node.address,
							expectedID: node.id
						)
						return (node, response)
					}
				}
				var collected: [(DHTNode, [String: BencodeValue]?)] = []
				for await item in group { collected.append(item) }
				return collected
			}

			var discovered: [DHTNode] = []
			for (node, response) in responses {
				guard let response else {
					routingTable.recordFailure(id: node.id)
					continue
				}
				if let token = response["token"]?.dataValue {
					tokens[node.address] = token
				}
				if let values = response["values"]?.listValue {
					for entry in values {
						guard let data = entry.dataValue else { continue }
						foundPeers.formUnion(PeerAddress.decodeCompact(data, isIPv6: false))
					}
				}
				if let nodes = response["nodes"]?.dataValue {
					discovered += RoutingTable.decodeCompact(nodes)
				}
			}

			for node in discovered {
				routingTable.insert(node)
				if !closestSeen.contains(where: { $0.id == node.id }) {
					closestSeen.append(node)
				}
			}

			// Keep the shortlist bounded to the best candidates seen so far.
			closestSeen = closestSeen
				.sorted { lhs, rhs in
					lhs.id.distance(to: target).lexicographicallyPrecedes(rhs.id.distance(to: target))
				}
				.prefix(16)
				.map { $0 }

			if discovered.isEmpty, !foundPeers.isEmpty { break }
		}

		if announce, let infoHash, announcedPort > 0 {
			await announceSelf(infoHash: infoHash, tokens: tokens, candidates: closestSeen)
		}

		return Array(foundPeers).filter(\.isRoutable)
	}

	private func announceSelf(infoHash: InfoHash, tokens: [PeerAddress: Data], candidates: [DHTNode]) async {
		let port = announcedPort
		let identity = localID.raw
		let targets = candidates.prefix(8).compactMap { node -> (DHTNode, Data)? in
			guard let token = tokens[node.address] else { return nil }
			return (node, token)
		}
		await withTaskGroup(of: Void.self) { group in
			for (node, token) in targets {
				group.addTask { [weak self] in
					guard let self else { return }
					_ = try? await self.query(method: "announce_peer", arguments: [
						"id": .bytes(identity),
						"info_hash": .bytes(infoHash.raw),
						// implied_port tells the receiving node to use the
						// source port of this datagram, which is what works
						// behind NAT; we send the literal port as a fallback.
						"implied_port": .integer(0),
						"port": .integer(Int(port)),
						"token": .bytes(token),
					], to: node.address, expectedID: node.id)
				}
			}
		}
	}

	// MARK: - Query plumbing

	@discardableResult
	private func query(
		method: String,
		arguments: [String: BencodeValue],
		to address: PeerAddress,
		expectedID: NodeID?,
		timeout: TimeInterval = 6
	) async throws -> [String: BencodeValue] {
		guard let socket, isRunning else { throw DHTError.notRunning }

		transactionCounter &+= 1
		let transaction = Data([UInt8(transactionCounter >> 8), UInt8(transactionCounter & 0xFF)])

		let message = Bencode.encode(.dictionary([
			"t": .bytes(transaction),
			"y": .bytes(Data("q".utf8)),
			"q": .bytes(Data(method.utf8)),
			"a": .dictionary(arguments),
		]))

		let timeoutTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
			await self?.expire(transaction: transaction)
		}
		defer { timeoutTask.cancel() }

		return try await withCheckedThrowingContinuation { continuation in
			pending[transaction] = PendingQuery(continuation: continuation, nodeID: expectedID)
			socket.send(message, to: address)
		}
	}

	private func expire(transaction: Data) {
		guard let query = pending.removeValue(forKey: transaction) else { return }
		if let nodeID = query.nodeID { routingTable.recordFailure(id: nodeID) }
		query.continuation.resume(throwing: DHTError.timedOut)
	}

	// MARK: - Incoming messages

	private func receive(_ data: Data, from address: PeerAddress) {
		guard let root = try? Bencode.decode(data).dictionaryValue,
		      let transaction = root["t"]?.dataValue,
		      let type = root["y"]?.stringValue
		else { return }

		switch type {
		case "r":
			guard let response = root["r"]?.dictionaryValue else { return }
			if let idData = response["id"]?.dataValue, let id = NodeID(raw: idData) {
				routingTable.insert(DHTNode(id: id, address: address))
				routingTable.recordSuccess(id: id)
			}
			pending.removeValue(forKey: transaction)?.continuation.resume(returning: response)

		case "e":
			let details = root["e"]?.listValue ?? []
			let code = details.first?.integerValue ?? 0
			let message = details.count > 1 ? (details[1].stringValue ?? "") : ""
			pending.removeValue(forKey: transaction)?
				.continuation.resume(throwing: DHTError.remote(code: code, message: message))

		case "q":
			answer(query: root, transaction: transaction, from: address)

		default:
			break
		}
	}

	private func answer(query root: [String: BencodeValue], transaction: Data, from address: PeerAddress) {
		guard let socket,
		      let method = root["q"]?.stringValue,
		      let arguments = root["a"]?.dictionaryValue,
		      let senderIDData = arguments["id"]?.dataValue,
		      let senderID = NodeID(raw: senderIDData)
		else { return }

		routingTable.insert(DHTNode(id: senderID, address: address))
		rotateTokenSecretIfNeeded()

		var response: [String: BencodeValue] = ["id": .bytes(localID.raw)]

		switch method {
		case "ping":
			break

		case "find_node":
			guard let targetData = arguments["target"]?.dataValue, let target = NodeID(raw: targetData) else { return }
			response["nodes"] = .bytes(RoutingTable.encodeCompact(routingTable.closest(to: target)))

		case "get_peers":
			guard let hashData = arguments["info_hash"]?.dataValue, let infoHash = InfoHash(raw: hashData) else { return }
			response["token"] = .bytes(token(for: address))
			let stored = prunedPeers(for: infoHash)
			if stored.isEmpty {
				response["nodes"] = .bytes(RoutingTable.encodeCompact(routingTable.closest(to: NodeID(infoHash: infoHash))))
			} else {
				response["values"] = .list(stored.prefix(50).compactMap { peer in
					peer.encodeCompact().map { BencodeValue.bytes($0) }
				})
			}

		case "announce_peer":
			guard let hashData = arguments["info_hash"]?.dataValue,
			      let infoHash = InfoHash(raw: hashData),
			      let providedToken = arguments["token"]?.dataValue,
			      isValidToken(providedToken, for: address)
			else {
				sendError(code: 203, message: "Bad token", transaction: transaction, to: address)
				return
			}
			let impliedPort = (arguments["implied_port"]?.integerValue ?? 0) != 0
			let port = impliedPort ? address.port : UInt16(arguments["port"]?.integerValue ?? 0)
			if port > 0 {
				store(peer: PeerAddress(host: address.host, port: port), for: infoHash)
			}

		default:
			sendError(code: 204, message: "Method unknown", transaction: transaction, to: address)
			return
		}

		let reply = Bencode.encode(.dictionary([
			"t": .bytes(transaction),
			"y": .bytes(Data("r".utf8)),
			"r": .dictionary(response),
		]))
		socket.send(reply, to: address)
	}

	private func sendError(code: Int, message: String, transaction: Data, to address: PeerAddress) {
		guard let socket else { return }
		let reply = Bencode.encode(.dictionary([
			"t": .bytes(transaction),
			"y": .bytes(Data("e".utf8)),
			"e": .list([.integer(code), .bytes(Data(message.utf8))]),
		]))
		socket.send(reply, to: address)
	}

	// MARK: - Tokens and peer storage

	private func rotateTokenSecretIfNeeded() {
		guard Date().timeIntervalSince(secretRotatedAt) > 300 else { return }
		previousTokenSecret = tokenSecret
		tokenSecret = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
		secretRotatedAt = Date()
	}

	private func token(for address: PeerAddress, secret: Data? = nil) -> Data {
		var input = Data(address.host.utf8)
		input.append(secret ?? tokenSecret)
		return Data(Insecure.SHA1.hash(data: input).prefix(8))
	}

	private func isValidToken(_ candidate: Data, for address: PeerAddress) -> Bool {
		if candidate == token(for: address) { return true }
		if let previousTokenSecret { return candidate == token(for: address, secret: previousTokenSecret) }
		return false
	}

	private func store(peer: PeerAddress, for infoHash: InfoHash) {
		// Cap the table: this is a phone, not an infrastructure node.
		guard storage.count < 256 || storage[infoHash] != nil else { return }
		var entry = storage[infoHash] ?? StoredPeers()
		entry.peers[peer] = Date()
		if entry.peers.count > 100 {
			let oldest = entry.peers.sorted { $0.value < $1.value }.prefix(entry.peers.count - 100)
			for (key, _) in oldest { entry.peers[key] = nil }
		}
		storage[infoHash] = entry
	}

	private func prunedPeers(for infoHash: InfoHash) -> [PeerAddress] {
		guard var entry = storage[infoHash] else { return [] }
		let cutoff = Date().addingTimeInterval(-1800)
		entry.peers = entry.peers.filter { $0.value > cutoff }
		storage[infoHash] = entry.peers.isEmpty ? nil : entry
		return Array(entry.peers.keys)
	}
}
