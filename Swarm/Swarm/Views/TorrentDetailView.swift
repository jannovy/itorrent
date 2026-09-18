import SwiftUI
import TorrentKit

struct TorrentDetailView: View {
	let infoHash: InfoHash

	@Environment(TorrentStore.self) private var store
	@State private var tab: Tab = .overview
	@State private var newTrackerURL = ""
	@State private var isShowingTrackerField = false
	@State private var exportURL: URL?

	enum Tab: String, CaseIterable, Identifiable {
		case overview = "Info"
		case files = "Files"
		case peers = "Peers"
		case trackers = "Trackers"

		var id: String { rawValue }
	}

	var body: some View {
		Group {
			if let snapshot = store.torrent(with: infoHash) {
				content(for: snapshot)
			} else {
				ContentUnavailableView("Torrent removed", systemImage: "trash")
			}
		}
		.navigationTitle(store.torrent(with: infoHash)?.name ?? "Torrent")
		.navigationBarTitleDisplayMode(.inline)
	}

	private func content(for snapshot: TorrentSnapshot) -> some View {
		VStack(spacing: 0) {
			header(for: snapshot)

			Picker("Section", selection: $tab) {
				ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
			}
			.pickerStyle(.segmented)
			.padding(.horizontal)
			.padding(.bottom, 8)

			switch tab {
			case .overview: overview(for: snapshot)
			case .files: files(for: snapshot)
			case .peers: peers(for: snapshot)
			case .trackers: trackers(for: snapshot)
			}
		}
		.toolbar {
			ToolbarItem(placement: .topBarTrailing) {
				Menu {
					Button {
						Task { await store.togglePause(snapshot) }
					} label: {
						let paused = snapshot.status.isPaused || snapshot.status == .finished
						Label(paused ? "Resume" : "Pause", systemImage: paused ? "play" : "pause")
					}
					Button {
						Task { await store.recheck(snapshot) }
					} label: {
						Label("Verify files", systemImage: "checkmark.seal")
					}
					Button {
						Task { await store.forceAnnounce(snapshot) }
					} label: {
						Label("Announce now", systemImage: "antenna.radiowaves.left.and.right")
					}
					if !snapshot.isMagnetOnly {
						Button {
							Task { exportURL = await store.exportTorrentFile(snapshot) }
						} label: {
							Label("Export .torrent", systemImage: "square.and.arrow.up")
						}
					}
				} label: {
					Image(systemName: "ellipsis.circle")
				}
			}
		}
		.sheet(item: $exportURL) { url in
			ShareSheet(items: [url])
		}
	}

	// MARK: - Header

	private func header(for snapshot: TorrentSnapshot) -> some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack {
				Label(snapshot.status.detailedDescription, systemImage: snapshot.status.systemImage)
					.font(.subheadline.weight(.medium))
					.foregroundStyle(snapshot.status.tint)
				Spacer()
				Text(Format.percent(snapshot.progress))
					.font(.subheadline.monospacedDigit().weight(.semibold))
			}

			ProgressTrack(progress: snapshot.progress, tint: snapshot.status.tint, height: 7)

			HStack(spacing: 18) {
				StatBadge(systemImage: "arrow.down", value: Format.rate(snapshot.downloadRate), tint: .accentColor)
				StatBadge(systemImage: "arrow.up", value: Format.rate(snapshot.uploadRate), tint: .green)
				StatBadge(systemImage: "person.2", value: "\(snapshot.connectedPeers)/\(snapshot.knownPeers)")
				Spacer()
				StatBadge(systemImage: "clock", value: Format.duration(snapshot.estimatedTimeRemaining))
			}
		}
		.padding(.horizontal)
		.padding(.bottom, 12)
	}

	// MARK: - Tabs

	private func overview(for snapshot: TorrentSnapshot) -> some View {
		List {
			Section("Transfer") {
				LabeledValue("Downloaded", Format.bytes(snapshot.downloadedBytes))
				LabeledValue("Uploaded", Format.bytes(snapshot.uploadedBytes))
				LabeledValue("Ratio", Format.ratio(snapshot.ratio))
				LabeledValue("Remaining", Format.bytes(snapshot.remainingBytes))
			}

			Section("Content") {
				LabeledValue("Total size", Format.bytes(snapshot.totalBytes))
				if snapshot.wantedBytes != snapshot.totalBytes {
					LabeledValue("Selected", Format.bytes(snapshot.wantedBytes))
				}
				LabeledValue("Pieces", "\(snapshot.completedPieces) / \(snapshot.pieceCount)")
				LabeledValue("Files", "\(snapshot.files.count)")
				LabeledValue("Seeds connected", "\(snapshot.connectedSeeds)")
			}

			Section("Details") {
				LabeledValue("Info hash", snapshot.infoHash.hex, isMonospaced: true)
				LabeledValue("Added", snapshot.addedAt.formatted(date: .abbreviated, time: .shortened))
				if let completedAt = snapshot.completedAt {
					LabeledValue("Completed", completedAt.formatted(date: .abbreviated, time: .shortened))
				}
				LabeledValue("Save path", snapshot.savePath)
			}

			if let error = snapshot.errorMessage {
				Section("Problem") {
					Text(error).foregroundStyle(.red).font(.subheadline)
				}
			}
		}
		.listStyle(.insetGrouped)
	}

	private func files(for snapshot: TorrentSnapshot) -> some View {
		Group {
			if snapshot.files.isEmpty {
				ContentUnavailableView(
					"No file list yet",
					systemImage: "doc.questionmark",
					description: Text("The file list appears once the torrent metadata has been downloaded.")
				)
			} else {
				List(snapshot.files) { file in
					VStack(alignment: .leading, spacing: 6) {
						HStack(alignment: .firstTextBaseline) {
							Text(file.name)
								.font(.subheadline)
								.lineLimit(2)
								.strikethrough(file.priority == .skip)
								.foregroundStyle(file.priority == .skip ? .secondary : .primary)
							Spacer(minLength: 8)
							Text(Format.bytes(file.length))
								.font(.caption.monospacedDigit())
								.foregroundStyle(.secondary)
						}

						ProgressTrack(
							progress: file.progress,
							tint: file.priority == .skip ? .gray : .accentColor,
							height: 4
						)

						HStack {
							Text(Format.percent(file.progress))
								.font(.caption2.monospacedDigit())
								.foregroundStyle(.secondary)
							Spacer()
							Picker("Priority", selection: priorityBinding(for: file, in: snapshot)) {
								Text("Skip").tag(PiecePriority.skip)
								Text("Normal").tag(PiecePriority.normal)
								Text("High").tag(PiecePriority.high)
							}
							.pickerStyle(.menu)
							.font(.caption2)
						}
					}
					.padding(.vertical, 4)
				}
				.listStyle(.plain)
			}
		}
	}

	private func peers(for snapshot: TorrentSnapshot) -> some View {
		Group {
			if snapshot.peers.isEmpty {
				ContentUnavailableView(
					"No peers connected",
					systemImage: "person.2.slash",
					description: Text("Swarm is still looking for peers through trackers and the DHT.")
				)
			} else {
				List(snapshot.peers) { peer in
					VStack(alignment: .leading, spacing: 5) {
						HStack {
							Text(peer.address.description)
								.font(.system(.footnote, design: .monospaced))
							Spacer()
							Text(peer.flags)
								.font(.system(.caption2, design: .monospaced))
								.foregroundStyle(.secondary)
						}
						HStack(spacing: 14) {
							Text(peer.client)
								.font(.caption)
								.foregroundStyle(.secondary)
								.lineLimit(1)
							Spacer()
							Text(Format.percent(peer.progress))
								.font(.caption.monospacedDigit())
								.foregroundStyle(.secondary)
							if peer.downloadRate > 0 {
								StatBadge(systemImage: "arrow.down", value: Format.rate(peer.downloadRate), tint: .accentColor)
							}
							if peer.uploadRate > 0 {
								StatBadge(systemImage: "arrow.up", value: Format.rate(peer.uploadRate), tint: .green)
							}
						}
						ProgressTrack(progress: peer.progress, tint: .secondary, height: 3)
					}
					.padding(.vertical, 3)
				}
				.listStyle(.plain)
			}
		}
	}

	private func trackers(for snapshot: TorrentSnapshot) -> some View {
		List {
			Section {
				ForEach(snapshot.trackers) { tracker in
					VStack(alignment: .leading, spacing: 4) {
						HStack {
							Circle()
								.fill(color(for: tracker.state))
								.frame(width: 8, height: 8)
							Text(tracker.host)
								.font(.subheadline)
								.lineLimit(1)
							Spacer()
							if let seeders = tracker.seeders, let leechers = tracker.leechers {
								Text("\(seeders)S / \(leechers)L")
									.font(.caption.monospacedDigit())
									.foregroundStyle(.secondary)
							}
						}
						if let message = tracker.message {
							Text(message)
								.font(.caption2)
								.foregroundStyle(tracker.state.isFailure ? .red : .secondary)
								.lineLimit(2)
						}
						if let next = tracker.nextAnnounce, !tracker.state.isFailure {
							Text("Next announce \(next.formatted(date: .omitted, time: .shortened))")
								.font(.caption2)
								.foregroundStyle(.tertiary)
						}
					}
					.padding(.vertical, 2)
				}
			} header: {
				Text("\(snapshot.trackers.count) tracker(s)")
			} footer: {
				if snapshot.trackers.isEmpty {
					Text("This torrent has no trackers. It relies on the DHT and peer exchange to find peers.")
				}
			}

			Section("Add tracker") {
				HStack {
					TextField("udp://tracker.example:1337/announce", text: $newTrackerURL)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.font(.system(.footnote, design: .monospaced))
					Button("Add") {
						let url = newTrackerURL.trimmingCharacters(in: .whitespacesAndNewlines)
						guard !url.isEmpty else { return }
						Task { await store.addTracker(url, to: snapshot) }
						newTrackerURL = ""
					}
					.disabled(newTrackerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
				}
			}
		}
		.listStyle(.insetGrouped)
	}

	private func priorityBinding(for file: FileSnapshot, in snapshot: TorrentSnapshot) -> Binding<PiecePriority> {
		Binding(
			get: { file.priority },
			set: { newValue in
				Task { await store.setPriority(newValue, forFileAt: file.index, in: snapshot) }
			}
		)
	}

	private func color(for state: TrackerStatus.State) -> Color {
		switch state {
		case .working: .green
		case .announcing: .orange
		case .idle: .secondary
		case .failed, .unsupported: .red
		}
	}
}

/// `URL` is made `Identifiable` so it can drive a `.sheet(item:)` for export.
extension URL: @retroactive Identifiable {
	public var id: String { absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
	let items: [Any]

	func makeUIViewController(context: Context) -> UIActivityViewController {
		UIActivityViewController(activityItems: items, applicationActivities: nil)
	}

	func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
