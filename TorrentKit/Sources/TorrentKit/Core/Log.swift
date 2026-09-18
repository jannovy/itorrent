import Foundation
import os

/// Structured logging for the engine.
///
/// Uses `os.Logger` so messages land in Console.app and `log stream` with no
/// runtime cost when nobody is listening. Categories match the subsystems, so a
/// stuck download can be traced without turning on everything at once:
///
/// ```
/// xcrun simctl spawn booted log stream --predicate 'subsystem == "dev.itorrent.torrentkit"'
/// ```
public enum Log {
	public static let subsystem = "dev.itorrent.torrentkit"

	public static let session = Logger(subsystem: subsystem, category: "session")
	public static let torrent = Logger(subsystem: subsystem, category: "torrent")
	public static let peer = Logger(subsystem: subsystem, category: "peer")
	public static let tracker = Logger(subsystem: subsystem, category: "tracker")
	public static let dht = Logger(subsystem: subsystem, category: "dht")
	public static let storage = Logger(subsystem: subsystem, category: "storage")
}
