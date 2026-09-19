import SwiftUI
import TorrentKit

struct SettingsView: View {
	@Environment(TorrentStore.self) private var store
	@Environment(\.dismiss) private var dismiss

	@State private var draft = SessionSettings.default
	@State private var isChoosingFolder = false

	/// Speed limits are edited as a menu of sane values rather than a free text
	/// field; typing bytes-per-second on a phone is nobody's idea of a good time.
	private static let speedOptions: [Int] = [
		0, 50_000, 100_000, 250_000, 500_000, 1_000_000, 2_000_000, 5_000_000, 10_000_000,
	]

	var body: some View {
		NavigationStack {
			Form {
				Section {
					LabeledContent("Incoming port") {
						TextField("0 = automatic", value: $draft.listenPort, format: .number)
							.keyboardType(.numberPad)
							.multilineTextAlignment(.trailing)
							.monospacedDigit()
					}
					Toggle("Distributed hash table", isOn: $draft.isDHTEnabled)
					Toggle("Peer exchange", isOn: $draft.isPeerExchangeEnabled)
					Toggle("Web seeds", isOn: $draft.areWebSeedsEnabled)
				} header: {
					Text("Network")
				} footer: {
					Text("DHT and peer exchange find peers without a tracker; both are ignored for private torrents, which forbid them. Web seeds download from an ordinary HTTP server listed in the torrent, so a torrent whose swarm has gone quiet still finishes.")
				}

				Section {
					Toggle("µTP", isOn: $draft.isUTPEnabled)
					Picker("Encryption", selection: $draft.encryptionPolicy) {
						ForEach(EncryptionPolicy.allCases, id: \.self) { policy in
							Text(policy.label).tag(policy)
						}
					}
				} header: {
					Text("Transport")
				} footer: {
					Text("µTP carries BitTorrent over UDP and backs off when it notices it is adding delay, so a download does not make the rest of the connection unusable. Peers that cannot do it are redialled over TCP.\n\nEncryption hides the protocol from equipment that throttles BitTorrent, and is needed for peers that accept nothing else. \"Prefer\" falls back to plaintext rather than losing a peer.")
				}

				Section {
					speedPicker("Download limit", selection: $draft.downloadLimit)
					speedPicker("Upload limit", selection: $draft.uploadLimit)
				} header: {
					Text("Speed limits")
				} footer: {
					Text("A download limit works by asking peers for fewer blocks, so the effective rate settles a little below the value you pick.")
				}

				Section("Connections") {
					Stepper(
						"Peers per torrent: \(draft.maximumPeersPerTorrent)",
						value: $draft.maximumPeersPerTorrent,
						in: 10...200,
						step: 10
					)
					Stepper(
						"Peers total: \(draft.maximumGlobalPeers)",
						value: $draft.maximumGlobalPeers,
						in: 20...500,
						step: 20
					)
				}

				Section {
					Toggle("Keep screen awake", isOn: $draft.keepScreenAwakeWhileDownloading)
				} header: {
					Text("While downloading")
				} footer: {
					Text("iOS suspends the app as soon as the display sleeps, which stops transfers. This holds off the automatic lock while something is downloading, and releases it when everything is finished. Pressing the side button still locks the phone.")
				}

				Section("Seeding") {
					Picker("Stop at ratio", selection: $draft.seedRatioLimit) {
						Text("Never").tag(0.0)
						Text("1.0").tag(1.0)
						Text("1.5").tag(1.5)
						Text("2.0").tag(2.0)
						Text("5.0").tag(5.0)
					}
					Toggle("Add torrents paused", isOn: $draft.startTorrentsPaused)
				}

				Section {
					LabeledValue("Downloads", store.downloadFolder.lastPathComponent)
					Text(store.downloadFolder.path)
						.font(.caption2)
						.foregroundStyle(.secondary)
						.textSelection(.enabled)

					Button {
						isChoosingFolder = true
					} label: {
						Label("Choose folder…", systemImage: "folder")
					}

					if !store.isUsingDefaultDownloadFolder {
						Button(role: .destructive) {
							Task { await store.useDefaultDownloadFolder() }
						} label: {
							Label("Use iTorrent+'s own folder", systemImage: "arrow.uturn.backward")
						}
					}
				} header: {
					Text("Storage")
				} footer: {
					Text(storageFooter)
				}

				Section("About") {
					LabeledValue("Client", "iTorrent+ 1.0")
					LabeledValue("Peer ID prefix", PeerID.clientPrefix, isMonospaced: true)
					LabeledValue("Protocols", "BEP 3, 5, 9, 10, 11, 12, 15, 19, 23, 29, 47")
					LabeledValue("Encryption", "MSE/PE (RC4)")
				}
			}
			.navigationTitle("Settings")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Save") {
						Task {
							await store.apply(settings: draft)
							dismiss()
						}
					}
					.disabled(draft == store.settings)
				}
			}
			.fileImporter(
				isPresented: $isChoosingFolder,
				allowedContentTypes: [.folder]
			) { result in
				switch result {
				case let .success(url):
					Task { await store.chooseDownloadFolder(url) }
				case let .failure(error):
					store.message = TorrentStore.Message(
						title: "Could not use that folder",
						detail: error.localizedDescription,
						isError: true
					)
				}
			}
			.task {
				draft = store.settings
			}
		}
	}

	private var storageFooter: String {
		if store.isUsingDefaultDownloadFolder {
			return "Downloads live in the app's Documents folder and are visible in Files under \"On My iPhone → iTorrent+\". Choosing another folder works too — an external drive, iCloud Drive, or anywhere else the Files app can reach."
		}
		return "Torrents added from now on are saved here. Ones already added keep the folder they were added with, so nothing moves behind your back. If this folder becomes unavailable — an unplugged drive, say — iTorrent+ falls back to its own folder and says so."
	}

	private func speedPicker(_ title: String, selection: Binding<Int>) -> some View {
		Picker(title, selection: selection) {
			ForEach(Self.speedOptions, id: \.self) { value in
				Text(value == 0 ? "Unlimited" : Format.rate(Double(value))).tag(value)
			}
		}
	}
}
