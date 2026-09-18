// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "TorrentKit",
	platforms: [.iOS(.v17), .macOS(.v14)],
	products: [
		.library(name: "TorrentKit", targets: ["TorrentKit"]),
	],
	targets: [
		.target(
			name: "TorrentKit",
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
		.testTarget(
			name: "TorrentKitTests",
			dependencies: ["TorrentKit"],
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
	]
)
