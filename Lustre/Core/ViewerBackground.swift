//
//  ViewerBackground.swift
//  Lustre
//
//  What the Viewer draws behind the splat. In Core rather than the Viewer so
//  `AppPreferences` can store it without a Services → Viewer dependency.
//

import Foundation

nonisolated enum ViewerBackground: String, CaseIterable, Identifiable, Sendable {
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
