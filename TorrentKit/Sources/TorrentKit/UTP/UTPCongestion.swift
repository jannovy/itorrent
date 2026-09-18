import Foundation

/// LEDBAT: the congestion control that makes µTP worth having.
///
/// TCP fills every buffer between here and the peer and only backs off once
/// something is dropped, which is why a torrent at full speed makes everything
/// else on the same connection feel broken. LEDBAT instead watches the *delay*
/// a transfer is adding: it targets a fixed 100 ms of queuing and gives way as
/// soon as the queue grows beyond that, so a download yields to a video call
/// rather than the other way round.
struct LEDBAT {

	/// The queuing delay to aim for. Below it the window grows, above it the
	/// window shrinks, which is what makes the traffic lower-than-best-effort.
	static let targetMicroseconds: Double = 100_000
	/// At most one extra packet per round trip, the same ceiling TCP uses.
	static let maximumIncreasePacketsPerRTT: Double = 1
	static let minimumWindow = 1500
	static let maximumWindow = 2 * 1024 * 1024

	/// One minute of samples per bucket; the base delay is the smallest across
	/// them. A single rolling minimum would never recover from one unusually
	/// quiet moment, and a window that never forgets cannot track a route that
	/// genuinely changed.
	private static let baseDelayBuckets = 13
	private static let bucketDuration: TimeInterval = 60

	private(set) var window = 3 * 1500
	private var baseDelays: [UInt32] = []
	private var currentBucket = UInt32.max
	private var bucketStartedAt = Date()
	/// A short history, so one delayed packet does not look like congestion.
	private var recentDelays: [UInt32] = []

	init() {}

	/// The smallest delay seen lately, taken as "no queue at all".
	var baseDelay: UInt32 {
		let candidates = baseDelays + (currentBucket == .max ? [] : [currentBucket])
		return candidates.min() ?? .max
	}

	private var currentDelay: UInt32 {
		recentDelays.min() ?? .max
	}

	/// Folds in the one-way delay the peer reported, and grows or shrinks the
	/// window by how far that sits from the target.
	mutating func onAck(bytesAcked: Int, delayMicroseconds: UInt32, now: Date = Date()) {
		guard delayMicroseconds > 0 else {
			// A peer that has not measured us yet reports zero; treat it as no
			// information rather than as a delay of nothing.
			grow(bytesAcked: bytesAcked, offTarget: 1)
			return
		}

		recordDelay(delayMicroseconds, now: now)
		let base = baseDelay
		guard base != .max, currentDelay != .max else { return }

		let queuing = Double(currentDelay >= base ? currentDelay - base : 0)
		let offTarget = (Self.targetMicroseconds - queuing) / Self.targetMicroseconds
		grow(bytesAcked: bytesAcked, offTarget: max(-1, min(1, offTarget)))
	}

	private mutating func grow(bytesAcked: Int, offTarget: Double) {
		guard bytesAcked > 0 else { return }
		// Scale by how much of the window this ack covered, so a window is
		// opened by at most one packet per round trip however it is acked.
		let windowFactor = min(1, Double(bytesAcked) / Double(max(window, Self.minimumWindow)))
		let gain = Self.maximumIncreasePacketsPerRTT * Double(Self.minimumWindow) * offTarget * windowFactor
		window = max(Self.minimumWindow, min(Self.maximumWindow, window + Int(gain)))
	}

	private mutating func recordDelay(_ delay: UInt32, now: Date) {
		if now.timeIntervalSince(bucketStartedAt) >= Self.bucketDuration {
			if currentBucket != .max { baseDelays.append(currentBucket) }
			if baseDelays.count > Self.baseDelayBuckets { baseDelays.removeFirst() }
			currentBucket = .max
			bucketStartedAt = now
		}
		currentBucket = min(currentBucket, delay)

		recentDelays.append(delay)
		if recentDelays.count > 3 { recentDelays.removeFirst() }
	}

	/// A packet was lost. Halve the window, the way every congestion control
	/// since Reno has.
	mutating func onLoss() {
		window = max(Self.minimumWindow, window / 2)
	}

	/// Nothing came back at all, so the window is worth nothing: start again.
	mutating func onTimeout() {
		window = Self.minimumWindow
	}
}

/// Round-trip estimate and retransmission timeout, RFC 6298 with µTP's floor.
struct RTTEstimator {
	/// Half a second, as libutp uses. Lower would retransmit into the very
	/// queue LEDBAT is trying not to build.
	static let minimumTimeout: TimeInterval = 0.5
	static let maximumTimeout: TimeInterval = 60

	private(set) var smoothed: TimeInterval = 0
	private(set) var variation: TimeInterval = 0
	private(set) var timeout: TimeInterval = 1.0

	mutating func record(sample: TimeInterval) {
		guard sample > 0 else { return }
		if smoothed == 0 {
			smoothed = sample
			variation = sample / 2
		} else {
			variation = 0.75 * variation + 0.25 * abs(smoothed - sample)
			smoothed = 0.875 * smoothed + 0.125 * sample
		}
		timeout = min(Self.maximumTimeout, max(Self.minimumTimeout, smoothed + 4 * variation))
	}

	/// Exponential backoff after a timeout, so a black hole is not hammered.
	mutating func backOff() {
		timeout = min(Self.maximumTimeout, timeout * 2)
	}
}
