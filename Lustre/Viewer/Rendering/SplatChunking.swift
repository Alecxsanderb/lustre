//
//  SplatChunking.swift
//  Lustre
//
//  Splits a loaded splat into spatial chunks so the renderer can switch off
//  the ones that aren't on screen.
//
//  MetalSplatter has no frustum culling of its own, and its fragment shader
//  has no early-out — every splat that survives to rasterization costs
//  overdraw. `setChunkEnabled` is the one lever the public API gives us, and
//  it only has granularity if the scene is more than one chunk. See
//  `Lustre/Viewer/INTEGRATION.md`.
//
//  Runs off the main actor: this touches every point in the file.
//

import Foundation
import Metal
import simd
import MetalSplatter
import SplatIO

nonisolated enum SplatChunking {

    /// A chunk plus the axis-aligned box, **in the splat's own coordinates**,
    /// used to cull it. Asset space rather than world space so the bounds stay
    /// valid when the user rescales or re-places the splat.
    struct Built: Sendable {
        let chunk: SplatChunk
        let minimum: SIMD3<Float>
        let maximum: SIMD3<Float>
    }

    /// Chunks below roughly this size stop paying for themselves: each one adds
    /// a GPU chunk-table entry and a separate buffer, and the cull test is
    /// per-chunk CPU work.
    static let targetSplatsPerChunk = 40_000

    /// Enough granularity to cull a room from the inside, few enough that
    /// re-evaluating every chunk is trivial. Well under the library's own
    /// 65535 ceiling.
    static let maximumChunks = 128

    private static let maximumDivisionsPerAxis = 16

    /// - Parameters:
    ///   - bounds: robust bounds, used to lay out the grid. Nil (or degenerate)
    ///     falls back to a single chunk, which is exactly today's behavior.
    ///   - budget: maximum splats to keep. Anything above it is uniformly
    ///     strided out — see `SplatQuality`.
    static func build(points: [SplatPoint],
                      bounds: SplatBounds?,
                      budget: Int,
                      device: MTLDevice) throws -> [Built] {
        let total = points.count
        guard total > 0 else { return [] }

        let keptCount = budget > 0 ? min(total, budget) : total

        let divisions = bounds.map { gridDivisions(extent: $0.extent, splatCount: keptCount) }
        guard let bounds, let divisions, divisions.x * divisions.y * divisions.z > 1 else {
            return [try buildSingleChunk(points: points,
                                         keptCount: keptCount,
                                         device: device)]
        }

        return try buildGrid(points: points,
                             keptCount: keptCount,
                             origin: bounds.minimum,
                             extent: bounds.extent,
                             divisions: divisions,
                             device: device)
    }

    /// Source index of the `position`-th kept point.
    ///
    /// Spreads exactly `keptCount` picks evenly across `total`, deterministically
    /// and without a scratch array. Not a `ceil(total / budget)` stride: that
    /// jumps to 2 the moment a file exceeds the budget by a single splat, which
    /// would throw away half the scene to stay under a cap it was one point over.
    @inline(__always)
    private static func sourceIndex(_ position: Int, keptCount: Int, total: Int) -> Int {
        keptCount >= total ? position : position * total / keptCount
    }

    // MARK: - Single chunk

    private static func buildSingleChunk(points: [SplatPoint],
                                         keptCount: Int,
                                         device: MTLDevice) throws -> Built {
        var subset = [SplatPoint]()
        subset.reserveCapacity(keptCount)
        for position in 0..<keptCount {
            subset.append(points[sourceIndex(position, keptCount: keptCount, total: points.count)])
        }
        let box = boundingBox(of: subset)
        return Built(chunk: try SplatChunk(device: device, from: subset),
                     minimum: box.minimum,
                     maximum: box.maximum)
    }

    // MARK: - Grid

    /// Counting sort into per-cell runs, then one chunk per non-empty cell.
    ///
    /// The two `Int32` scratch arrays cost 8 bytes per kept splat — 40 MB on a
    /// 5M-point capture. Building every cell's `[SplatPoint]` up front instead
    /// would cost a second full copy of the point data, which is the one
    /// allocation a 500 MB PLY can't afford.
    private static func buildGrid(points: [SplatPoint],
                                  keptCount: Int,
                                  origin: SIMD3<Float>,
                                  extent: SIMD3<Float>,
                                  divisions: SIMD3<Int>,
                                  device: MTLDevice) throws -> [Built] {
        let cellCount = divisions.x * divisions.y * divisions.z
        let cellSize = SIMD3(max(extent.x, 1e-4) / Float(divisions.x),
                             max(extent.y, 1e-4) / Float(divisions.y),
                             max(extent.z, 1e-4) / Float(divisions.z))

        func cell(for position: SIMD3<Float>) -> Int {
            let local = (position - origin) / cellSize
            // Clamp in float first. Points outside the robust bounds are
            // expected (that's what makes the bounds robust), and `Int(_:)` of
            // a NaN or an out-of-range float traps.
            func axis(_ value: Float, _ count: Int) -> Int {
                guard value.isFinite else { return 0 }
                return Int(min(max(value, 0), Float(count - 1)))
            }
            return axis(local.x, divisions.x)
                + axis(local.y, divisions.y) * divisions.x
                + axis(local.z, divisions.z) * divisions.x * divisions.y
        }

        let total = points.count
        var cellOfKept = [Int32](repeating: 0, count: keptCount)
        var counts = [Int](repeating: 0, count: cellCount)
        for position in 0..<keptCount {
            let c = cell(for: points[sourceIndex(position, keptCount: keptCount, total: total)].position)
            cellOfKept[position] = Int32(c)
            counts[c] += 1
        }

        var starts = [Int](repeating: 0, count: cellCount + 1)
        for c in 0..<cellCount { starts[c + 1] = starts[c] + counts[c] }

        // `order` holds original point indices grouped by cell.
        var cursor = starts
        var order = [Int32](repeating: 0, count: keptCount)
        for position in 0..<keptCount {
            let c = Int(cellOfKept[position])
            order[cursor[c]] = Int32(sourceIndex(position, keptCount: keptCount, total: total))
            cursor[c] += 1
        }

        var built: [Built] = []
        built.reserveCapacity(cellCount)
        var members = [SplatPoint]()
        for c in 0..<cellCount where counts[c] > 0 {
            members.removeAll(keepingCapacity: true)
            members.reserveCapacity(counts[c])
            for slot in starts[c]..<starts[c + 1] {
                members.append(points[Int(order[slot])])
            }
            let box = boundingBox(of: members)
            built.append(Built(chunk: try SplatChunk(device: device, from: members),
                               minimum: box.minimum,
                               maximum: box.maximum))
        }
        return built
    }

    /// Cell layout proportional to the splat's shape, so a wide flat room gets
    /// divided across the floor rather than into vertical slabs.
    private static func gridDivisions(extent: SIMD3<Float>, splatCount: Int) -> SIMD3<Int> {
        let targetCells = min(max(splatCount / targetSplatsPerChunk, 1), maximumChunks)
        guard targetCells > 1 else { return SIMD3(1, 1, 1) }

        let safe = SIMD3(max(extent.x, 1e-4), max(extent.y, 1e-4), max(extent.z, 1e-4))
        guard safe.x.isFinite, safe.y.isFinite, safe.z.isFinite else { return SIMD3(1, 1, 1) }

        let cellSize = powf(safe.x * safe.y * safe.z / Float(targetCells), 1.0 / 3.0)
        guard cellSize.isFinite, cellSize > 0 else { return SIMD3(1, 1, 1) }

        func division(_ length: Float) -> Int {
            min(max(Int((length / cellSize).rounded()), 1), maximumDivisionsPerAxis)
        }
        var divisions = SIMD3(division(safe.x), division(safe.y), division(safe.z))

        // Rounding each axis independently can overshoot the cell budget; halve
        // the longest axis until it fits.
        while divisions.x * divisions.y * divisions.z > maximumChunks {
            if divisions.x >= divisions.y, divisions.x >= divisions.z {
                divisions.x = max(1, divisions.x / 2)
            } else if divisions.y >= divisions.z {
                divisions.y = max(1, divisions.y / 2)
            } else {
                divisions.z = max(1, divisions.z / 2)
            }
            if divisions == SIMD3(1, 1, 1) { break }
        }
        return divisions
    }

    /// Gaussians reach visibly out to about three standard deviations, and the
    /// linear scale is one standard deviation along each principal axis.
    private static let extentSigmas: Float = 3

    /// True min/max of the chunk's own members, not the grid cell — a cell
    /// holding one far-flung floater must report a box that contains it, or
    /// culling would make that splat disappear.
    ///
    /// Each point is padded by its footprint, not just its center: a large
    /// splat whose center is off screen can still cover the edge of it. The
    /// largest axis stands in for the rotated ellipsoid, which is conservative
    /// without touching the quaternion.
    private static func boundingBox(of points: [SplatPoint]) -> (minimum: SIMD3<Float>, maximum: SIMD3<Float>) {
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var found = false
        for point in points {
            let p = point.position
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { continue }
            let radius = point.scale.asLinearFloat.max() * extentSigmas
            // A NaN or infinite scale would poison the whole chunk box; keep
            // the center rather than drop the point.
            let pad = radius.isFinite && radius > 0 ? radius : 0
            minimum = simd_min(minimum, p - pad)
            maximum = simd_max(maximum, p + pad)
            found = true
        }
        guard found else { return (.zero, .zero) }
        return (minimum, maximum)
    }
}
