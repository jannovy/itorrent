import SwiftUI
import TorrentKit
import UniformTypeIdentifiers

struct TorrentListView: View {
	@Environment(TorrentStore.self) private var store

	@State private var isShowingAddSheet = false
	@State private var isShowingSettings = false
	@State private var isShowingFileImporter = false
	@State private var removalTarget: TorrentSnapshot?

	var body: some View {
		@Bindable var store = store

		NavigationStack {
			Group {
				if store.torrents.isEmpty {
					EmptyTorrentsView { isShowingAddSheet = true }
				} else {
					list
				}
			}
			.navigationTitle("Swarm")
			.safeAreaInset(edge: .bottom, spacing: 0) {
				SessionStatusBar(
					statistics: store.statistics,
					isHoldingScreenAwake: store.isHoldingScreenAwake
				)
			}
			.toolbar { toolbarContent }
			.sheet(isPresented: $isShowingAddSheet) {
				AddTorrentView()
			}
			.sheet(isPresented: $isShowingSettings) {
				SettingsView()
			}
			.fileImporter(
				isPresented: $isShowingFileImporter,
				allowedContentTypes: [Self.torrentType, .data],
				allowsMultipleSelection: true
			) { result in
				handleImport(result)
			}
			.alert(item: $store.message) { message in
				Alert(
					title: Text(message.title),
					message: message.detail.map(Text.init),
					dismissButton: .default(Text("OK"))
				)
			}
			.confirmationDialog(
				removalTarget.map { "Remove \($0.name)?" } ?? "Remove torrent?",
				isPresented: Binding(
					get: { removalTarget != nil },
					set: { if !$0 { removalTarget = nil } }
				),
				titleVisibility: .visible
			) {
				if let target = removalTarget {
					Button("Remove torrent only") {
						Task { await store.remove(target, deleteFiles: false) }
						removalTarget = nil
					}
					Button("Remove and delete files", role: .destructive) {
						Task { await store.remove(target, deleteFiles: true) }
						removalTarget = nil
					}
				}
				Button("Cancel", role: .cancel) { removalTarget = nil }
			}
		}
	}

	private var list: some View {
		@Bindable var store = store

		return List {
			if store.torrents.count > 1 {
				Picker("Filter", selection: $store.filter) {
					ForEach(TorrentStore.Filter.allCases) { filter in
						Label(filter.rawValue, systemImage: filter.systemImage).tag(filter)
					}
				}
				.pickerStyle(.segmented)
				.listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 8, trailing: 12))
				.listRowSeparator(.hidden)
				.listRowBackground(Color.clear)
			}

			ForEach(store.filteredTorrents) { snapshot in
				NavigationLink(value: snapshot.infoHash) {
					TorrentRowView(snapshot: snapshot)
				}
				.swipeActions(edge: .trailing, allowsFullSwipe: false) {
					Button(role: .destructive) {
						removalTarget = snapshot
					} label: {
						Label("Remove", systemImage: "trash")
					}
				}
				.swipeActions(edge: .leading) {
					Button {
						Task { await store.togglePause(snapshot) }
					} label: {
						let paused = snapshot.status.isPaused || snapshot.status == .finished
						Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
					}
					.tint(snapshot.status.isPaused ? .green : .orange)
				}
				.contextMenu {
					torrentContextMenu(for: snapshot)
				}
			}
		}
		.listStyle(.plain)
		.navigationDestination(for: InfoHash.self) { infoHash in
			TorrentDetailView(infoHash: infoHash)
		}
	}

	@ViewBuilder
	private func torrentContextMenu(for snapshot: TorrentSnapshot) -> some View {
		Button {
			Task { await store.togglePause(snapshot) }
		} label: {
			let paused = snapshot.status.isPaused || snapshot.status == .finished
			Label(paused ? "Resume" : "Pause", systemImage: paused ? "play" : "pause")
		}
		Button {
			Task { await store.forceAnnounce(snapshot) }
		} label: {
			Label("Announce now", systemImage: "antenna.radiowaves.left.and.right")
		}
		Button {
			Task { await store.recheck(snapshot) }
		} label: {
			Label("Verify files", systemImage: "checkmark.seal")
		}
		Divider()
		Button(role: .destructive) {
			removalTarget = snapshot
		} label: {
			Label("Remove", systemImage: "trash")
		}
	}

	@ToolbarContentBuilder
	private var toolbarContent: some ToolbarContent {
		ToolbarItem(placement: .topBarLeading) {
			Menu {
				Button {
					Task { await store.resumeAll() }
				} label: {
					Label("Resume all", systemImage: "play")
				}
				Button {
					Task { await store.pauseAll() }
				} label: {
					Label("Pause all", systemImage: "pause")
				}
				Divider()
				Button {
					isShowingSettings = true
				} label: {
					Label("Settings", systemImage: "gearshape")
				}
			} label: {
				Image(systemName: "ellipsis.circle")
			}
		}

		ToolbarItem(placement: .topBarTrailing) {
			Menu {
				Button {
					isShowingAddSheet = true
				} label: {
					Label("Magnet link", systemImage: "link")
				}
				Button {
					isShowingFileImporter = true
				} label: {
					Label("Torrent file", systemImage: "doc")
				}
			} label: {
				Image(systemName: "plus")
			}
		}
	}

	private func handleImport(_ result: Result<[URL], Error>) {
		switch result {
		case let .success(urls):
			for url in urls {
				Task { await store.add(torrentFile: url) }
			}
		case let .failure(error):
			store.message = TorrentStore.Message(
				title: "Import failed",
				detail: error.localizedDescription,
				isError: true
			)
		}
	}

	/// Falls back to `public.data` on systems that do not know the torrent type,
	/// otherwise the importer would show every file greyed out.
	private static var torrentType: UTType {
		UTType(filenameExtension: "torrent") ?? .data
	}
}
