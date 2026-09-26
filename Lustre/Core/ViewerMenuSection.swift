//
//  ViewerMenuSection.swift
//  Lustre
//
//  The collapsible sections of the Viewer's control menu. In Core rather than
//  the Viewer so `AppPreferences` can remember which one was open without a
//  Services → Viewer dependency.
//

import Foundation

nonisolated enum ViewerMenuSection: String, Hashable, Identifiable, CaseIterable, Sendable {
    case placement, orientation, position, display, performance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .placement: "Scale"
        case .orientation: "Orientation"
        case .position: "Position"
        case .display: "Display"
        case .performance: "Performance"
        }
    }

    var systemImage: String {
        switch self {
        case .placement: "arrow.up.left.and.arrow.down.right"
        case .orientation: "rotate.3d"
        case .position: "move.3d"
        case .display: "photo"
        case .performance: "speedometer"
        }
    }
}
