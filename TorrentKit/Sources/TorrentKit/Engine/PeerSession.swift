import Foundation

/// Per-peer state, owned exclusively by the `TorrentTask` actor that created it.
final class PeerSession {
	let connection: PeerConnection
	let address: PeerAddress
	let isIncoming: Bool
	let connectedAt = Date()

	var remotePeerID: Data?
	var bitfield: BitField
	var didReceiveBitfield = false

	/// Peers announce what they hold immediately after the handshake, which for
	/// a magnet download is before we know how many pieces there are. The raw
	/// announcements are kept here and replayed once the metadata arrives.
	var pendingBitfieldBytes: Data?
	var pendingHaveIndices: Set<Int> = []

	/// Wire protocol state. "We" is us, "peer" is them.
	var weAreChoking = true
	var weAreInterested = false
	var peerIsChoking = true
	var peerIsInterested = false

	var supportsExtensions = false
	var remoteExtensions: ExtensionProtocol.RemoteHandshake?

	var downloadMeter = RateMeter()
	var uploadMeter = RateMeter()
	var uploadedBytes: Int64 = 0
	var downloadedBytes: Int64 = 0

	var pendingUploads: [BlockRequest] = []
	var lastMessageAt = Date()
	var lastKeepAliveSentAt = Date()
	var metadataRequestsInFlight = 0
	var eventTask: Task<Void, Never>?

	var key: ObjectIdentifier { ObjectIdentifier(self) }

	init(connection: PeerConnection, address: PeerAddress, isIncoming: Bool, pieceCount: Int) {
		self.connection = connection
		self.address = address
		self.isIncoming = isIncoming
		self.bitfield = BitField(bitCount: pieceCount)
	}

	/// True once the peer has every piece — worth knowing because seeds are
	/// never interesting to unchoke when we are seeding too.
	var isSeed: Bool { bitfield.bitCount > 0 && bitfield.isComplete }

	var canRequest: Bool { !peerIsChoking && weAreInterested }

	/// Adaptive pipeline depth. Deep pipelines keep fast peers busy; shallow
	/// ones stop a slow peer from sitting on requests we could place elsewhere.
	var targetPipelineDepth: Int {
		let rate = downloadMeter.bytesPerSecond
		let blocksPerSecond = rate / Double(BlockRequest.standardLength)
		return Int(min(64, max(4, blocksPerSecond * 2)))
	}

	func snapshot() -> PeerSnapshot {
		PeerSnapshot(
			address: address,
			client: remotePeerID.flatMap { PeerID(raw: $0)?.clientName } ?? "unknown",
			progress: bitfield.completionFraction,
			downloadRate: downloadMeter.bytesPerSecond,
			uploadRate: uploadMeter.bytesPerSecond,
			isChokingUs: peerIsChoking,
			isInterestedInUs: peerIsInterested,
			weAreChoking: weAreChoking,
			weAreInterested: weAreInterested,
			isIncoming: isIncoming,
			supportsExtensions: supportsExtensions
		)
	}
}
