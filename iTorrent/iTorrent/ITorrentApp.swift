import SwiftUI
import TorrentKit

@main
struct ITorrentApp: App {
	@State private var store = TorrentStore()
	@Environment(\.scenePhase) private var scenePhase

	var body: some Scene {
		WindowGroup {
			TorrentListView()
				.environment(store)
				.task { await store.start() }
				// Magnet links tapped in Safari arrive here.
				.onOpenURL { url in
					Task { await store.open(url: url) }
				}
		}
		.onChange(of: scenePhase) { _, phase in
			// iOS can kill a suspended app without warning, so resume data is
			// flushed the moment we leave the foreground.
			if phase == .active {
				store.applicationBecameActive()
			} else {
				Task { await store.prepareForBackground() }
			}
		}
	}
}
