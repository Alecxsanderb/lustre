//
//  ViewerUIState.swift
//  Lustre
//
//  Viewer chrome state. Deliberately separate from `SplatSceneState`, which is
//  read by the render loop every frame and is what a saved placement would
//  serialize — a "menu is open" flag has no business in that record.
//

import Foundation
import Observation

@MainActor
@Observable
final class ViewerUIState {

    enum Background: String, CaseIterable, Identifiable {
        case black
        case camera

        var id: String { rawValue }

        var title: String {
            switch self {
            case .black: "Black"
            case .camera: "Camera"
            }
        }

        var systemImage: String {
            switch self {
            case .black: "square.fill"
            case .camera: "camera.fill"
            }
        }
    }

    enum Section: String, Hashable, Identifiable, CaseIterable {
        case placement, orientation, position, display

        var id: String { rawValue }

        var title: String {
            switch self {
            case .placement: "Scale"
            case .orientation: "Orientation"
            case .position: "Position"
            case .display: "Display"
            }
        }

        var systemImage: String {
            switch self {
            case .placement: "arrow.up.left.and.arrow.down.right"
            case .orientation: "rotate.3d"
            case .position: "move.3d"
            case .display: "photo"
            }
        }
    }

    /// Collapsed by default so the splat is unobstructed on first look.
    var isMenuExpanded = false

    /// One section open at a time; the menu would otherwise cover the view.
    var expandedSection: Section? = .placement

    var areGesturesEnabled = true

    /// Pitch and roll are hidden until asked for. Yaw covers almost every real
    /// capture, and three rotation sliders reads as a debug panel.
    var showsAdvancedRotation = false

    var background: Background = .black

    func toggle(_ section: Section) {
        expandedSection = (expandedSection == section) ? nil : section
    }
}
