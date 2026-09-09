//
//  SplatBounds.swift
//  Lustre
//
//  Spatial extent of a loaded splat, used to pick a pivot and an initial scale.
//  In Core because Library thumbnailing will want the same numbers.
//

import Foundation
import simd

nonisolated struct SplatBounds: Equatable, Sendable {
    let minimum: SIMD3<Float>
    let maximum: SIMD3<Float>

    var center: SIMD3<Float> { (minimum + maximum) / 2 }
    var extent: SIMD3<Float> { maximum - minimum }

    /// Ignores Y deliberately: a capture's height shouldn't drive how big it
    /// reads on a table, and tall thin captures would otherwise fit tiny.
    var longestHorizontalExtent: Float { max(extent.x, extent.z) }

    /// Robust bounds over a strided subsample.
    ///
    /// Raw min/max is unusable on real data: 3DGS PLYs routinely carry a
    /// handful of far-flung floater splats that inflate the box by orders of
    /// magnitude, which would make auto-fit worse than no auto-fit. Percentile
    /// bounds discard them.
    ///
    /// Takes a sequence rather than `[SplatPoint]` so `Core` stays free of the
    /// SplatIO dependency. **Pass `points.lazy.map(\.position)`** — an eager
    /// map allocates another ~60 MB at 5M points.
    static func robust(of positions: some Sequence<SIMD3<Float>>,
                       percentile: Float = 0.02,
                       maximumSamples: Int = 200_000) -> SplatBounds? {
        var xs: [Float] = [], ys: [Float] = [], zs: [Float] = []
        xs.reserveCapacity(maximumSamples)
        ys.reserveCapacity(maximumSamples)
        zs.reserveCapacity(maximumSamples)

        // Two passes would need the count up front, which a Sequence can't give
        // cheaply. Collect everything finite, then stride down if oversized.
        for position in positions where position.x.isFinite && position.y.isFinite && position.z.isFinite {
            xs.append(position.x); ys.append(position.y); zs.append(position.z)
        }
        guard !xs.isEmpty else { return nil }

        if xs.count > maximumSamples {
            // Fixed step, no RNG, so the result is deterministic and testable.
            let step = xs.count / maximumSamples + 1
            xs = stride(from: 0, to: xs.count, by: step).map { xs[$0] }
            ys = stride(from: 0, to: ys.count, by: step).map { ys[$0] }
            zs = stride(from: 0, to: zs.count, by: step).map { zs[$0] }
        }

        xs.sort(); ys.sort(); zs.sort()
        let lower = percentile
        let upper = 1 - percentile
        return SplatBounds(
            minimum: SIMD3(percentileValue(xs, lower),
                           percentileValue(ys, lower),
                           percentileValue(zs, lower)),
            maximum: SIMD3(percentileValue(xs, upper),
                           percentileValue(ys, upper),
                           percentileValue(zs, upper)))
    }

    /// `sorted` must already be ascending.
    private static func percentileValue(_ sorted: [Float], _ fraction: Float) -> Float {
        guard !sorted.isEmpty else { return 0 }
        let clamped = min(max(fraction, 0), 1)
        let index = Int((Float(sorted.count - 1) * clamped).rounded())
        return sorted[index]
    }

    /// Scale that puts `longestHorizontalExtent` at `targetExtent` meters.
    ///
    /// Returns `SplatScale.authored` for a degenerate (zero-extent) cloud
    /// rather than dividing by zero.
    func fittedScale(targetExtent: Float,
                     clampedTo range: ClosedRange<Float> = SplatScale.range) -> Float {
        let horizontal = longestHorizontalExtent
        guard horizontal.isFinite, horizontal > 0 else { return SplatScale.authored }
        return min(max(targetExtent / horizontal, range.lowerBound), range.upperBound)
    }
}
