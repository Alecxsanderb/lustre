//
//  SplatQuality.swift
//  Lustre
//
//  How many splats to keep from a file.
//
//  Applied at load, because the alternative — holding the parsed points so the
//  budget can change without re-reading the file — costs a full second copy of
//  the point data. At 5M splats that's hundreds of megabytes on a device with
//  2–4 GB usable, so changing this re-reads instead.
//

import Foundation

nonisolated enum SplatQuality: String, CaseIterable, Identifiable, Sendable {
    case full
    case balanced
    case performance

    var id: String { rawValue }

    /// Maximum splats to keep. Points above it are strided out uniformly.
    var budget: Int {
        switch self {
        case .full: .max
        case .balanced: 1_200_000
        // Matches `SplatSceneState.performanceWarningSplatCount`: the count
        // where frame rate was measured to start falling off on device.
        case .performance: 500_000
        }
    }

    var title: String {
        switch self {
        case .full: "Full"
        case .balanced: "Balanced"
        case .performance: "Fast"
        }
    }

    var detail: String {
        switch self {
        case .full: "Every splat in the file."
        case .balanced: "Caps at 1.2M splats."
        case .performance: "Caps at 500k splats."
        }
    }
}
