import Foundation

/// A µTP packet (BEP 29).
///
/// Twenty bytes of header, optionally followed by extensions, followed by the
/// payload. Every field is big-endian.
///
/// ```
///  0       4       8               16              24              32
/// +-------+-------+---------------+---------------+---------------+
/// | type  | ver   | extension     | connection_id                 |
/// +---------------+---------------+---------------+---------------+
/// | timestamp_microseconds                                        |
/// +---------------+---------------+---------------+---------------+
/// | timestamp_difference_microseconds                             |
/// +---------------+---------------+---------------+---------------+
/// | wnd_size                                                      |
/// +---------------+---------------+---------------+---------------+
/// | seq_nr                        | ack_nr                        |
/// +---------------+---------------+---------------+---------------+
/// ```
struct UTPPacket: Equatable {

	enum Kind: UInt8 {
		/// Payload.
		case data = 0
		/// The sender is done sending; numbered like data.
		case fin = 1
		/// An acknowledgement carrying no payload and consuming no sequence
		/// number.
		case state = 2
		/// Tear the connection down now.
		case reset = 3
		/// Open a connection.
		case syn = 4
	}

	static let headerLength = 20
	static let version: UInt8 = 1
	/// The extension id for selective acknowledgements.
	static let selectiveAckExtension: UInt8 = 1

	var kind: Kind
	var connectionID: UInt16
	/// Our clock, in microseconds, when the packet was put on the wire.
	var timestamp: UInt32
	/// What we last measured of the *peer's* one-way delay to us. This is the
	/// number LEDBAT runs on: the peer reads its own delay out of our packets.
	var timestampDifference: UInt32
	/// Free space in our receive buffer.
	var windowSize: UInt32
	var sequenceNumber: UInt16
	var acknowledgementNumber: UInt16
	/// Bitmask of packets received out of order, starting at `ack_nr + 2`.
	var selectiveAck: Data?
	var payload: Data

	init(
		kind: Kind,
		connectionID: UInt16,
		timestamp: UInt32 = 0,
		timestampDifference: UInt32 = 0,
		windowSize: UInt32 = 0,
		sequenceNumber: UInt16 = 0,
		acknowledgementNumber: UInt16 = 0,
		selectiveAck: Data? = nil,
		payload: Data = Data()
	) {
		self.kind = kind
		self.connectionID = connectionID
		self.timestamp = timestamp
		self.timestampDifference = timestampDifference
		self.windowSize = windowSize
		self.sequenceNumber = sequenceNumber
		self.acknowledgementNumber = acknowledgementNumber
		self.selectiveAck = selectiveAck
		self.payload = payload
	}

	func encoded() -> Data {
		var data = Data()
		data.append(kind.rawValue << 4 | Self.version)
		data.append(selectiveAck == nil ? 0 : Self.selectiveAckExtension)
		data.appendBigEndian(connectionID)
		data.appendBigEndian(timestamp)
		data.appendBigEndian(timestampDifference)
		data.appendBigEndian(windowSize)
		data.appendBigEndian(sequenceNumber)
		data.appendBigEndian(acknowledgementNumber)

		if let selectiveAck {
			// No further extensions, then the length, then the bitmask.
			data.append(0)
			data.append(UInt8(selectiveAck.count))
			data.append(selectiveAck)
		}
		data.append(payload)
		return data
	}

	init?(data: Data) {
		guard data.count >= Self.headerLength else { return nil }
		let base = data.startIndex

		let typeAndVersion = data[base]
		guard typeAndVersion & 0x0F == Self.version,
		      let kind = Kind(rawValue: typeAndVersion >> 4)
		else { return nil }

		self.kind = kind
		self.connectionID = data.bigEndianUInt16(at: 2)!
		self.timestamp = data.bigEndianUInt32(at: 4)!
		self.timestampDifference = data.bigEndianUInt32(at: 8)!
		self.windowSize = data.bigEndianUInt32(at: 12)!
		self.sequenceNumber = data.bigEndianUInt16(at: 16)!
		self.acknowledgementNumber = data.bigEndianUInt16(at: 18)!
		self.selectiveAck = nil

		// Walk the extension chain. Unknown extensions are skipped rather than
		// rejected: that is what the field is for.
		var nextExtension = data[base + 1]
		var offset = Self.headerLength
		while nextExtension != 0 {
			guard offset + 2 <= data.count else { return nil }
			let following = data[base + offset]
			let length = Int(data[base + offset + 1])
			guard offset + 2 + length <= data.count else { return nil }

			if nextExtension == Self.selectiveAckExtension {
				selectiveAck = data.subdata(in: (base + offset + 2)..<(base + offset + 2 + length))
			}
			nextExtension = following
			offset += 2 + length
		}

		self.payload = offset < data.count ? data.subdata(in: (base + offset)..<data.endIndex) : Data()
	}
}

/// Sequence numbers wrap at 16 bits, so they are compared by the sign of the
/// difference rather than by value: 65535 comes *before* 0, not after it.
@inline(__always)
func utpSequence(_ lhs: UInt16, isLessThan rhs: UInt16) -> Bool {
	Int16(bitPattern: lhs &- rhs) < 0
}

@inline(__always)
func utpSequence(_ lhs: UInt16, isAtOrBefore rhs: UInt16) -> Bool {
	Int16(bitPattern: lhs &- rhs) <= 0
}

/// Microseconds from a monotonic clock, truncated to the 32 bits the header
/// carries. Wall-clock time would jump when the phone corrects its clock.
@inline(__always)
func utpNowMicroseconds() -> UInt32 {
	UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1000)
}
