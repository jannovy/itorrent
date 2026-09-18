import Foundation

/// Display helpers shared by the app UI.
public enum Format {
	private static let byteFormatter: ByteCountFormatter = {
		let formatter = ByteCountFormatter()
		formatter.countStyle = .file
		formatter.allowsNonnumericFormatting = false
		return formatter
	}()

	public static func bytes(_ count: Int64) -> String {
		byteFormatter.string(fromByteCount: max(0, count))
	}

	public static func rate(_ bytesPerSecond: Double) -> String {
		guard bytesPerSecond >= 1 else { return "—" }
		return byteFormatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
	}

	public static func percent(_ fraction: Double) -> String {
		String(format: "%.1f%%", min(100, max(0, fraction * 100)))
	}

	public static func duration(_ seconds: TimeInterval?) -> String {
		guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
		if seconds > 60 * 60 * 24 * 30 { return "∞" }

		let total = Int(seconds)
		let days = total / 86400
		let hours = (total % 86400) / 3600
		let minutes = (total % 3600) / 60
		let remaining = total % 60

		if days > 0 { return "\(days)d \(hours)h" }
		if hours > 0 { return "\(hours)h \(minutes)m" }
		if minutes > 0 { return "\(minutes)m \(remaining)s" }
		return "\(remaining)s"
	}

	public static func ratio(_ value: Double) -> String {
		value.isFinite ? String(format: "%.2f", value) : "∞"
	}
}
