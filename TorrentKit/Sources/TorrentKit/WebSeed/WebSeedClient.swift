import Foundation

public enum WebSeedError: Error, LocalizedError {
	case invalidURL(String)
	case httpStatus(Int)
	/// The server ignored `Range:` and sent the whole file instead.
	case rangeNotHonoured
	case shortRead(expected: Int, got: Int)

	public var errorDescription: String? {
		switch self {
		case let .invalidURL(url): "'\(url)' is not a usable web seed URL."
		case let .httpStatus(code): "The web seed answered with HTTP \(code)."
		case .rangeNotHonoured: "The web seed ignored the requested byte range."
		case let .shortRead(expected, got): "Expected \(expected) bytes but received \(got)."
		}
	}
}

/// BEP 19 web seeding: fetches pieces over HTTP with `Range` requests.
///
/// A web seed is a plain HTTP server holding the torrent's files, so a torrent
/// whose swarm has gone quiet still downloads at full speed. One piece can
/// straddle several files and therefore several URLs, which is why a piece is
/// assembled here rather than mapping one request to one piece.
public struct WebSeedClient: Sendable {
	/// The URL as it appears in `url-list`, before the file path is appended.
	public let baseURL: String
	private let metainfo: TorrentMetainfo

	private static let session: URLSession = {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = 30
		configuration.timeoutIntervalForResource = 120
		configuration.httpShouldSetCookies = false
		configuration.waitsForConnectivity = false
		// One connection per seed keeps range requests in order and stops a
		// phone from opening six sockets to the same host for one torrent.
		configuration.httpMaximumConnectionsPerHost = 2
		return URLSession(configuration: configuration)
	}()

	public init(baseURL: String, metainfo: TorrentMetainfo) {
		self.baseURL = baseURL
		self.metainfo = metainfo
	}

	/// Builds the URL for one file inside the torrent.
	///
	/// BEP 19: a URL ending in a slash has the torrent's name appended, and for
	/// a multi-file torrent the file's path inside the torrent follows. A URL
	/// that does not end in a slash *is* the file, which only makes sense for a
	/// single-file torrent.
	public func url(for file: TorrentFile) -> URL? {
		var text = baseURL
		if metainfo.isMultiFile {
			if !text.hasSuffix("/") { text += "/" }
			text += Self.encode(metainfo.name) + "/"
			text += file.path.map(Self.encode).joined(separator: "/")
		} else if text.hasSuffix("/") {
			text += Self.encode(metainfo.name)
		}
		return URL(string: text)
	}

	/// Downloads one complete piece, reassembling it across file boundaries.
	///
	/// Padding files (BEP 47) are not on the server and are left as the zeroes
	/// they are defined to be, which is exactly what the piece hash covers.
	public func fetch(piece index: Int) async throws -> Data {
		let range = metainfo.byteRange(ofPiece: index)
		var piece = Data(count: Int(range.upperBound - range.lowerBound))

		for segment in metainfo.segments(forByteRange: range) {
			guard !segment.file.isPadding else { continue }
			guard let url = url(for: segment.file) else {
				throw WebSeedError.invalidURL(baseURL)
			}
			let chunk = try await fetch(url: url, byteRange: segment.insideFile)
			piece.replaceSubrange(segment.insideBuffer, with: chunk)
		}
		return piece
	}

	private func fetch(url: URL, byteRange: Range<Int64>) async throws -> Data {
		let expected = Int(byteRange.upperBound - byteRange.lowerBound)
		var request = URLRequest(url: url)
		request.setValue("iTorrent/1.0", forHTTPHeaderField: "User-Agent")
		request.setValue(
			"bytes=\(byteRange.lowerBound)-\(byteRange.upperBound - 1)",
			forHTTPHeaderField: "Range"
		)

		let (data, response) = try await Self.session.data(for: request)
		if let http = response as? HTTPURLResponse {
			guard (200...299).contains(http.statusCode) else {
				throw WebSeedError.httpStatus(http.statusCode)
			}
			// 200 means the server sent the whole file. Slicing it would work
			// but invites downloading gigabytes to keep sixteen kilobytes, so
			// it counts as a failure unless the file happens to be the range.
			if http.statusCode == 200, data.count != expected {
				throw WebSeedError.rangeNotHonoured
			}
		}
		guard data.count == expected else {
			throw WebSeedError.shortRead(expected: expected, got: data.count)
		}
		return data
	}

	/// Percent-encodes one path component. Spaces and non-ASCII names are
	/// common in torrents and a raw URL string would simply fail to parse.
	private static func encode(_ component: String) -> String {
		component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
	}
}
