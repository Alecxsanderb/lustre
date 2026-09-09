//
//  SplatScale.swift
//  Lustre
//
//  Scale mapping for splats. SfM output has no metric ground truth, so the
//  usable range spans several orders of magnitude and a linear slider is
//  useless across it.
//

import Foundation

nonisolated enum SplatScale {

    /// Six decades. The low end matters most: an SfM capture whose units are
    /// effectively kilometers needs to come down by ~1000× to be visible at all.
    static let range: ClosedRange<Float> = 0.001...1000

    /// `1.0` still means "as authored". It's the only stable meaning, it's what
    /// a saved placement serializes, and an eventual export needs it. Auto-fit
    /// changes the *initial value*, never this anchor.
    static let authored: Float = 1.0

    private static let logMinimum = log(range.lowerBound)
    private static let logMaximum = log(range.upperBound)

    /// Maps a scale to 0...1 for a slider. Logarithmic, so each decade gets
    /// equal travel and the midpoint is the geometric mean.
    static func sliderPosition(for scale: Float) -> Float {
        let clamped = clamp(scale)
        return (log(clamped) - logMinimum) / (logMaximum - logMinimum)
    }

    static func scale(forSliderPosition position: Float) -> Float {
        let t = min(max(position, 0), 1)
        return clamp(exp(logMinimum + t * (logMaximum - logMinimum)))
    }

    /// Guards against zero, negatives, and NaN, any of which would produce a
    /// singular model matrix and a blank screen.
    static func clamp(_ scale: Float) -> Float {
        guard scale.isFinite, scale > 0 else { return range.lowerBound }
        return min(max(scale, range.lowerBound), range.upperBound)
    }

    /// Magnitude-aware, because "0.0×" across three decades tells the user
    /// nothing. The slider is coarse; this is how they read the exact value.
    static func formatted(_ scale: Float) -> String {
        let magnitude = abs(scale)
        let fractionDigits: Int
        switch magnitude {
        case ..<0.01:  fractionDigits = 4
        case ..<0.1:   fractionDigits = 3
        case ..<10:    fractionDigits = 2
        case ..<100:   fractionDigits = 1
        default:       fractionDigits = 0
        }
        return String(format: "%.\(fractionDigits)f×", scale)
    }
}
