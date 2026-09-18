import Foundation

public enum StorageError: Error, LocalizedError {
	case cannotCreateDirectory(String)
	case cannotOpenFile(String)
	case writeFailed(String)
	case readFailed(String)
	case outOfBounds

	public var errorDescription: String? {
		switch self {
		case let .cannotCreateDirectory(path): "Could not create the directory at \(path)."
		case let .cannotOpenFile(path): "Could not open \(path)."
		case let .writeFailed(path): "Writing to \(path) failed."
		case let .readFailed(path): "Reading from \(path) failed."
		case .outOfBounds: "The requested range lies outside the torrent."
		}
	}
}

/// Maps the torrent's flat byte stream onto real files on disk.
///
/// Files are created sparse and written at offsets as pieces arrive, so a
/// half-finished download occupies only the bytes actually received — which
/// matters a great deal on a device where the user can run out of space
/// mid-download.
public actor TorrentStorage {
	/// iOS processes have a modest file-descriptor budget, and a torrent can
	/// contain thousands of files, so handles are pooled.
	private static let maximumOpenHandles = 24

	private let metainfo: TorrentMetainfo
	private let rootURL: URL
	private var handles: [Int: FileHandle] = [:]
	private var handleUse: [Int] = []
	private var skippedFileIndices: Set<Int> = []

	public init(metainfo: TorrentMetainfo, downloadDirectory: URL) {
		self.metainfo = metainfo
		// Multi-file torrents get their own folder; single-file torrents are
		// written straight into the download directory.
		self.rootURL = metainfo.isMultiFile
			? downloadDirectory.appendingPathComponent(Self.sanitise(metainfo.name), isDirectory: true)
			: downloadDirectory
	}

	public var contentURL: URL {
		metainfo.isMultiFile ? rootURL : rootURL.appendingPathComponent(metainfo.files[0].relativePath)
	}

	public func setSkippedFiles(_ indices: Set<Int>) {
		skippedFileIndices = indices
	}

	public func url(for file: TorrentFile) -> URL {
		file.path.reduce(rootURL) { $0.appendingPathComponent(Self.sanitise($1)) }
	}

	// MARK: - Writing

	public func write(piece index: Int, data: Data) throws {
		let range = metainfo.byteRange(ofPiece: index)
		guard data.count == Int(range.upperBound - range.lowerBound) else { throw StorageError.outOfBounds }

		for (file, fileRange, dataRange) in segments(for: range) {
			guard !file.isPadding, !skippedFileIndices.contains(file.index) else { continue }
			let handle = try handle(for: file)
			do {
				try handle.seek(toOffset: UInt64(fileRange.lowerBound))
				try handle.write(contentsOf: data.subdata(in: dataRange))
			} catch {
				throw StorageError.writeFailed(url(for: file).path)
			}
		}
	}

	public func read(_ request: BlockRequest) throws -> Data {
		let pieceStart = Int64(request.pieceIndex) * Int64(metainfo.pieceLength)
		let start = pieceStart + Int64(request.begin)
		let range = start..<(start + Int64(request.length))
		guard range.upperBound <= metainfo.totalLength else { throw StorageError.outOfBounds }

		var output = Data(count: request.length)
		for (file, fileRange, dataRange) in segments(for: range) {
			guard !file.isPadding else { continue }
			let handle = try handle(for: file)
			do {
				try handle.seek(toOffset: UInt64(fileRange.lowerBound))
				let chunk = try handle.read(upToCount: dataRange.count) ?? Data()
				guard chunk.count == dataRange.count else { throw StorageError.readFailed(url(for: file).path) }
				output.replaceSubrange(dataRange, with: chunk)
			} catch {
				throw StorageError.readFailed(url(for: file).path)
			}
		}
		return output
	}

	public func flush() {
		for handle in handles.values { try? handle.synchronize() }
	}

	public func close() {
		for handle in handles.values { try? handle.close() }
		handles.removeAll()
		handleUse.removeAll()
	}

	public func deleteFiles() {
		close()
		let manager = FileManager.default
		if metainfo.isMultiFile {
			try? manager.removeItem(at: rootURL)
		} else {
			for file in metainfo.files {
				try? manager.removeItem(at: url(for: file))
			}
		}
	}

	/// Bytes actually present on disk, used to show per-file progress and to
	/// sanity-check resume data against a user who deleted files behind our back.
	public func bytesOnDisk(for file: TorrentFile) -> Int64 {
		let path = url(for: file).path
		guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
		      let size = attributes[.size] as? NSNumber
		else { return 0 }
		return size.int64Value
	}

	public func anyFileExists() -> Bool {
		metainfo.contentFiles.contains { FileManager.default.fileExists(atPath: url(for: $0).path) }
	}

	// MARK: - File mapping

	/// Splits a global byte range into per-file segments: the file, the byte
	/// range inside that file, and the matching slice of the caller's buffer.
	private func segments(for range: Range<Int64>) -> [(TorrentFile, Range<Int64>, Range<Int>)] {
		var result: [(TorrentFile, Range<Int64>, Range<Int>)] = []
		for file in metainfo.files where file.length > 0 {
			let fileRange = file.range
			let overlapStart = max(range.lowerBound, fileRange.lowerBound)
			let overlapEnd = min(range.upperBound, fileRange.upperBound)
			guard overlapStart < overlapEnd else { continue }

			let insideFile = (overlapStart - fileRange.lowerBound)..<(overlapEnd - fileRange.lowerBound)
			let insideBuffer = Int(overlapStart - range.lowerBound)..<Int(overlapEnd - range.lowerBound)
			result.append((file, insideFile, insideBuffer))
		}
		return result
	}

	private func handle(for file: TorrentFile) throws -> FileHandle {
		if let existing = handles[file.index] {
			touch(file.index)
			return existing
		}

		let fileURL = url(for: file)
		let manager = FileManager.default
		let directory = fileURL.deletingLastPathComponent()
		if !manager.fileExists(atPath: directory.path) {
			do {
				try manager.createDirectory(at: directory, withIntermediateDirectories: true)
			} catch {
				throw StorageError.cannotCreateDirectory(directory.path)
			}
		}
		if !manager.fileExists(atPath: fileURL.path) {
			guard manager.createFile(atPath: fileURL.path, contents: nil) else {
				throw StorageError.cannotOpenFile(fileURL.path)
			}
			// Torrent data must not go into iCloud backups; Apple rejects apps
			// that back up re-downloadable content.
			var resourceValues = URLResourceValues()
			resourceValues.isExcludedFromBackup = true
			var mutableURL = fileURL
			try? mutableURL.setResourceValues(resourceValues)
		}

		guard let handle = try? FileHandle(forUpdating: fileURL) else {
			throw StorageError.cannotOpenFile(fileURL.path)
		}

		if handles.count >= Self.maximumOpenHandles, let evicted = handleUse.first {
			handleUse.removeFirst()
			try? handles.removeValue(forKey: evicted)?.close()
		}
		handles[file.index] = handle
		handleUse.append(file.index)
		return handle
	}

	private func touch(_ index: Int) {
		if let position = handleUse.firstIndex(of: index) {
			handleUse.remove(at: position)
		}
		handleUse.append(index)
	}

	private static func sanitise(_ component: String) -> String {
		component.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
	}
}
