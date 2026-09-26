//
//  ThumbnailCacheTests.swift
//  LustreTests
//

import Foundation
import Testing
@testable import Lustre

struct ThumbnailKeyTests {

    private let date = Date(timeIntervalSince1970: 1_700_000_000.25)

    private func key(name: String = "room.ply", size: Int64 = 1_000,
                     date: Date? = nil, version: Int = 1) -> ThumbnailKey {
        ThumbnailKey(fileName: name, fileSize: size, modificationDate: date ?? self.date,
                     rendererVersion: version)
    }

    @Test func stableForSameInputs() {
        #expect(key() == key())
        #expect(key().hash.count == 64)
        #expect(key().hash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test func changesWithEachInput() {
        let base = key()
        #expect(key(name: "room 2.ply") != base)
        #expect(key(size: 1_001) != base)
        #expect(key(date: date.addingTimeInterval(0.001)) != base)
        #expect(key(version: 2) != base)
    }

    @Test func readsFromFile() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "scan.spz")
        try Data(repeating: 7, count: 123).write(to: file)
        let modified = Date(timeIntervalSince1970: 1_650_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)

        let fromFile = try ThumbnailKey(fileURL: file, rendererVersion: 3)
        #expect(fromFile == ThumbnailKey(fileName: "scan.spz", fileSize: 123,
                                         modificationDate: modified, rendererVersion: 3))
    }
}

struct ThumbnailCacheTests {

    private func key(_ name: String) -> ThumbnailKey {
        ThumbnailKey(fileName: name, fileSize: 10, modificationDate: Date(timeIntervalSince1970: 0),
                     rendererVersion: 1)
    }

    @Test func missingBeforeAnyWrite() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        // The directory doesn't exist yet: the cache creates it on first write.
        let cache = ThumbnailCache(directory: directory.url.appending(path: "Thumbnails"))
        #expect(cache.lookup(key("a.ply")) == .missing)
        #expect(cache.sweep(keeping: []) == 0)
    }

    @Test func writeThenRead() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let cache = ThumbnailCache(directory: directory.url.appending(path: "Thumbnails"))
        let data = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try cache.write(jpegData: data, for: key("a.ply"))

        guard case .image(let url) = cache.lookup(key("a.ply")) else {
            Issue.record("expected an image entry"); return
        }
        #expect(url.pathExtension == "jpg")
        #expect(try Data(contentsOf: url) == data)
        #expect(cache.lookup(key("b.ply")) == .missing)
    }

    @Test func failureMarkerAndRecovery() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let cache = ThumbnailCache(directory: directory.url)
        try cache.markFailed(key("broken.ply"))
        #expect(cache.lookup(key("broken.ply")) == .failed)

        // A later successful render replaces the marker.
        try cache.write(jpegData: Data([1]), for: key("broken.ply"))
        #expect(cache.lookup(key("broken.ply")) == .image(cache.imageURL(for: key("broken.ply"))))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
        #expect(leftovers.filter { $0.hasSuffix(".failed") }.isEmpty)
    }

    @Test func moveCarriesImageAndMarker() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let cache = ThumbnailCache(directory: directory.url)
        try cache.write(jpegData: Data([1, 2]), for: key("old.ply"))
        try cache.markFailed(key("oldbad.ply"))

        try cache.move(from: key("old.ply"), to: key("new.ply"))
        try cache.move(from: key("oldbad.ply"), to: key("newbad.ply"))
        // Nothing to move is not an error.
        try cache.move(from: key("never.ply"), to: key("still-never.ply"))

        #expect(cache.lookup(key("old.ply")) == .missing)
        #expect(try Data(contentsOf: cache.imageURL(for: key("new.ply"))) == Data([1, 2]))
        #expect(cache.lookup(key("oldbad.ply")) == .missing)
        #expect(cache.lookup(key("newbad.ply")) == .failed)
    }

    @Test func moveOverwritesStaleDestination() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let cache = ThumbnailCache(directory: directory.url)
        try cache.write(jpegData: Data([1]), for: key("a.ply"))
        try cache.write(jpegData: Data([2]), for: key("b.ply"))
        try cache.move(from: key("a.ply"), to: key("b.ply"))
        #expect(try Data(contentsOf: cache.imageURL(for: key("b.ply"))) == Data([1]))
    }

    @Test func sweepRemovesOrphansOnly() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let cache = ThumbnailCache(directory: directory.url)
        try cache.write(jpegData: Data([1]), for: key("keep.ply"))
        try cache.markFailed(key("keep-bad.ply"))
        try cache.write(jpegData: Data([1]), for: key("gone.ply"))
        try cache.markFailed(key("gone-bad.ply"))
        // Not ours: left alone.
        let foreign = directory.url.appending(path: "notes.txt")
        try Data([1]).write(to: foreign)

        let removed = cache.sweep(keeping: [key("keep.ply"), key("keep-bad.ply")])

        #expect(removed == 2)
        #expect(cache.lookup(key("keep.ply")) != .missing)
        #expect(cache.lookup(key("keep-bad.ply")) == .failed)
        #expect(cache.lookup(key("gone.ply")) == .missing)
        #expect(cache.lookup(key("gone-bad.ply")) == .missing)
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }
}

/// A fresh directory under the test's temp folder. Removed explicitly with
/// `defer` rather than in a deinit, which ARC may run before the last use of
/// `url` is done with the directory.
struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "LustreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
