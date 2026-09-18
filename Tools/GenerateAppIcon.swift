import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders the app icon.
///
/// Kept in the repository so the icon is reproducible rather than a binary
/// nobody can regenerate:
///
///     swiftc Tools/GenerateAppIcon.swift -o /tmp/icon && /tmp/icon <output.png>
///
/// The glyph is a download arrow whose landing bar is split into three pieces —
/// the download half of the name, and the "file arrives in pieces" half. It is
/// drawn with big, flat shapes because an app icon spends most of its life at
/// 40 points, where thin strokes and fine detail turn to mush.
@main
enum GenerateAppIcon {
	static let size = 1024.0

	static func main() {
		let output = CommandLine.arguments.count > 1
			? CommandLine.arguments[1]
			: "AppIcon.png"

		guard let context = CGContext(
			data: nil,
			width: Int(size),
			height: Int(size),
			bitsPerComponent: 8,
			bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		) else {
			FileHandle.standardError.write(Data("Could not create the drawing context.\n".utf8))
			exit(1)
		}

		drawBackground(in: context)
		drawArrow(in: context)
		drawPieces(in: context)

		guard let image = context.makeImage() else { exit(1) }
		let url = URL(fileURLWithPath: output)
		guard let destination = CGImageDestinationCreateWithURL(
			url as CFURL, UTType.png.identifier as CFString, 1, nil
		) else { exit(1) }
		CGImageDestinationAddImage(destination, image, nil)
		guard CGImageDestinationFinalize(destination) else { exit(1) }

		print("Wrote \(Int(size))×\(Int(size)) icon to \(url.path)")
	}

	// MARK: - Drawing

	/// Full bleed: iOS applies the rounded-rectangle mask itself, and an icon
	/// that rounds its own corners ends up with a visible double edge.
	private static func drawBackground(in context: CGContext) {
		let space = CGColorSpace(name: CGColorSpace.sRGB)!
		let colors = [
			CGColor(srgbRed: 0.26, green: 0.80, blue: 0.44, alpha: 1),
			CGColor(srgbRed: 0.04, green: 0.47, blue: 0.42, alpha: 1),
		] as CFArray
		guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return }

		context.drawLinearGradient(
			gradient,
			start: CGPoint(x: 0, y: size),
			end: CGPoint(x: size, y: 0),
			options: []
		)

		// A soft highlight keeps the large flat area from looking like a swatch.
		guard let highlight = CGGradient(
			colorsSpace: space,
			colors: [
				CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18),
				CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
			] as CFArray,
			locations: [0, 1]
		) else { return }
		context.drawRadialGradient(
			highlight,
			startCenter: CGPoint(x: size * 0.3, y: size * 0.85), startRadius: 0,
			endCenter: CGPoint(x: size * 0.3, y: size * 0.85), endRadius: size * 0.75,
			options: []
		)
	}

	/// Core Graphics puts the origin at the bottom left; the layout below reads
	/// top-down, so y values are flipped on the way out.
	private static func flip(_ y: Double) -> Double { size - y }

	private static func drawArrow(in context: CGContext) {
		context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))

		let shaftWidth = 150.0
		let shaft = CGRect(
			x: (size - shaftWidth) / 2,
			y: flip(450),
			width: shaftWidth,
			height: 450 - 195
		)
		context.addPath(CGPath(roundedRect: shaft, cornerWidth: 40, cornerHeight: 40, transform: nil))
		context.fillPath()

		let head = CGMutablePath()
		head.move(to: CGPoint(x: size / 2 - 245, y: flip(420)))
		head.addLine(to: CGPoint(x: size / 2 + 245, y: flip(420)))
		head.addLine(to: CGPoint(x: size / 2, y: flip(700)))
		head.closeSubpath()
		context.addPath(head)
		context.fillPath()
	}

	private static func drawPieces(in context: CGContext) {
		let total = 600.0
		let gap = 26.0
		let height = 94.0
		let width = (total - gap * 2) / 3
		let left = (size - total) / 2

		// Two solid pieces and one faded: a download in progress, not a finished one.
		let alphas = [1.0, 1.0, 0.45]
		for index in 0..<3 {
			context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alphas[index]))
			let rect = CGRect(
				x: left + (width + gap) * Double(index),
				y: flip(762 + height),
				width: width,
				height: height
			)
			context.addPath(CGPath(roundedRect: rect, cornerWidth: 26, cornerHeight: 26, transform: nil))
			context.fillPath()
		}
	}
}
