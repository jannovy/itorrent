import Foundation

public enum PiecePriority: Int, Sendable, Comparable, Codable {
	case skip = 0
	case low = 1
	case normal = 2
	case high = 3

	public static func < (lhs: PiecePriority, rhs: PiecePriority) -> Bool {
		lhs.rawValue < rhs.rawValue
	}
}

/// Decides which blocks to ask which peer for, and reassembles pieces.
///
/// Strategy: rarest-first once the download is under way, but the first few
/// pieces are picked at random. Rarest-first at startup makes every client in
/// a fresh swarm converge on the same piece, which starves the swarm of
/// anything to trade.
public final class PiecePicker {
	public enum BlockOutcome {
		/// Not part of any piece we are working on, or already held.
		case ignored
		case accepted
		/// The piece is fully assembled and awaiting hash verification.
		case pieceReady(index: Int, data: Data)
	}

	private struct PartialPiece {
		let index: Int
		var data: Data
		var receivedBlocks: BitField
		var requestedBlocks: Set<Int> = []
		var lastProgress = Date()
		/// Who supplied each block. A piece that fails its hash check was
		/// corrupted by one of these peers, and with a single contributor there
		/// is no doubt at all about which one.
		var blockContributors: [Int: ObjectIdentifier] = [:]

		var isComplete: Bool { receivedBlocks.isComplete }
	}

	private struct InFlight {
		let peer: ObjectIdentifier
		let sentAt: Date
	}

	/// Random-piece phase length; four pieces is enough to have something to
	/// trade before switching to rarest-first.
	private static let randomPieceThreshold = 4
	/// Bounds memory: each partial piece holds a full piece in RAM.
	private static let maximumPartialPieces = 16
	private static let endgameRemainingPieces = 8

	private let pieceCount: Int
	private let pieceLength: Int
	private let totalLength: Int64

	public private(set) var have: BitField
	public private(set) var priorities: [PiecePriority]
	private var availability: [Int]
	private var partials: [Int: PartialPiece] = [:]
	private var inFlight: [BlockRequest: InFlight] = [:]
	private var failedHashChecks: [Int: Int] = [:]
	/// Pieces a web seed has taken on. They are fetched whole and out of band,
	/// so peers must not start them as well.
	private var reservedForWebSeeds: Set<Int> = []

	public init(metainfo: TorrentMetainfo, have: BitField? = nil) {
		self.pieceCount = metainfo.pieceCount
		self.pieceLength = metainfo.pieceLength
		self.totalLength = metainfo.totalLength
		self.have = have ?? BitField(bitCount: metainfo.pieceCount)
		self.priorities = Array(repeating: .normal, count: metainfo.pieceCount)
		self.availability = Array(repeating: 0, count: metainfo.pieceCount)
		recomputeTotals()
	}

	// MARK: - Progress

	public var completedPieces: Int { have.setBitCount }

	/// A torrent with skipped files is complete once every *wanted* piece is in.
	public var isComplete: Bool { remainingBytesValue == 0 && wantedBytesValue > 0 }

	public private(set) var downloadedBytes: Int64 = 0
	public var wantedBytes: Int64 { wantedBytesValue }
	public var remainingBytes: Int64 { remainingBytesValue }

	/// Maintained incrementally rather than recomputed. These are read on every
	/// UI refresh, and walking tens of thousands of pieces each time showed up
	/// as real contention on the torrent actor during fast downloads.
	private var wantedBytesValue: Int64 = 0
	private var remainingBytesValue: Int64 = 0

	private func recomputeTotals() {
		var wanted: Int64 = 0
		var remaining: Int64 = 0
		var downloaded: Int64 = 0
		for index in 0..<pieceCount {
			let size = Int64(size(ofPiece: index))
			if have[index] { downloaded += size }
			guard priorities[index] != .skip else { continue }
			wanted += size
			if !have[index] { remaining += size }
		}
		wantedBytesValue = wanted
		remainingBytesValue = remaining
		downloadedBytes = downloaded
	}

	private func wantedPieceIndices() -> [Int] {
		(0..<pieceCount).filter { priorities[$0] != .skip }
	}

	public func size(ofPiece index: Int) -> Int {
		guard index == pieceCount - 1 else { return pieceLength }
		let remainder = Int(totalLength % Int64(pieceLength))
		return remainder == 0 ? pieceLength : remainder
	}

	private func blockCount(ofPiece index: Int) -> Int {
		(size(ofPiece: index) + BlockRequest.standardLength - 1) / BlockRequest.standardLength
	}

	private func blockLength(piece index: Int, block: Int) -> Int {
		let pieceSize = size(ofPiece: index)
		let start = block * BlockRequest.standardLength
		return min(BlockRequest.standardLength, pieceSize - start)
	}

	// MARK: - Availability

	public func addAvailability(bitfield: BitField) {
		for index in 0..<min(pieceCount, bitfield.bitCount) where bitfield[index] {
			availability[index] += 1
		}
	}

	public func removeAvailability(bitfield: BitField) {
		for index in 0..<min(pieceCount, bitfield.bitCount) where bitfield[index] {
			availability[index] = max(0, availability[index] - 1)
		}
	}

	public func addAvailability(piece index: Int) {
		guard index >= 0, index < pieceCount else { return }
		availability[index] += 1
	}

	public func availabilityCount(piece index: Int) -> Int {
		guard index >= 0, index < pieceCount else { return 0 }
		return availability[index]
	}

	/// True when the peer holds at least one piece we still want.
	public func isInteresting(peerBitfield: BitField) -> Bool {
		for index in 0..<pieceCount where !have[index] && priorities[index] != .skip && peerBitfield[index] {
			return true
		}
		return false
	}

	// MARK: - Priorities

	public func setPriorities(_ newPriorities: [PiecePriority]) {
		guard newPriorities.count == pieceCount else { return }
		priorities = newPriorities
		// Drop work on pieces that just became unwanted.
		for index in partials.keys where priorities[index] == .skip {
			discardPartial(index)
		}
		recomputeTotals()
	}

	// MARK: - Picking

	public func pick(
		for peer: ObjectIdentifier,
		peerBitfield: BitField,
		limit: Int
	) -> [BlockRequest] {
		guard limit > 0 else { return [] }
		var requests: [BlockRequest] = []
		let endgame = isEndgame

		// Finish what is already started before opening new pieces: partial
		// pieces are dead weight until they complete.
		for index in partials.keys.sorted(by: { partials[$0]!.lastProgress < partials[$1]!.lastProgress }) {
			guard peerBitfield[index], priorities[index] != .skip else { continue }
			appendRequests(for: index, peer: peer, into: &requests, limit: limit, endgame: endgame)
			if requests.count >= limit { return requests }
		}

		while requests.count < limit, partials.count < Self.maximumPartialPieces {
			guard let index = selectNewPiece(peerBitfield: peerBitfield) else { break }
			startPartial(index)
			appendRequests(for: index, peer: peer, into: &requests, limit: limit, endgame: endgame)
		}

		return requests
	}

	private var isEndgame: Bool {
		guard remainingBytesValue > 0 else { return false }
		// Cheap upper bound: only walk the piece list once the tail is close.
		guard remainingBytesValue <= Int64(Self.endgameRemainingPieces) * Int64(pieceLength) else { return false }
		let remaining = wantedPieceIndices().count { !have[$0] }
		return remaining > 0 && remaining <= Self.endgameRemainingPieces
	}

	private func appendRequests(
		for index: Int,
		peer: ObjectIdentifier,
		into requests: inout [BlockRequest],
		limit: Int,
		endgame: Bool
	) {
		guard var piece = partials[index] else { return }
		for block in 0..<blockCount(ofPiece: index) {
			guard requests.count < limit else { break }
			guard !piece.receivedBlocks[block] else { continue }

			let request = BlockRequest(
				pieceIndex: index,
				begin: block * BlockRequest.standardLength,
				length: blockLength(piece: index, block: block)
			)
			if let existing = inFlight[request] {
				// In endgame, request the last blocks from everyone and cancel
				// the losers; otherwise one slow peer stalls the whole torrent.
				guard endgame, existing.peer != peer else { continue }
			}
			inFlight[request] = InFlight(peer: peer, sentAt: Date())
			piece.requestedBlocks.insert(block)
			requests.append(request)
		}
		partials[index] = piece
	}

	private func selectNewPiece(peerBitfield: BitField) -> Int? {
		var candidates: [Int] = []
		for index in 0..<pieceCount
			where !have[index] && partials[index] == nil && priorities[index] != .skip
				&& peerBitfield[index] && !reservedForWebSeeds.contains(index) {
			candidates.append(index)
		}
		guard !candidates.isEmpty else { return nil }

		if have.setBitCount < Self.randomPieceThreshold {
			return candidates.randomElement()
		}

		let highestPriority = candidates.map { priorities[$0] }.max() ?? .normal
		let filtered = candidates.filter { priorities[$0] == highestPriority }
		// Rarest first, ties broken randomly to spread load across the swarm.
		let rarest = filtered.min { lhs, rhs in
			let lhsCount = availability[lhs]
			let rhsCount = availability[rhs]
			if lhsCount == rhsCount { return Bool.random() }
			return lhsCount < rhsCount
		}
		return rarest
	}

	private func startPartial(_ index: Int) {
		guard partials[index] == nil else { return }
		partials[index] = PartialPiece(
			index: index,
			data: Data(count: size(ofPiece: index)),
			receivedBlocks: BitField(bitCount: blockCount(ofPiece: index))
		)
	}

	private func discardPartial(_ index: Int) {
		partials[index] = nil
		for request in inFlight.keys where request.pieceIndex == index {
			inFlight[request] = nil
		}
	}

	// MARK: - Web seed reservations

	/// Claims a piece for a web seed, or returns nil when there is nothing
	/// useful left to claim.
	///
	/// Rarest first, as everywhere else, but it matters more here: a web seed
	/// always has every piece, so spending it on what the swarm is short of is
	/// the whole point. Pieces already under way with peers are left alone.
	public func reservePieceForWebSeed() -> Int? {
		var best: Int?
		var bestAvailability = Int.max
		for index in 0..<pieceCount
			where !have[index] && partials[index] == nil && priorities[index] != .skip
				&& !reservedForWebSeeds.contains(index) {
			if availability[index] < bestAvailability {
				best = index
				bestAvailability = availability[index]
			}
		}
		if let best { reservedForWebSeeds.insert(best) }
		return best
	}

	public func releaseWebSeedReservation(_ index: Int) {
		reservedForWebSeeds.remove(index)
	}

	public func isReservedForWebSeed(_ index: Int) -> Bool {
		reservedForWebSeeds.contains(index)
	}

	// MARK: - Receiving

	public func receive(pieceIndex: Int, begin: Int, block: Data, from peer: ObjectIdentifier? = nil) -> BlockOutcome {
		guard pieceIndex >= 0, pieceIndex < pieceCount, !have[pieceIndex] else { return .ignored }
		guard begin >= 0, begin % BlockRequest.standardLength == 0 else { return .ignored }

		let blockIndex = begin / BlockRequest.standardLength
		guard blockIndex < blockCount(ofPiece: pieceIndex),
		      block.count == blockLength(piece: pieceIndex, block: blockIndex)
		else { return .ignored }

		if partials[pieceIndex] == nil { startPartial(pieceIndex) }
		guard var piece = partials[pieceIndex] else { return .ignored }

		let request = BlockRequest(pieceIndex: pieceIndex, begin: begin, length: block.count)
		inFlight[request] = nil

		guard !piece.receivedBlocks[blockIndex] else { return .ignored }

		piece.data.replaceSubrange(begin..<(begin + block.count), with: block)
		piece.receivedBlocks[blockIndex] = true
		piece.requestedBlocks.remove(blockIndex)
		piece.lastProgress = Date()
		if let peer { piece.blockContributors[blockIndex] = peer }
		partials[pieceIndex] = piece

		guard piece.isComplete else { return .accepted }
		return .pieceReady(index: pieceIndex, data: piece.data)
	}

	/// Called after the SHA-1 check passes and the piece is on disk.
	public func markVerified(piece index: Int) {
		partials[index] = nil
		reservedForWebSeeds.remove(index)
		guard !have[index] else { return }
		have[index] = true
		let size = Int64(size(ofPiece: index))
		downloadedBytes += size
		if priorities[index] != .skip { remainingBytesValue -= size }
		failedHashChecks[index] = nil
		for request in inFlight.keys where request.pieceIndex == index {
			inFlight[request] = nil
		}
	}

	/// Every peer that supplied a block of a piece. Read before `markCorrupt`,
	/// which throws the partial away along with its record of who sent what.
	public func contributors(toPiece index: Int) -> Set<ObjectIdentifier> {
		guard let piece = partials[index] else { return [] }
		return Set(piece.blockContributors.values)
	}

	/// Called when the SHA-1 check fails; the piece is thrown away and refetched.
	public func markCorrupt(piece index: Int) {
		failedHashChecks[index, default: 0] += 1
		discardPartial(index)
	}


	public func failureCount(piece index: Int) -> Int {
		failedHashChecks[index] ?? 0
	}

	/// Frees every block a peer had outstanding, so they can be asked of
	/// somebody else. Called on disconnect and on choke.
	public func releaseRequests(from peer: ObjectIdentifier) {
		for (request, entry) in inFlight where entry.peer == peer {
			inFlight[request] = nil
			partials[request.pieceIndex]?.requestedBlocks.remove(request.blockIndex)
		}
	}

	/// Drops requests that a peer accepted but never answered.
	@discardableResult
	public func expireStaleRequests(olderThan interval: TimeInterval) -> [BlockRequest] {
		let cutoff = Date().addingTimeInterval(-interval)
		var expired: [BlockRequest] = []
		for (request, entry) in inFlight where entry.sentAt < cutoff {
			inFlight[request] = nil
			partials[request.pieceIndex]?.requestedBlocks.remove(request.blockIndex)
			expired.append(request)
		}
		return expired
	}

	public func outstandingRequestCount(for peer: ObjectIdentifier) -> Int {
		inFlight.values.count { $0.peer == peer }
	}

	// MARK: - Resume

	public func restore(have bitfield: BitField) {
		have = bitfield
		partials.removeAll()
		inFlight.removeAll()
		reservedForWebSeeds.removeAll()
		recomputeTotals()
	}

}
