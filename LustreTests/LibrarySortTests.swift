//
//  LibrarySortTests.swift
//  LustreTests
//

import Foundation
import Testing
@testable import Lustre

/// `LibrarySort` has no `nonisolated`, so it's MainActor under the app's
/// default isolation.
@MainActor
struct LibrarySortTests {

    private static func item(_ name: String, added: TimeInterval, size: Int64) -> SplatItem {
        SplatItem(url: URL(fileURLWithPath: "/Splats/\(name).ply"),
                  source: .imported,
                  dateAdded: Date(timeIntervalSinceReferenceDate: added),
                  fileSize: size,
                  lastOpened: nil)
    }

    private let items = [
        item("Scan 2", added: 100, size: 5_000),
        item("scan 10", added: 300, size: 1_000),
        item("Attic", added: 200, size: 9_000),
    ]

    @Test func dateAddedIsNewestFirst() {
        #expect(LibrarySort.dateAdded.sorted(items).map(\.name) == ["scan 10", "Attic", "Scan 2"])
    }

    @Test func nameIsFinderOrder() {
        // Case-insensitive, and numbers compare numerically: 2 before 10.
        #expect(LibrarySort.name.sorted(items).map(\.name) == ["Attic", "Scan 2", "scan 10"])
    }

    @Test func sizeIsLargestFirst() {
        #expect(LibrarySort.size.sorted(items).map(\.name) == ["Attic", "Scan 2", "scan 10"])
    }

    @Test("Empty input stays empty", arguments: LibrarySort.allCases)
    func empty(sort: LibrarySort) {
        #expect(sort.sorted([]).isEmpty)
    }
}
