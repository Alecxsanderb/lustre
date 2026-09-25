//
//  ViewerContent.swift
//  Lustre
//
//  What the Viewer was asked to show. The Viewer's public input — the App
//  layer builds one from a Library item, so the Viewer never sees Library
//  types.
//

import Foundation

enum ViewerContent: Hashable {
    /// The procedurally generated room, for a first launch with nothing
    /// imported and for exercising the renderer in the simulator.
    case sample
    case file(URL, name: String)
}
