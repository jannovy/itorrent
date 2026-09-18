import Foundation
import SwiftUI
import TorrentKit

/// The bridge between the engine actor and SwiftUI.
///
/// Everything the UI reads lives here on the main actor as plain value types,
/// so views never touch the session actor directly and never block on it.
@MainActor
@Observable
final class TorrentStore {

	enum Filter: String, CaseIterable, Identifiable {
		case all = "All"
		case downloading = "Active"
		case seeding = "Seeding"
		case paused = "Paused"

		var id: String { rawValue }

		var systemImage: String {
			switch self {
			case .all: "square.stack.3d.up"
			case .downloading: "arrow.down.circle"
			case .seeding: "arrow.up.circle"
			case .paused: "pause.circle"
			}
		}
	}

	struct Message: Identifiable {
		let id = UUID()
		let title: String
		let detail: String?
		let isError: Bool
	}

	private(set) var torrents: [TorrentSnapshot] = []
	/// True while the display's auto-lock is being held off.
	private(set) var isHoldingScreenAwake = false
	private(set) var statistics = TorrentSession.Statistics()
	private(set) var isReady = false
	var settings: SessionSettings = .default
	var filter: Filter = .all
	var message: Message?
	/// Where new torrents are saved. Mirrored here so the UI can read it
	/// without awaiting the session actor on every redraw.
	private(set) var downloadFolder: URL = DownloadFolder.defaultURL
	private(set) var isUsingDefaultDownloadFolder = true

	private let session = TorrentSession()
	private var observationTask: Task<Void, Never>?
	private var statisticsTask: Task<Void, Never>?

	var filteredTorrents: [TorrentSnapshot] {
		switch filter {
		case .all:
			torrents
		case .downloading:
			torrents.filter { if case .downloading = $0.status { true } else if case .fetchingMetadata = $0.status { true } else if case .stalled = $0.status { true } else { false } }
		case .seeding:
			torrents.filter { if case .seeding = $0.status { true } else { false } }
		case .paused:
			torrents.filter { $0.status.isPaused || $0.status == .finished }
		}
	}

	func torrent(with infoHash: InfoHash) -> TorrentSnapshot? {
		torrents.first { $0.infoHash == infoHash }
	}

	// MARK: - Lifecycle

	func start() async {
		guard !isReady else { return }
		await restoreDownloadFolder()
		await session.start()
		settings = await session.currentSettings()
		isReady = true

		observationTask = Task { [session] in
			for await list in await session.snapshotStream() {
				await MainActor.run {
					self.torrents = list
					self.updateIdleTimer()
				}
			}
		}
		statisticsTask = Task { [session] in
			while !Task.isCancelled {
				let latest = await session.statistics()
				await MainActor.run { self.statistics = latest }
				try? await Task.sleep(nanoseconds: 1_000_000_000)
			}
		}
	}

	// MARK: - Download folder

	/// Reopens the folder the user chose last time, before the session starts
	/// restoring torrents into it.
	private func restoreDownloadFolder() async {
		do {
			guard let url = try DownloadFolder.restore() else { return }
			try await session.setDownloadDirectory(url)
			downloadFolder = url
			isUsingDefaultDownloadFolder = false
		} catch {
			// The folder is gone or no longer writable. Say so once and carry
			// on with the default rather than refusing to start.
			DownloadFolder.forget()
			downloadFolder = DownloadFolder.defaultURL
			isUsingDefaultDownloadFolder = true
			message = Message(
				title: "Download folder unavailable",
				detail: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
				isError: true
			)
		}
	}

	/// Adopts a folder the user picked in the Files app.
	func chooseDownloadFolder(_ url: URL) async {
		guard DownloadFolder.open(url) else {
			message = Message(
				title: "Could not use that folder",
				detail: "iTorrent was not given permission to write to it.",
				isError: true
			)
			return
		}

		do {
			try await session.setDownloadDirectory(url)
			try DownloadFolder.remember(url)
			downloadFolder = url
			isUsingDefaultDownloadFolder = false
			message = Message(
				title: "Downloads will go to \(url.lastPathComponent)",
				detail: "Torrents already added keep their current folder.",
				isError: false
			)
		} catch {
			DownloadFolder.forget()
			message = Message(
				title: "Could not use that folder",
				detail: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
				isError: true
			)
		}
	}

	/// Goes back to the folder inside the app, the one visible in Files.
	func useDefaultDownloadFolder() async {
		DownloadFolder.forget()
		do {
			try await session.setDownloadDirectory(DownloadFolder.defaultURL)
			downloadFolder = DownloadFolder.defaultURL
			isUsingDefaultDownloadFolder = true
		} catch {
			message = Message(
				title: "Could not use the default folder",
				detail: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
				isError: true
			)
		}
	}

	func prepareForBackground() async {
		// iOS ignores the idle timer flag outside the foreground anyway;
		// clearing it keeps our own state honest.
		setIdleTimerDisabled(false)
		await session.prepareForBackground()
	}

	func applicationBecameActive() {
		updateIdleTimer()
		// Sockets do not survive suspension, so nudge the engine rather than
		// letting the user stare at a stalled torrent until a backoff expires.
		Task { [session] in await session.recoverFromBackground() }
	}

	// MARK: - Keeping the screen awake

	/// Whether anything is actively transferring right now.
	///
	/// Seeding deliberately does not count: holding a phone's screen on all
	/// night to serve other people's downloads is not a trade most users would
	/// knowingly make.
	private var hasActiveTransfer: Bool {
		torrents.contains { snapshot in
			switch snapshot.status {
			case .downloading, .fetchingMetadata, .checkingFiles: true
			case .stalled: snapshot.downloadRate > 0
			default: false
			}
		}
	}

	private func updateIdleTimer() {
		setIdleTimerDisabled(settings.keepScreenAwakeWhileDownloading && hasActiveTransfer)
	}

	private func setIdleTimerDisabled(_ disabled: Bool) {
		guard disabled != isHoldingScreenAwake else { return }
		isHoldingScreenAwake = disabled
		UIApplication.shared.isIdleTimerDisabled = disabled
	}

	// MARK: - Adding

	func open(url: URL) async {
		if url.scheme?.lowercased() == "magnet" {
			await add(magnetLink: url.absoluteString)
		} else {
			await add(torrentFile: url)
		}
	}

	func add(magnetLink: String) async {
		do {
			let infoHash = try await session.add(magnetLink: magnetLink)
			message = Message(
				title: "Torrent added",
				detail: "Looking for peers for \(infoHash.abbreviated).",
				isError: false
			)
		} catch {
			report(error)
		}
	}

	func add(torrentFile url: URL) async {
		do {
			let infoHash = try await session.add(torrentFileAt: url)
			message = Message(
				title: "Torrent added",
				detail: torrent(with: infoHash)?.name,
				isError: false
			)
		} catch {
			report(error)
		}
	}

	// MARK: - Commands

	func togglePause(_ snapshot: TorrentSnapshot) async {
		if snapshot.status.isPaused || snapshot.status == .finished {
			await session.resume(infoHash: snapshot.infoHash)
		} else {
			await session.pause(infoHash: snapshot.infoHash)
		}
	}

	func remove(_ snapshot: TorrentSnapshot, deleteFiles: Bool) async {
		await session.remove(infoHash: snapshot.infoHash, deleteFiles: deleteFiles)
	}

	func recheck(_ snapshot: TorrentSnapshot) async {
		await session.recheck(infoHash: snapshot.infoHash)
	}

	func forceAnnounce(_ snapshot: TorrentSnapshot) async {
		await session.forceAnnounce(infoHash: snapshot.infoHash)
	}

	func pauseAll() async {
		await session.pauseAll()
	}

	func resumeAll() async {
		await session.resumeAll()
	}

	func setPriority(_ priority: PiecePriority, forFileAt index: Int, in snapshot: TorrentSnapshot) async {
		await session.setPriority(priority, forFileAt: index, in: snapshot.infoHash)
	}

	func addTracker(_ url: String, to snapshot: TorrentSnapshot) async {
		await session.addTracker(url, to: snapshot.infoHash)
	}

	func exportTorrentFile(_ snapshot: TorrentSnapshot) async -> URL? {
		guard let data = await session.exportTorrentFile(infoHash: snapshot.infoHash) else { return nil }
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("\(snapshot.name).torrent")
		do {
			try data.write(to: url, options: .atomic)
			return url
		} catch {
			report(error)
			return nil
		}
	}

	func apply(settings newValue: SessionSettings) async {
		settings = newValue
		await session.update(settings: newValue)
		updateIdleTimer()
	}

	private func report(_ error: Error) {
		message = Message(
			title: "Could not add torrent",
			detail: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
			isError: true
		)
	}
}

// MARK: - Presentation helpers

extension TorrentStatus {
	var tint: Color {
		switch self {
		case .downloading: .accentColor
		case .seeding: .green
		case .fetchingMetadata: .purple
		case .checkingFiles: .orange
		case .stalled: .yellow
		case .paused, .queued: .secondary
		case .finished: .green
		case .failed: .red
		}
	}

	var systemImage: String {
		switch self {
		case .downloading: "arrow.down.circle.fill"
		case .seeding: "arrow.up.circle.fill"
		case .fetchingMetadata: "magnifyingglass.circle.fill"
		case .checkingFiles: "checkmark.seal.fill"
		case .stalled: "hourglass.circle.fill"
		case .paused: "pause.circle.fill"
		case .queued: "clock.circle.fill"
		case .finished: "checkmark.circle.fill"
		case .failed: "exclamationmark.triangle.fill"
		}
	}

	/// A longer description than `label`, used where there is room for it.
	var detailedDescription: String {
		switch self {
		case let .checkingFiles(progress): "Checking files \(Format.percent(progress))"
		case let .fetchingMetadata(progress): "Fetching metadata \(Format.percent(progress))"
		case let .failed(reason): reason
		default: label
		}
	}
}
