//
//  SplatItem.swift
//  Lustre
//
//  One splat in the Library. Shared by Home and Library, which is why it lives
//  in Core rather than in either feature.
//

import Foundation

nonisolated struct SplatItem: Identifiable, Hashable, Sendable {

    /// Where the splat came from. Everything is `.imported` until Capture
    /// exists; the distinction is stored now so captures don't need a
    /// migration later.
    enum Source: String, Codable, Sendable {
        case captured
        case imported
    }

    /// The on-disk file, which is also the identity: the file name is unique
    /// within the library folder, and renaming changes both.
    let url: URL
    let source: Source
    let dateAdded: Date
    let fileSize: Int64
    let lastOpened: Date?

    var id: URL { url }

    /// The file name without its extension — renaming edits exactly this.
    var name: String { url.deletingPathExtension().lastPathComponent }

    /// Uppercased extension for display, e.g. "PLY".
    var formatLabel: String { url.pathExtension.uppercased() }

    /// What Home orders its row by: a splat you just imported counts as recent
    /// even before you've opened it.
    var lastActivity: Date { max(lastOpened ?? dateAdded, dateAdded) }
}
