import Foundation

/// BEP 3 HTTP tracker, with BEP 23 compact peer lists.
public struct HTTPTracker: TrackerClient {
	public let url: String

	private static let session: URLSession = {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = 25
		configuration.timeoutIntervalForResource = 30
		configuration.httpShouldSetCookies = false
		configuration.waitsForConnectivity = false
		return URLSession(configuration: configuration)
	}()

	public init(url: String) {
		self.url = url
	}

	public func announce(_ request: AnnounceRequest) async throws -> AnnounceResponse {
		guard let requestURL = URL(string: try buildQueryString(request)) else {
			throw TrackerError.invalidURL(url)
		}

		var urlRequest = URLRequest(url: requestURL)
		urlRequest.setValue("iTorrent+/1.0", forHTTPHeaderField: "User-Agent")
		urlRequest.setValue("*/*", forHTTPHeaderField: "Accept")

		let (data, response) = try await Self.session.data(for: urlRequest)
		if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
			throw TrackerError.httpStatus(http.statusCode)
		}
		return try Self.parse(data)
	}

	private func buildQueryString(_ request: AnnounceRequest) throws -> String {
		// Built by hand because info_hash and peer_id are raw binary, which
		// URLComponents refuses to encode.
		var parameters = [
			"info_hash=\(request.infoHash.urlEncoded)",
			"peer_id=\(request.peerID.urlEncoded)",
			"port=\(request.port)",
			"uploaded=\(request.uploaded)",
			"downloaded=\(request.downloaded)",
			"left=\(request.left)",
			"numwant=\(request.numberWanted)",
			"key=\(request.key)",
			"compact=1",
			"supportcrypto=\(request.supportsEncryption ? 1 : 0)",
		]
		if request.event != .periodic {
			parameters.append("event=\(request.event.rawValue)")
		}
		let separator = url.contains("?") ? "&" : "?"
		return url + separator + parameters.joined(separator: "&")
	}

	static func parse(_ data: Data) throws -> AnnounceResponse {
		guard let root = try? Bencode.decode(data).dictionaryValue else {
			throw TrackerError.malformedResponse
		}
		if let failure = root["failure reason"]?.stringValue {
			throw TrackerError.rejected(failure)
		}

		var peers: [PeerAddress] = []
		// Compact form (a byte blob) is the norm; the dictionary form still
		// turns up on older private trackers.
		if let compact = root["peers"]?.dataValue {
			peers += PeerAddress.decodeCompact(compact, isIPv6: false)
		} else if let list = root["peers"]?.listValue {
			for entry in list {
				guard let host = entry["ip"]?.stringValue,
				      let port = entry["port"]?.integerValue,
				      port > 0, port <= 65535
				else { continue }
				let peer = PeerAddress(host: host, port: UInt16(port))
				if peer.isRoutable { peers.append(peer) }
			}
		}
		if let compact6 = root["peers6"]?.dataValue {
			peers += PeerAddress.decodeCompact(compact6, isIPv6: true)
		}

		let interval = TimeInterval(root["interval"]?.integerValue ?? 1800)
		return AnnounceResponse(
			interval: max(60, interval),
			minimumInterval: root["min interval"]?.integerValue.map(TimeInterval.init),
			seeders: root["complete"]?.integerValue,
			leechers: root["incomplete"]?.integerValue,
			peers: peers,
			warning: root["warning message"]?.stringValue,
			trackerID: root["tracker id"]?.stringValue
		)
	}
}
