//
//  SplatDecimator.swift
//  Lustre
//
//  Keeps an evenly spread, bounded subsample of a splat stream without
//  knowing its length up front.
//
//  Thumbnails don't need every splat, and a 5M-splat capture held whole just
//  to draw a 300-pixel tile would cost the memory the Viewer needs. Readers
//  yield batches and none of them report a total, so a fixed stride can't be
//  chosen in advance. Instead: keep every k-th point; whenever the kept set
//  outgrows the cap, drop every other kept point and double k. The survivors
//  are always exactly the points whose input index is a multiple of k, so the
//  result is deterministic and spans the whole file, and peak memory is the
//  cap plus one batch.
//

import Foundation
import SplatIO

nonisolated struct StrideDecimator<Element> {

    let cap: Int

    /// Keep every `stride`-th input. Always a power of two.
    private(set) var stride = 1

    /// Inputs seen so far, kept or not.
    private(set) var consumedCount = 0

    private(set) var kept: [Element] = []

    /// Applied to each point as it's kept, never to the discarded ones.
    private let transform: @Sendable (Element) -> Element

    init(cap: Int, transform: @escaping @Sendable (Element) -> Element = { $0 }) {
        precondition(cap > 0, "A decimator needs room for at least one point")
        self.cap = cap
        self.transform = transform
        // One over the cap: the append that overflows happens before the halving.
        kept.reserveCapacity(cap + 1)
    }

    mutating func add(_ batch: some Sequence<Element>) {
        for element in batch {
            if consumedCount % stride == 0 {
                kept.append(transform(element))
                if kept.count > cap { halve() }
            }
            consumedCount += 1
        }
    }

    /// Keeps kept[0], kept[2], ...: the inputs at multiples of `2 * stride`.
    /// In place so the reserved capacity is reused rather than reallocated.
    private mutating func halve() {
        var write = 0
        for read in Swift.stride(from: 0, to: kept.count, by: 2) {
            kept[write] = kept[read]
            write += 1
        }
        kept.removeLast(kept.count - write)
        stride *= 2
    }
}

// Crosses into the watchdog's reader task as drain state.
extension StrideDecimator: Sendable where Element: Sendable {}

nonisolated enum SplatDecimator {

    /// Enough for a recognizable thumbnail at a fraction of a large capture's
    /// memory: ~300k SH0 points is a few tens of MB on the CPU side.
    static let defaultCap = 300_000

    static func make(cap: Int = defaultCap) -> StrideDecimator<SplatPoint> {
        StrideDecimator(cap: cap, transform: strippingHigherOrderSH)
    }

    /// Drops spherical-harmonic bands above degree 0.
    ///
    /// A thumbnail is one fixed view, so view-dependent color adds nothing, and
    /// degree-3 SH is 16 coefficients per splat: most of a point's memory.
    /// `SplatChunk` reads only SH0 into its splat buffer and sizes its SH
    /// buffer from the first point's degree, so stripping every kept point
    /// also keeps that GPU buffer from being allocated at all.
    ///
    /// `.sRGBUInt8` is already degree 0 and passes through. So does an empty
    /// coefficient list, which has no SH0 to keep (and which the library
    /// would trap on either way).
    static func strippingHigherOrderSH(_ point: SplatPoint) -> SplatPoint {
        guard case .sphericalHarmonicFloat(let coefficients) = point.color,
              coefficients.count > 1 else { return point }
        var stripped = point
        stripped.color = .sphericalHarmonicFloat([coefficients[0]])
        return stripped
    }
}
