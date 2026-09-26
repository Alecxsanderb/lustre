//
//  SplatLibraryThumbnailTests.swift
//  LustreTests
//
//  The library keeps the thumbnail cache in step with the folder: a rename
//  carries the thumbnail to the new key, and a refresh sweeps entries for
//  files that are gone.
//

import Foundation
import Testing
@testable import Lustre

@MainActor
struct SplatLibraryThumbnailTests {

    private struct Fixture {
        let root: TemporaryDirectory
        let folder: URL
        let cache: ThumbnailCache

        init() throws {
            root = try TemporaryDirectory()
            folder = root.url.appending(path: "Splats", directoryHint: .isDirectory)
            cache = ThumbnailCache(directory: root.url.appending(path: "Thumbnails"))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        func addFile(_ name: String) throws {
            try Data(repeating: 1, count: 64).write(to: folder.appending(path: name))
        }

        @MainActor
        func makeLibrary() -> SplatLibrary {
            SplatLibrary(folderURL: folder,
                         indexURL: root.url.appending(path: "index.json"),
                         thumbnailCache: cache)
        }
    }

    @Test func itemsCarryTheFileModificationDate() throws {
        let fixture = try Fixture()
        defer { fixture.root.remove() }
        try fixture.addFile("room.ply")
        let modified = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified],
                                              ofItemAtPath: fixture.folder.appending(path: "room.ply").path)

        let item = try #require(fixture.makeLibrary().items.first)
        #expect(item.modificationDate == modified)
        // So the key built from the item matches the one built from the file.
        #expect(ThumbnailKey(item: item)
                == (try ThumbnailKey(fileURL: item.url, rendererVersion: ThumbnailRenderer.version)))
    }

    @Test func renameMovesTheThumbnail() async throws {
        let fixture = try Fixture()
        defer { fixture.root.remove() }
        try fixture.addFile("room.ply")
        let library = fixture.makeLibrary()
        let item = try #require(library.items.first)
        // Deliberately not waiting for init's sweep: its stale snapshot must
        // not be able to delete the entry the rename moves.
        try fixture.cache.write(jpegData: Data([0xFF, 0xD8]), for: ThumbnailKey(item: item))

        let renamed = try library.rename(item, to: "Kitchen")
        await library.waitForThumbnailMaintenance()

        guard case .image = fixture.cache.lookup(ThumbnailKey(item: renamed)) else {
            Issue.record("thumbnail didn't follow the rename"); return
        }
        #expect(fixture.cache.lookup(ThumbnailKey(item: item)) == .missing)
    }

    @Test func refreshSweepsOrphans() async throws {
        let fixture = try Fixture()
        defer { fixture.root.remove() }
        try fixture.addFile("keep.ply")
        try fixture.addFile("gone.ply")
        let library = fixture.makeLibrary()
        await library.waitForThumbnailMaintenance()
        for item in library.items {
            try fixture.cache.write(jpegData: Data([0xFF, 0xD8]), for: ThumbnailKey(item: item))
        }
        let gone = try #require(library.items.first { $0.name == "gone" })
        let keep = try #require(library.items.first { $0.name == "keep" })

        try FileManager.default.removeItem(at: gone.url)
        library.refresh()
        await library.waitForThumbnailMaintenance()

        #expect(fixture.cache.lookup(ThumbnailKey(item: gone)) == .missing)
        guard case .image = fixture.cache.lookup(ThumbnailKey(item: keep)) else {
            Issue.record("live thumbnail was swept"); return
        }
    }
}
