//
//  SplatLibrary.swift
//  Lustre
//
//  The on-disk splat library: `Documents/Splats/`, visible in Files as
//  "Lustre › Splats". The folder is the source of truth — a file dropped in
//  through Files shows up on the next refresh, and one deleted there drops
//  out. A small index in Application Support holds what the file system
//  can't: where the splat came from and when it was last opened.
//
//  Imports are copied here rather than into Caches: Caches can be purged
//  under storage pressure, which would silently empty the Library.
//

import Foundation
import Observation

@MainActor
@Observable
final class SplatLibrary {

    /// Per-file metadata the file system doesn't carry, keyed by file name.
    private struct IndexEntry: Codable {
        var source: SplatItem.Source
        var dateAdded: Date
        var lastOpened: Date?
    }

    enum ImportError: LocalizedError {
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .copyFailed(let name): return "Couldn't copy \(name) into the Library."
            }
        }
    }

    /// Unsorted; each view orders it for itself.
    private(set) var items: [SplatItem] = []
    private(set) var isImporting = false

    /// Set when the folder itself couldn't be created or read, which leaves
    /// the whole Library unusable rather than one item.
    private(set) var storageError: String?

    let folderURL: URL
    private let indexURL: URL
    private var index: [String: IndexEntry] = [:]

    init(folderURL: URL = SplatLibrary.defaultFolderURL,
         indexURL: URL = SplatLibrary.defaultIndexURL) {
        self.folderURL = folderURL
        self.indexURL = indexURL
        index = Self.readIndex(at: indexURL)
        refresh()
    }

    nonisolated static var defaultFolderURL: URL {
        URL.documentsDirectory.appending(path: "Splats", directoryHint: .isDirectory)
    }

    nonisolated static var defaultIndexURL: URL {
        URL.applicationSupportDirectory.appending(path: "LibraryIndex.json")
    }

    /// Up to `limit` items, most recently opened or added first.
    func recentItems(limit: Int) -> [SplatItem] {
        Array(items.sorted { $0.lastActivity > $1.lastActivity }.prefix(limit))
    }

    // MARK: - Scanning

    /// Re-reads the folder. Cheap — a directory listing and a stat per file —
    /// so it runs on the main actor.
    func refresh() {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let urls = try fileManager.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])
            storageError = nil
            items = urls.compactMap(makeItem)
        } catch {
            storageError = "Couldn't read the Library folder: \(error.localizedDescription)"
            items = []
            return
        }

        // Entries for files deleted through Files. Pruned so a later file with
        // the same name doesn't inherit a stale source or open date.
        let present = Set(items.map(\.url.lastPathComponent))
        let stale = index.keys.filter { !present.contains($0) }
        if !stale.isEmpty {
            stale.forEach { index.removeValue(forKey: $0) }
            writeIndex()
        }
    }

    private func makeItem(for url: URL) -> SplatItem? {
        guard SplatFileIO.readableExtensions.contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }

        // A file dropped in through Files has no entry; it was imported, just
        // not by us, and its creation date is the best "added" date there is.
        let entry = index[url.lastPathComponent]
        return SplatItem(url: url,
                         source: entry?.source ?? .imported,
                         dateAdded: entry?.dateAdded ?? values.creationDate ?? .now,
                         fileSize: Int64(values.fileSize ?? 0),
                         lastOpened: entry?.lastOpened)
    }

    // MARK: - Mutations

    /// Copies each file into the library. Returns one message per file that
    /// was skipped; the rest import regardless.
    @discardableResult
    func importFiles(_ urls: [URL]) async -> [String] {
        guard !isImporting else { return [] }
        isImporting = true
        defer { isImporting = false }

        let readable = SplatFileIO.readableExtensions
        let unsupported = SplatFileIO.recognizedButUnsupportedExtensions
        let folder = folderURL
        // Off the main actor: captures run to hundreds of megabytes, and the
        // copy would freeze the UI for the whole transfer.
        let results = await Task.detached(priority: .userInitiated) {
            urls.map { url in
                Result { try Self.copyIntoLibrary(url, folder: folder,
                                                  readable: readable, unsupported: unsupported) }
            }
        }.value

        var failures: [String] = []
        for result in results {
            switch result {
            case .success(let fileName):
                index[fileName] = IndexEntry(source: .imported, dateAdded: .now, lastOpened: nil)
            case .failure(let error):
                failures.append(error.localizedDescription)
            }
        }
        writeIndex()
        refresh()
        return failures
    }

    /// Copies to a temporary file first and moves it in at the end, so a
    /// refresh mid-copy never lists a half-written splat. Returns the final
    /// file name.
    private nonisolated static func copyIntoLibrary(_ source: URL,
                                                    folder: URL,
                                                    readable: [String],
                                                    unsupported: [String]) throws -> String {
        let fileExtension = source.pathExtension.lowercased()
        // Rejected here rather than on open: a file the Viewer can never read
        // shouldn't take up a spot in the Library.
        guard !unsupported.contains(fileExtension) else {
            throw SplatFileIO.LoadError.notYetSupported(source)
        }
        guard readable.contains(fileExtension) else {
            throw SplatFileIO.LoadError.unsupportedFormat(source)
        }

        // Document-picker URLs are security scoped; no-op for anything else.
        let needsScopedAccess = source.startAccessingSecurityScopedResource()
        defer { if needsScopedAccess { source.stopAccessingSecurityScopedResource() } }

        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension(fileExtension)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: staging)
            let fileName = SplatFileNaming.uniqueFileName(
                base: source.deletingPathExtension().lastPathComponent,
                fileExtension: fileExtension) { candidate in
                    fileManager.fileExists(atPath: folder.appending(path: candidate).path)
                }
            try fileManager.moveItem(at: staging, to: folder.appending(path: fileName))
            return fileName
        } catch {
            try? fileManager.removeItem(at: staging)
            throw ImportError.copyFailed(source.lastPathComponent)
        }
    }

    func delete(_ item: SplatItem) throws {
        try FileManager.default.removeItem(at: item.url)
        index.removeValue(forKey: item.url.lastPathComponent)
        writeIndex()
        refresh()
    }

    /// Renames the file itself, so the new name shows in Files too. The
    /// extension is kept; it's what tells the reader the format.
    @discardableResult
    func rename(_ item: SplatItem, to proposedName: String) throws -> SplatItem {
        let name = try SplatFileNaming.validatedName(proposedName)
        guard name != item.name else { return item }

        let oldFileName = item.url.lastPathComponent
        let newFileName = item.url.pathExtension.isEmpty ? name : "\(name).\(item.url.pathExtension)"
        let destination = folderURL.appending(path: newFileName)
        // A case-only rename is the same file on a case-insensitive volume, so
        // it isn't a collision.
        if FileManager.default.fileExists(atPath: destination.path),
           newFileName.lowercased() != oldFileName.lowercased() {
            throw SplatFileNaming.RenameError.alreadyExists(name)
        }
        try FileManager.default.moveItem(at: item.url, to: destination)

        if let entry = index.removeValue(forKey: oldFileName) {
            index[newFileName] = entry
        }
        writeIndex()
        refresh()
        return items.first { $0.url.lastPathComponent == newFileName } ?? item
    }

    func markOpened(_ item: SplatItem) {
        let fileName = item.url.lastPathComponent
        var entry = index[fileName]
            ?? IndexEntry(source: item.source, dateAdded: item.dateAdded, lastOpened: nil)
        entry.lastOpened = .now
        index[fileName] = entry
        writeIndex()
        // In place rather than `refresh()`: this runs as the Viewer is pushed,
        // and nothing on disk changed that a rescan would pick up.
        if let position = items.firstIndex(where: { $0.url == item.url }) {
            let current = items[position]
            items[position] = SplatItem(url: current.url, source: current.source,
                                        dateAdded: current.dateAdded, fileSize: current.fileSize,
                                        lastOpened: entry.lastOpened)
        }
    }

    // MARK: - Index persistence

    private static func readIndex(at url: URL) -> [String: IndexEntry] {
        // Missing or corrupt both mean "start over": the files are still
        // there, and only sources and open dates are lost.
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode([String: IndexEntry].self, from: data) else {
            return [:]
        }
        return index
    }

    private func writeIndex() {
        do {
            try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
        } catch {
            // Not surfaced: losing the index costs recents ordering, not files.
            print("SplatLibrary: couldn't write index: \(error)")
        }
    }
}
