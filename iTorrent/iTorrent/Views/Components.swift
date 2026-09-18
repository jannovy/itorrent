import SwiftUI
import TorrentKit

/// A thin progress track. `ProgressView` is deliberately not used: its bar is
/// too tall for a dense list and cannot be tinted per row without fighting the
/// style system.
struct ProgressTrack: View {
	let progress: Double
	let tint: Color
	var height: CGFloat = 5

	var body: some View {
		GeometryReader { geometry in
			ZStack(alignment: .leading) {
				Capsule()
					.fill(.quaternary)
				Capsule()
					.fill(tint.gradient)
					.frame(width: max(0, min(1, progress)) * geometry.size.width)
			}
		}
		.frame(height: height)
		.animation(.easeOut(duration: 0.4), value: progress)
	}
}

/// A small icon-and-value pair, used across the list and detail screens.
struct StatBadge: View {
	let systemImage: String
	let value: String
	var tint: Color = .secondary

	var body: some View {
		Label(value, systemImage: systemImage)
			.font(.caption)
			.foregroundStyle(tint)
			.labelStyle(.titleAndIcon)
			.monospacedDigit()
			// Rates like "2,4 MB/s" otherwise wrap onto two lines in the
			// status bar and shove the row's height around as speeds change.
			.lineLimit(1)
			.fixedSize(horizontal: true, vertical: false)
	}
}

struct LabeledValue: View {
	let label: String
	let value: String
	var isMonospaced = false

	init(_ label: String, _ value: String, isMonospaced: Bool = false) {
		self.label = label
		self.value = value
		self.isMonospaced = isMonospaced
	}

	var body: some View {
		HStack(alignment: .firstTextBaseline) {
			Text(label)
				.foregroundStyle(.secondary)
			Spacer(minLength: 12)
			Text(value)
				.multilineTextAlignment(.trailing)
				.font(isMonospaced ? .system(.body, design: .monospaced) : .body)
				.textSelection(.enabled)
		}
		.font(.subheadline)
	}
}

/// The persistent footer showing session-wide throughput.
struct SessionStatusBar: View {
	let statistics: TorrentSession.Statistics
	var isHoldingScreenAwake = false

	var body: some View {
		HStack(spacing: 16) {
			StatBadge(
				systemImage: "arrow.down",
				value: Format.rate(statistics.downloadRate),
				tint: statistics.downloadRate > 0 ? .accentColor : .secondary
			)
			StatBadge(
				systemImage: "arrow.up",
				value: Format.rate(statistics.uploadRate),
				tint: statistics.uploadRate > 0 ? .green : .secondary
			)
			Divider().frame(height: 12)
			StatBadge(systemImage: "person.2", value: "\(statistics.connectedPeers)")
			if statistics.dhtNodes > 0 {
				StatBadge(systemImage: "point.3.connected.trianglepath.dotted", value: "\(statistics.dhtNodes)")
			}
			Spacer()
			if isHoldingScreenAwake {
				// Without this the user has no way to tell why their screen
				// stopped dimming.
				Image(systemName: "sun.max.fill")
					.font(.caption2)
					.foregroundStyle(.orange)
					.accessibilityLabel("Screen kept awake while downloading")
			}
			if statistics.listenPort > 0 {
				Text("port \(String(statistics.listenPort))")
					.font(.caption2)
					.foregroundStyle(.tertiary)
					.monospacedDigit()
					// On a narrow screen this otherwise breaks mid-number, so
					// the bar reads "port 590 / 94" across two lines.
					.lineLimit(1)
					.fixedSize(horizontal: true, vertical: false)
			}
		}
		.padding(.horizontal)
		.padding(.vertical, 8)
		.background(.bar)
	}
}

struct EmptyTorrentsView: View {
	let onAdd: () -> Void

	var body: some View {
		ContentUnavailableView {
			Label("No torrents", systemImage: "water.waves")
		} description: {
			Text("Add a magnet link or open a .torrent file to get started.")
		} actions: {
			Button("Add torrent", action: onAdd)
				.buttonStyle(.borderedProminent)
		}
	}
}

/// One web seed in the trackers tab: its state, what it has contributed, and
/// why it stopped if it did.
struct WebSeedRow: View {
	let seed: WebSeedStatus

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack {
				Circle()
					.fill(seed.isEnabled ? Color.green : Color.secondary)
					.frame(width: 8, height: 8)
				Text(seed.url)
					.font(.system(.caption, design: .monospaced))
					.lineLimit(1)
					.truncationMode(.middle)
				Spacer()
				if seed.piecesInFlight > 0 {
					Text("\(seed.piecesInFlight)")
						.font(.caption.monospacedDigit())
						.foregroundStyle(.secondary)
				}
			}

			HStack(spacing: 8) {
				Text(Format.bytes(seed.downloadedBytes))
					.foregroundStyle(.secondary)
				if let error = seed.lastError {
					Text(error)
						.foregroundStyle(seed.isEnabled ? Color.secondary : Color.red)
						.lineLimit(1)
				}
			}
			.font(.caption2)
		}
		.padding(.vertical, 2)
	}
}
