import SwiftUI
import TorrentKit

struct AddTorrentView: View {
	@Environment(TorrentStore.self) private var store
	@Environment(\.dismiss) private var dismiss

	@State private var magnetText = ""
	@State private var validationError: String?
	@FocusState private var isFieldFocused: Bool

	var body: some View {
		NavigationStack {
			Form {
				Section {
					TextField("magnet:?xt=urn:btih:…", text: $magnetText, axis: .vertical)
						.lineLimit(3...8)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.font(.system(.footnote, design: .monospaced))
						.focused($isFieldFocused)
						.onChange(of: magnetText) { _, _ in validate() }

					if let pasteboardMagnet, pasteboardMagnet != magnetText {
						Button {
							magnetText = pasteboardMagnet
							validate()
						} label: {
							Label("Paste from clipboard", systemImage: "doc.on.clipboard")
						}
					}
				} header: {
					Text("Magnet link")
				} footer: {
					if let validationError {
						Text(validationError).foregroundStyle(.red)
					} else if let preview {
						VStack(alignment: .leading, spacing: 4) {
							Text(preview.name).fontWeight(.medium)
							Text(preview.infoHash.hex)
								.font(.system(.caption2, design: .monospaced))
							Text("\(preview.trackerCount) tracker(s)")
								.font(.caption2)
						}
						.foregroundStyle(.secondary)
					} else {
						Text("Paste a magnet link, or use the + menu to open a .torrent file.")
					}
				}
			}
			.navigationTitle("Add torrent")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Add") {
						Task {
							await store.add(magnetLink: magnetText)
							dismiss()
						}
					}
					.disabled(preview == nil)
				}
			}
			.onAppear { isFieldFocused = true }
		}
	}

	private struct Preview {
		let name: String
		let infoHash: InfoHash
		let trackerCount: Int
	}

	/// Parsed live so the user finds out a link is malformed before they commit
	/// to it, rather than through an error alert afterwards.
	private var preview: Preview? {
		guard !magnetText.isEmpty, let magnet = try? MagnetURI(string: magnetText) else { return nil }
		return Preview(
			name: magnet.displayName ?? magnet.infoHash.abbreviated,
			infoHash: magnet.infoHash,
			trackerCount: magnet.trackers.count
		)
	}

	private var pasteboardMagnet: String? {
		guard let text = UIPasteboard.general.string,
		      text.lowercased().hasPrefix("magnet:")
		else { return nil }
		return text
	}

	private func validate() {
		let trimmed = magnetText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			validationError = nil
			return
		}
		do {
			_ = try MagnetURI(string: trimmed)
			validationError = nil
		} catch {
			validationError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
		}
	}
}
