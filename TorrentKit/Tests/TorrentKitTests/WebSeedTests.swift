import Foundation
import Network
import Testing
@testable import TorrentKit

/// A minimal HTTP/1.1 server that honours `Range`, so the web seed code is
/// tested against a real socket and real headers rather than a stubbed client.
final class RangeServer: @unchecked Sendable {
	private let listener: NWListener
	private let queue = DispatchQueue(label: "itorrent.tests.rangeserver")
	private let files: [String: Data]

	private let lock = NSLock()
	private var boundPort: UInt16 = 0
	private var servedRequests = 0
	/// When set, the server answers with 200 and the whole file, the way a
	/// server that does not understand ranges does.
	var ignoresRanges = false

	var port: UInt16 { lock.withLock { boundPort } }
	var requestCount: Int { lock.withLock { servedRequests } }

	/// - Parameter files: path (without the leading slash) to contents.
	init(files: [String: Data]) throws {
		self.files = files
		let parameters = NWParameters.tcp
		parameters.allowLocalEndpointReuse = true
		self.listener = try NWListener(using: parameters, on: .any)

		listener.newConnectionHandler = { [weak self] connection in
			self?.serve(connection)
		}
		listener.stateUpdateHandler = { [weak self] state in
			guard let self, case .ready = state, let assigned = self.listener.port?.rawValue else { return }
			self.lock.withLock { self.boundPort = assigned }
		}
		listener.start(queue: queue)
	}

	func waitUntilReady() async throws {
		for _ in 0..<100 {
			if port > 0 { return }
			try await Task.sleep(nanoseconds: 20_000_000)
		}
		throw WebSeedTestFailure.serverNeverStarted
	}

	func stop() {
		listener.cancel()
	}

	private func serve(_ connection: NWConnection) {
		connection.start(queue: queue)
		receive(on: connection, buffer: Data())
	}

	private func receive(on connection: NWConnection, buffer: Data) {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
			guard let self else { return }
			var buffer = buffer
			if let data { buffer.append(data) }

			guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
				if error == nil, !isComplete {
					self.receive(on: connection, buffer: buffer)
				}
				return
			}

			let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
			self.respond(to: header, on: connection)
		}
	}

	private func respond(to header: String, on connection: NWConnection) {
		lock.withLock { servedRequests += 1 }

		let lines = header.split(separator: "\r\n", omittingEmptySubsequences: false)
		guard let requestLine = lines.first else { return send(status: 400, body: Data(), on: connection) }

		let parts = requestLine.split(separator: " ")
		guard parts.count >= 2 else { return send(status: 400, body: Data(), on: connection) }

		let path = String(parts[1].dropFirst()).removingPercentEncoding ?? String(parts[1].dropFirst())
		guard let contents = files[path] else {
			return send(status: 404, body: Data(), on: connection)
		}

		let rangeHeader = lines.first { $0.lowercased().hasPrefix("range:") }
		guard !ignoresRanges, let rangeHeader else {
			return send(status: 200, body: contents, on: connection)
		}

		let spec = rangeHeader.split(separator: "=").last.map(String.init) ?? ""
		let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
		guard bounds.count == 2,
		      let start = Int(bounds[0]),
		      let end = Int(bounds[1]),
		      start <= end, end < contents.count
		else {
			return send(status: 416, body: Data(), on: connection)
		}

		let slice = contents.subdata(in: start..<(end + 1))
		send(
			status: 206,
			body: slice,
			extraHeaders: ["Content-Range": "bytes \(start)-\(end)/\(contents.count)"],
			on: connection
		)
	}

	private func send(
		status: Int,
		body: Data,
		extraHeaders: [String: String] = [:],
		on connection: NWConnection
	) {
		var header = "HTTP/1.1 \(status) \(status == 206 ? "Partial Content" : "OK")\r\n"
		header += "Content-Length: \(body.count)\r\n"
		header += "Accept-Ranges: bytes\r\n"
		header += "Connection: close\r\n"
		for (key, value) in extraHeaders {
			header += "\(key): \(value)\r\n"
		}
		header += "\r\n"

		var response = Data(header.utf8)
		response.append(body)
		connection.send(content: response, completion: .contentProcessed { _ in
			connection.cancel()
		})
	}
}

enum WebSeedTestFailure: Error {
	case serverNeverStarted
	case timedOut(String)
}

@Suite("Web seeds", .timeLimit(.minutes(2)))
struct WebSeedTests {

	@Test("A single-file URL ending in a slash gets the torrent name appended")
	func buildsSingleFileURLs() {
		let payload = Fixtures.payload(byteCount: 1024)
		let (metainfo, _) = Fixtures.singleFileTorrent(name: "sample.bin", payload: payload, pieceLength: 1024)

		let withSlash = WebSeedClient(baseURL: "http://example.test/files/", metainfo: metainfo)
		#expect(withSlash.url(for: metainfo.files[0])?.absoluteString == "http://example.test/files/sample.bin")

		// Without the trailing slash the URL is the file itself.
		let direct = WebSeedClient(baseURL: "http://example.test/mirror.bin", metainfo: metainfo)
		#expect(direct.url(for: metainfo.files[0])?.absoluteString == "http://example.test/mirror.bin")
	}

	@Test("A multi-file URL gets the torrent name and the file's path appended")
	func buildsMultiFileURLs() {
		let (metainfo, _) = Fixtures.multiFileTorrent(name: "bundle", fileSizes: [512, 512], pieceLength: 512)
		let client = WebSeedClient(baseURL: "http://example.test/pub", metainfo: metainfo)

		#expect(client.url(for: metainfo.files[0])?.absoluteString == "http://example.test/pub/bundle/dir0/file0.dat")
		#expect(client.url(for: metainfo.files[1])?.absoluteString == "http://example.test/pub/bundle/dir1/file1.dat")
	}

	@Test("Names with spaces are percent-encoded")
	func encodesAwkwardNames() {
		let payload = Fixtures.payload(byteCount: 16)
		let (metainfo, _) = Fixtures.singleFileTorrent(name: "a file.bin", payload: payload, pieceLength: 16)
		let client = WebSeedClient(baseURL: "http://example.test/d/", metainfo: metainfo)

		#expect(client.url(for: metainfo.files[0])?.absoluteString == "http://example.test/d/a%20file.bin")
	}

	@Test("Fetches one piece with a range request")
	func fetchesASinglePiece() async throws {
		let payload = Fixtures.payload(byteCount: 40_000)
		let (metainfo, _) = Fixtures.singleFileTorrent(payload: payload, pieceLength: 16_384)

		let server = try RangeServer(files: ["sample.bin": payload])
		try await server.waitUntilReady()
		defer { server.stop() }

		let client = WebSeedClient(baseURL: "http://127.0.0.1:\(server.port)/", metainfo: metainfo)
		let piece = try await client.fetch(piece: 1)

		#expect(piece == payload.subdata(in: 16_384..<32_768))
	}

	@Test("Assembles a piece that straddles two files")
	func fetchesAPieceAcrossFileBoundaries() async throws {
		// Two 24 KB files with a 32 KB piece length: piece 0 spans both.
		let (metainfo, payload) = Fixtures.multiFileTorrent(
			name: "bundle",
			fileSizes: [24_576, 24_576],
			pieceLength: 32_768
		)

		let server = try RangeServer(files: [
			"bundle/dir0/file0.dat": payload.subdata(in: 0..<24_576),
			"bundle/dir1/file1.dat": payload.subdata(in: 24_576..<49_152),
		])
		try await server.waitUntilReady()
		defer { server.stop() }

		let client = WebSeedClient(baseURL: "http://127.0.0.1:\(server.port)/", metainfo: metainfo)
		let piece = try await client.fetch(piece: 0)

		#expect(piece == payload.subdata(in: 0..<32_768))
	}

	@Test("A server that ignores Range is rejected instead of silently trusted")
	func rejectsAServerThatIgnoresRanges() async throws {
		let payload = Fixtures.payload(byteCount: 40_000)
		let (metainfo, _) = Fixtures.singleFileTorrent(payload: payload, pieceLength: 16_384)

		let server = try RangeServer(files: ["sample.bin": payload])
		server.ignoresRanges = true
		try await server.waitUntilReady()
		defer { server.stop() }

		let client = WebSeedClient(baseURL: "http://127.0.0.1:\(server.port)/", metainfo: metainfo)

		await #expect(throws: WebSeedError.self) {
			_ = try await client.fetch(piece: 0)
		}
	}

	@Test("A missing file surfaces the HTTP status")
	func reportsHTTPFailures() async throws {
		let payload = Fixtures.payload(byteCount: 16_384)
		let (metainfo, _) = Fixtures.singleFileTorrent(payload: payload, pieceLength: 16_384)

		let server = try RangeServer(files: [:])
		try await server.waitUntilReady()
		defer { server.stop() }

		let client = WebSeedClient(baseURL: "http://127.0.0.1:\(server.port)/", metainfo: metainfo)

		await #expect(throws: WebSeedError.self) {
			_ = try await client.fetch(piece: 0)
		}
	}

	@Test("A torrent with no peers at all downloads completely from a web seed")
	func downloadsAWholeTorrentFromAWebSeedAlone() async throws {
		let payload = Fixtures.payload(byteCount: 400_000)
		let (metainfo, _) = Fixtures.singleFileTorrent(payload: payload, pieceLength: 32_768)

		let server = try RangeServer(files: ["sample.bin": payload])
		try await server.waitUntilReady()
		defer { server.stop() }

		let downloadDirectory = Fixtures.temporaryDirectory()
		let session = TorrentSession(
			store: SessionStore(rootURL: Fixtures.temporaryDirectory()),
			downloadDirectory: downloadDirectory
		)
		var settings = SessionSettings.default
		settings.isDHTEnabled = false
		settings.isPeerExchangeEnabled = false
		await session.update(settings: settings)
		await session.start()
		defer { Task { await session.stop() } }

		// Rebuilt with a `url-list`, exactly as a .torrent file carrying a web
		// seed would parse.
		let seeded = try TorrentMetainfo(
			rawInfoDictionary: metainfo.rawInfoDictionary,
			webSeeds: ["http://127.0.0.1:\(server.port)/"]
		)
		let infoHash = try await session.add(source: .metainfo(seeded))

		let deadline = Date().addingTimeInterval(60)
		var snapshot: TorrentSnapshot?
		while Date() < deadline {
			snapshot = await session.allSnapshots().first { $0.infoHash == infoHash }
			if snapshot?.progress == 1 { break }
			try await Task.sleep(nanoseconds: 200_000_000)
		}

		#expect(snapshot?.progress == 1, "the torrent should complete from the web seed alone")
		#expect(snapshot?.connectedPeers == 0, "there is no swarm in this test")

		let written = try Data(contentsOf: downloadDirectory.appendingPathComponent("sample.bin"))
		#expect(written == payload, "every byte should match, verified piece by piece")
	}
}
