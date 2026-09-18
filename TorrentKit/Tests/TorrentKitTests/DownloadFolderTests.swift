import Foundation
import Testing
@testable import TorrentKit

@Suite("Download folder", .timeLimit(.minutes(1)))
struct DownloadFolderTests {

	private func makeSession() async -> TorrentSession {
		let session = TorrentSession(
			store: SessionStore(rootURL: Fixtures.temporaryDirectory()),
			downloadDirectory: Fixtures.temporaryDirectory()
		)
		var settings = SessionSettings.default
		settings.isDHTEnabled = false
		settings.isPeerExchangeEnabled = false
		settings.areWebSeedsEnabled = false
		settings.isUTPEnabled = false
		settings.startTorrentsPaused = true
		await session.update(settings: settings)
		await session.start()
		return session
	}

	@Test("Torrents added afterwards are saved in the chosen folder")
	func newTorrentsUseTheChosenFolder() async throws {
		let session = await makeSession()
		defer { Task { await session.stop() } }

		let chosen = Fixtures.temporaryDirectory().appendingPathComponent("Elsewhere", isDirectory: true)
		try await session.setDownloadDirectory(chosen)
		#expect(await session.downloadFolder == chosen)

		let payload = Fixtures.payload(byteCount: 32_768)
		let (metainfo, _) = Fixtures.singleFileTorrent(payload: payload, pieceLength: 16_384)
		let infoHash = try await session.add(source: .metainfo(metainfo))

		let snapshot = await session.allSnapshots().first { $0.infoHash == infoHash }
		#expect(snapshot?.savePath == chosen.path)
	}

	@Test("Torrents added before the change keep the folder they were added with")
	func existingTorrentsKeepTheirFolder() async throws {
		let session = await makeSession()
		defer { Task { await session.stop() } }

		let original = await session.downloadFolder
		let payload = Fixtures.payload(byteCount: 32_768)
		let (metainfo, _) = Fixtures.singleFileTorrent(payload: payload, pieceLength: 16_384)
		let infoHash = try await session.add(source: .metainfo(metainfo))

		try await session.setDownloadDirectory(
			Fixtures.temporaryDirectory().appendingPathComponent("Elsewhere", isDirectory: true)
		)

		// Moving gigabytes because a preference changed is not something to do
		// behind the user's back, so the torrent stays where its data already is.
		let snapshot = await session.allSnapshots().first { $0.infoHash == infoHash }
		#expect(snapshot?.savePath == original.path)
	}

	@Test("The folder is created if it does not exist yet")
	func createsTheFolder() async throws {
		let session = await makeSession()
		defer { Task { await session.stop() } }

		let chosen = Fixtures.temporaryDirectory()
			.appendingPathComponent("One", isDirectory: true)
			.appendingPathComponent("Two", isDirectory: true)
		try await session.setDownloadDirectory(chosen)

		var isDirectory: ObjCBool = false
		#expect(FileManager.default.fileExists(atPath: chosen.path, isDirectory: &isDirectory))
		#expect(isDirectory.boolValue)
	}

	@Test("A folder that cannot be written to is refused, not accepted and failed later")
	func refusesAnUnwritableFolder() async throws {
		let session = await makeSession()
		defer { Task { await session.stop() } }

		let before = await session.downloadFolder
		await #expect(throws: SessionError.self) {
			try await session.setDownloadDirectory(URL(fileURLWithPath: "/System/iTorrentDownloads"))
		}
		// The old folder is still in force; a refused change must not leave the
		// session pointing somewhere it cannot write.
		#expect(await session.downloadFolder == before)
	}

	@Test("The write probe leaves nothing behind")
	func leavesNoProbeFile() async throws {
		let session = await makeSession()
		defer { Task { await session.stop() } }

		let chosen = Fixtures.temporaryDirectory().appendingPathComponent("Clean", isDirectory: true)
		try await session.setDownloadDirectory(chosen)

		let contents = try FileManager.default.contentsOfDirectory(atPath: chosen.path)
		#expect(contents.isEmpty, "found \(contents)")
	}
}
