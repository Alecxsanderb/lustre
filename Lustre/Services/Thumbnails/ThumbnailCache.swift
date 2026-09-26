//
//  ThumbnailCache.swift
//  Lustre
//
//  On-disk thumbnail store: `<key>.jpg` for a rendered thumbnail, or
//  `<key>.failed` when the file couldn't be read, so a damaged splat isn't
//  re-parsed every time its tile scrolls into view. Lives in Caches because
//  every entry can be regenerated from the splat itself.
//
//  Stateless apart from the directory, and FileManager is thread-safe for
//  these calls, so it's safe to use from any task.
//

import Foundation

nonisolated struct ThumbnailCache: Sendable {

    enum Entry: Equatable {
        case image(URL)
        case failed
        case missing
    }

    static let imageExtension = "jpg"
    static let failureExtension = "failed"

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// `Caches/Thumbnails/`.
    static var defaultDirectory: URL {
        URL.cachesDirectory.appending(path: "Thumbnails", directoryHint: .isDirectory)
    }

    func imageURL(for key: ThumbnailKey) -> URL {
        directory.appending(path: key.hash).appendingPathExtension(Self.imageExtension)
    }

    private func failureURL(for key: ThumbnailKey) -> URL {
        directory.appending(path: key.hash).appendingPathExtension(Self.failureExtension)
    }

    func lookup(_ key: ThumbnailKey) -> Entry {
        let fileManager = FileManager.default
        let image = imageURL(for: key)
        if fileManager.fileExists(atPath: image.path) { return .image(image) }
        if fileManager.fileExists(atPath: failureURL(for: key).path) { return .failed }
        return .missing
    }

    /// Stores a rendered thumbnail, replacing any failure marker for the key.
    func write(jpegData: Data, for key: ThumbnailKey) throws {
        try ensureDirectory()
        // Atomic so a reader never sees a half-written JPEG.
        try jpegData.write(to: imageURL(for: key), options: .atomic)
        try? FileManager.default.removeItem(at: failureURL(for: key))
    }

    /// Records that the file behind `key` couldn't be thumbnailed. The key
    /// includes size and mtime, so replacing the file retries automatically.
    func markFailed(_ key: ThumbnailKey) throws {
        try ensureDirectory()
        try Data().write(to: failureURL(for: key), options: .atomic)
    }

    /// Carries an entry across a rename. The rename changes the key (the name
    /// is part of it) but not the contents, so re-rendering would be waste.
    /// Missing entries are fine: there's nothing to move.
    func move(from oldKey: ThumbnailKey, to newKey: ThumbnailKey) throws {
        guard oldKey != newKey else { return }
        let pairs = [(imageURL(for: oldKey), imageURL(for: newKey)),
                     (failureURL(for: oldKey), failureURL(for: newKey))]
        let fileManager = FileManager.default
        for (source, destination) in pairs where fileManager.fileExists(atPath: source.path) {
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    func remove(_ key: ThumbnailKey) {
        try? FileManager.default.removeItem(at: imageURL(for: key))
        try? FileManager.default.removeItem(at: failureURL(for: key))
    }

    /// Deletes every entry whose key isn't in `liveKeys`: deleted splats,
    /// files changed on disk (Files app edits), and old renderer versions.
    /// Only touches files this cache wrote, so anything else in the folder
    /// (an in-flight atomic write's temp file) is left alone.
    @discardableResult
    func sweep(keeping liveKeys: Set<ThumbnailKey>) -> Int {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: directory,
                                                                   includingPropertiesForKeys: nil) else {
            return 0
        }
        let live = Set(liveKeys.map(\.hash))
        var removed = 0
        for url in contents {
            let fileExtension = url.pathExtension
            guard fileExtension == Self.imageExtension || fileExtension == Self.failureExtension else { continue }
            guard !live.contains(url.deletingPathExtension().lastPathComponent) else { continue }
            if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
