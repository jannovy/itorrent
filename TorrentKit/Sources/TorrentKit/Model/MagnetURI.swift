import Foundation

/// A parsed `magnet:` link. Only BitTorrent v1 (`urn:btih:`) is supported;
/// v2-only links are rejected rather than silently producing a torrent that can
/// never resolve.
public struct MagnetURI: Sendable, Equatable {
	public let infoHash: InfoHash
	public let displayName: String?
	public let trackers: [String]
	/// `x.pe` peer hints let a download start before any tracker replies.
	public let peerHints: [PeerAddress]
	public let webSeeds: [String]

	public init(infoHash: InfoHash, displayName: String? = nil, trackers: [String] = [], peerHints: [PeerAddress] = [], webSeeds: [String] = []) {
		self.infoHash = infoHash
		self.displayName = displayName
		self.trackers = trackers
		self.peerHints = peerHints
		self.webSeeds = webSeeds
	}
}

public enum MagnetError: Error, LocalizedError {
	case notAMagnetLink
	case missingInfoHash
	case unsupportedHashFormat
	case version2Unsupported

	public var errorDescription: String? {
		switch self {
		case .notAMagnetLink: "That is not a magnet link."
		case .missingInfoHash: "The magnet link has no 'xt=urn:btih:' info-hash."
		case .unsupportedHashFormat: "The info-hash is neither 40-character hex nor 32-character base32."
		case .version2Unsupported: "This is a BitTorrent v2-only magnet link, which Swarm does not support yet."
		}
	}
}

public extension MagnetURI {
	init(string: String) throws {
		let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.lowercased().hasPrefix("magnet:?") else { throw MagnetError.notAMagnetLink }

		// Hand-rolled query splitting: magnet links routinely contain
		// unescaped characters that make URLComponents return nil.
		let query = String(trimmed.dropFirst("magnet:?".count))
		var parameters: [(String, String)] = []
		for pair in query.split(separator: "&") {
			let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
			guard parts.count == 2 else { continue }
			let key = String(parts[0]).lowercased()
			let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
			parameters.append((key, value))
		}

		func values(_ key: String) -> [String] {
			// Multi-value keys may be plain (`tr`) or indexed (`tr.1`).
			parameters.filter { $0.0 == key || $0.0.hasPrefix("\(key).") }.map(\.1)
		}

		var hash: InfoHash?
		var sawVersion2 = false
		for topic in values("xt") {
			let lowered = topic.lowercased()
			if lowered.hasPrefix("urn:btih:") {
				let raw = String(topic.dropFirst("urn:btih:".count))
				if raw.count == 40, let parsed = InfoHash(hex: raw) {
					hash = parsed
				} else if raw.count == 32, let parsed = InfoHash(base32: raw) {
					hash = parsed
				} else {
					throw MagnetError.unsupportedHashFormat
				}
			} else if lowered.hasPrefix("urn:btmh:") {
				sawVersion2 = true
			}
		}

		guard let infoHash = hash else {
			throw sawVersion2 ? MagnetError.version2Unsupported : MagnetError.missingInfoHash
		}

		self.init(
			infoHash: infoHash,
			displayName: values("dn").first,
			trackers: values("tr").filter { !$0.isEmpty },
			peerHints: values("x.pe").compactMap(PeerAddress.init(hostPortString:)),
			webSeeds: values("ws")
		)
	}

	var uriString: String {
		var components = ["magnet:?xt=urn:btih:\(infoHash.hex)"]
		if let displayName, let escaped = displayName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
			components.append("dn=\(escaped)")
		}
		for tracker in trackers {
			if let escaped = tracker.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
				components.append("tr=\(escaped)")
			}
		}
		return components.joined(separator: "&")
	}
}

/// What the user handed us: a `.torrent` file or a magnet link.
public enum TorrentSource: Sendable {
	case metainfo(TorrentMetainfo)
	case magnet(MagnetURI)

	public var infoHash: InfoHash {
		switch self {
		case let .metainfo(metainfo): metainfo.infoHash
		case let .magnet(magnet): magnet.infoHash
		}
	}

	public var displayName: String {
		switch self {
		case let .metainfo(metainfo): metainfo.name
		case let .magnet(magnet): magnet.displayName ?? magnet.infoHash.abbreviated
		}
	}

	/// Accepts a magnet string, a file URL, or raw `.torrent` bytes pasted as text.
	public static func parse(_ input: String) throws -> TorrentSource {
		let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.lowercased().hasPrefix("magnet:") {
			return .magnet(try MagnetURI(string: trimmed))
		}
		if let url = URL(string: trimmed), url.isFileURL {
			return .metainfo(try TorrentMetainfo(fileContents: Data(contentsOf: url)))
		}
		throw MagnetError.notAMagnetLink
	}
}
