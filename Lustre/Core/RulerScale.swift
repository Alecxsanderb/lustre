//
//  RulerScale.swift
//  Lustre
//
//  Picks tick spacing for the measuring marks on the placement axes, so a
//  real-world distance is readable against a splat whose own units are
//  arbitrary.
//
//  Shared between `GizmoRenderer`, which draws the ticks, and the control
//  menu, which names the interval — the gizmo has no text, so the menu is the
//  only place the user learns what one notch means.
//

import Foundation

nonisolated enum RulerUnits: String, CaseIterable, Identifiable, Sendable {
    case meters
    case feet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meters: "Metric"
        case .feet: "Imperial"
        }
    }
}

nonisolated struct RulerScale: Equatable, Sendable {

    /// Meters between minor ticks.
    let spacing: Float

    /// Minor ticks per major tick. Major ticks are drawn longer, so counting
    /// works without labels.
    let majorEvery: Int

    let units: RulerUnits

    /// Above this many minor ticks per axis the marks merge into a smear at
    /// arm's length, so the next coarser interval is chosen instead.
    private static let maximumTicksPerAxis: Float = 12

    private static let inch: Float = 0.0254
    private static let foot: Float = 0.3048

    /// Ascending. The first entry that keeps the tick count under the limit
    /// wins, so short rulers get fine marks and long ones get coarse marks.
    private static func candidates(for units: RulerUnits) -> [(spacing: Float, majorEvery: Int)] {
        switch units {
        case .meters:
            return [(0.001, 10), (0.005, 10), (0.01, 10), (0.02, 5),
                    (0.05, 10), (0.1, 10), (0.25, 4), (0.5, 2), (1, 5), (5, 2)]
        case .feet:
            return [(inch, 12), (inch * 3, 4), (inch * 6, 2), (foot, 3),
                    (foot * 3, 3), (foot * 10, 3), (foot * 100, 5)]
        }
    }

    /// - Parameter axisLength: half-length of one axis bar, in meters.
    static func fitting(axisLength: Float, units: RulerUnits) -> RulerScale {
        let options = candidates(for: units)
        let length = max(axisLength, 1e-4)
        let chosen = options.first { length / $0.spacing <= maximumTicksPerAxis } ?? options[options.count - 1]
        return RulerScale(spacing: chosen.spacing, majorEvery: chosen.majorEvery, units: units)
    }

    /// e.g. "5 cm" or "3 in" — what one minor tick is worth.
    var minorTickDescription: String { Self.describe(spacing, units: units) }

    /// e.g. "50 cm" or "1 ft" — what one major tick is worth.
    var majorTickDescription: String {
        Self.describe(spacing * Float(majorEvery), units: units)
    }

    private static func describe(_ meters: Float, units: RulerUnits) -> String {
        switch units {
        case .meters:
            if meters < 0.01 { return "\(rounded(meters * 1000)) mm" }
            if meters < 1 { return "\(rounded(meters * 100)) cm" }
            return "\(rounded(meters)) m"
        case .feet:
            if meters < foot { return "\(rounded(meters / inch)) in" }
            return "\(rounded(meters / foot)) ft"
        }
    }

    /// Tick intervals are chosen from round numbers, so anything that isn't
    /// whole after conversion is a rounding artifact rather than real precision.
    private static func rounded(_ value: Float) -> String {
        let whole = value.rounded()
        if abs(value - whole) < 0.05 { return String(Int(whole)) }
        return String(format: "%.1f", value)
    }
}
