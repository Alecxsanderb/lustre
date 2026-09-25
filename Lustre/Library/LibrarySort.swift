//
//  LibrarySort.swift
//  Lustre
//

import Foundation

enum LibrarySort: String, CaseIterable, Identifiable {
    case dateAdded
    case name
    case size

    var id: Self { self }

    var title: String {
        switch self {
        case .dateAdded: "Date Added"
        case .name: "Name"
        case .size: "Size"
        }
    }

    /// Each order's natural direction: newest, A–Z, largest.
    func sorted(_ items: [SplatItem]) -> [SplatItem] {
        switch self {
        case .dateAdded:
            items.sorted { $0.dateAdded > $1.dateAdded }
        case .name:
            items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            items.sorted { $0.fileSize > $1.fileSize }
        }
    }
}
