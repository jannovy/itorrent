import Foundation

/// Remembers the folder the user picked for downloads.
///
/// A folder chosen in the Files app lives outside the app's sandbox, and the
/// URL the picker hands over is only good for this launch. What survives is a
/// security-scoped bookmark, which has to be resolved and then *opened* before
/// anything can be written — and left open for as long as the app runs, since
/// the engine writes continuously rather than in one burst.
enum DownloadFolder {

	private static let bookmarkKey = "cz.jannovy.iTorrent.downloadFolderBookmark"

	/// The open security-scoped URL, kept so access can be closed again when
	/// the choice changes. Unbalanced access leaks a resource for the lifetime
	/// of the process.
	private static var openedURL: URL?

	/// `Documents/Downloads`, which is what the app uses unless told otherwise.
	/// It needs no bookmark and is the folder visible in Files under
	/// "On My iPhone → iTorrent".
	static var defaultURL: URL {
		FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Downloads", isDirectory: true)
	}

	static var isUsingDefault: Bool {
		UserDefaults.standard.data(forKey: bookmarkKey) == nil
	}

	/// The folder to start the session with, or nil to use the default.
	///
	/// A bookmark can go stale — the folder was renamed, moved, or lives on a
	/// share that is not mounted — and there is nothing useful to do about it
	/// beyond saying so, so the caller is told rather than silently falling
	/// back to a folder the user did not choose.
	static func restore() throws -> URL? {
		guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }

		var isStale = false
		let url: URL
		do {
			url = try URL(
				resolvingBookmarkData: data,
				options: [],
				relativeTo: nil,
				bookmarkDataIsStale: &isStale
			)
		} catch {
			forget()
			throw DownloadFolderError.unresolvable(error.localizedDescription)
		}

		guard open(url) else {
			forget()
			throw DownloadFolderError.inaccessible(url.lastPathComponent)
		}
		// A stale bookmark still resolved, so re-record it while the folder is
		// open and the app has the right to make one.
		if isStale { try? remember(url) }
		return url
	}

	/// Records a folder the user just picked. The URL must still be open.
	static func remember(_ url: URL) throws {
		let data: Data
		do {
			data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
		} catch {
			throw DownloadFolderError.unbookmarkable(error.localizedDescription)
		}
		UserDefaults.standard.set(data, forKey: bookmarkKey)
	}

	/// Opens access to a folder the picker returned and keeps it open.
	@discardableResult
	static func open(_ url: URL) -> Bool {
		if let openedURL, openedURL != url {
			openedURL.stopAccessingSecurityScopedResource()
		}
		// A URL inside our own sandbox is not security-scoped and returns
		// false here, which is not a failure: it needs no permission at all.
		let granted = url.startAccessingSecurityScopedResource()
		openedURL = granted ? url : nil
		return granted || url.path.hasPrefix(defaultURL.deletingLastPathComponent().path)
	}

	/// Goes back to the folder inside the app's own Documents.
	static func forget() {
		openedURL?.stopAccessingSecurityScopedResource()
		openedURL = nil
		UserDefaults.standard.removeObject(forKey: bookmarkKey)
	}
}

enum DownloadFolderError: LocalizedError {
	case unresolvable(String)
	case inaccessible(String)
	case unbookmarkable(String)

	var errorDescription: String? {
		switch self {
		case let .unresolvable(reason):
			"The download folder could not be found again (\(reason)). Downloads will go to iTorrent's own folder."
		case let .inaccessible(name):
			"iTorrent no longer has permission to write to '\(name)'. Downloads will go to its own folder."
		case let .unbookmarkable(reason):
			"That folder cannot be remembered for next time (\(reason))."
		}
	}
}
