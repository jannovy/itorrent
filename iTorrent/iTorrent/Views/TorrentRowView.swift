import SwiftUI
import TorrentKit

struct TorrentRowView: View {
	let snapshot: TorrentSnapshot

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Image(systemName: snapshot.status.systemImage)
					.foregroundStyle(snapshot.status.tint)
					.imageScale(.small)

				Text(snapshot.name)
					.font(.subheadline.weight(.medium))
					.lineLimit(2)

				Spacer(minLength: 8)

				Text(Format.percent(snapshot.progress))
					.font(.caption.monospacedDigit())
					.foregroundStyle(.secondary)
			}

			ProgressTrack(progress: snapshot.progress, tint: snapshot.status.tint)

			HStack(spacing: 14) {
				Text(sizeSummary)
					.font(.caption)
					.foregroundStyle(.secondary)
					.monospacedDigit()

				if snapshot.downloadRate > 0 {
					StatBadge(systemImage: "arrow.down", value: Format.rate(snapshot.downloadRate), tint: .accentColor)
				}
				if snapshot.uploadRate > 0 {
					StatBadge(systemImage: "arrow.up", value: Format.rate(snapshot.uploadRate), tint: .green)
				}

				Spacer(minLength: 0)

				if snapshot.connectedPeers > 0 {
					StatBadge(systemImage: "person.2", value: "\(snapshot.connectedPeers)")
				}
				if let eta = snapshot.estimatedTimeRemaining {
					StatBadge(systemImage: "clock", value: Format.duration(eta))
				}
			}
		}
		.padding(.vertical, 6)
	}

	private var sizeSummary: String {
		switch snapshot.status {
		case .fetchingMetadata:
			return snapshot.status.detailedDescription
		case let .checkingFiles(progress):
			return "Checking \(Format.percent(progress))"
		case let .failed(reason):
			return reason
		case .seeding, .finished:
			return "\(Format.bytes(snapshot.totalBytes)) · ratio \(Format.ratio(snapshot.ratio))"
		default:
			let done = snapshot.wantedBytes - snapshot.remainingBytes
			return "\(Format.bytes(done)) of \(Format.bytes(snapshot.wantedBytes))"
		}
	}
}
