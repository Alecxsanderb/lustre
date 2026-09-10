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

    /// Collapsed by default so the splat is unobstructed on first look.
    var isMenuExpanded = false

    /// One section open at a time; the menu would otherwise cover the view.
    var expandedSection: Section? = .placement

    var areGesturesEnabled = true

    /// One two-finger gesture changes one thing. Off by default because the
    /// combined gesture is faster once you're used to it; on, it's far easier
    /// to make a small correction without disturbing scale and rotation.
    var locksToSingleAxis = false

    /// Axis bars and surface outlines. Off by default — they drive plane
    /// detection, which costs CPU every frame.
    var showsPlacementIndicators = false

    /// Notches at real-world intervals along the axis bars. Only drawn when
    /// the indicators are on, since they're marks *on* those bars.
    var showsMeasuringTicks = true

    var rulerUnits: RulerUnits = .meters

    /// Hide splats that sit behind a detected real surface. Off by default: it
    /// needs surface detection *and* the camera background, and it's only as
    /// good as ARKit's plane estimate.
    var occludesBehindSurfaces = false

    /// How much of a file to load. Applied on the next load, so changing it
    /// re-reads the current splat.
    var quality: SplatQuality = .full

    /// Pitch and roll are hidden until asked for. Yaw covers almost every real
    /// capture, and three rotation sliders reads as a debug panel.
    var showsAdvancedRotation = false

    /// Camera by default: the point of the viewer is a splat sitting in your
    /// room, and a black background hides that. Falls back to black
    /// automatically wherever no camera frames exist.
    var background: Background = .camera

    func toggle(_ section: Section) {
        expandedSection = (expandedSection == section) ? nil : section
    }
}
