//
//  SplatChunkCuller.swift
//  Lustre
//
//  Switches off the splat chunks that can't be on screen.
//
//  Why this is careful about *when* it runs: `setChunkEnabled` goes through
//  MetalSplatter's `withChunkAccess`, which waits for in-flight renders to
//  drain and makes `isReadyToRender` false while it waits. Calling it every
//  frame would stall the render loop more than the culling saves. So the
//  visible set is re-evaluated only after the camera has actually moved, and
//  only then if the set changed at all.
//
//  (The flag itself is cheap once applied — the library documents it as
//  sort-neutral, since disabled chunks keep participating in the sort and the
//  vertex shader collapses their quads. So culling saves rasterization, not
//  sorting.)
//

import Foundation
import QuartzCore
import simd
import MetalSplatter

@MainActor
final class SplatChunkCuller {

    struct Entry {
        let id: ChunkID
        let minimum: SIMD3<Float>
        let maximum: SIMD3<Float>
        let splatCount: Int
        var isEnabled: Bool = true
    }

    private enum Constants {
        /// Never re-evaluate more often than this, however fast the phone moves.
        static let minimumInterval: CFTimeInterval = 0.3
        /// Fraction of the splat's own diagonal the camera must travel before
        /// a re-evaluation is worth considering. Relative rather than absolute
        /// so it behaves the same on a dollhouse and a full-size room.
        static let movementFraction: Float = 0.03
        /// About 6°.
        static let rotationCosine: Float = 0.9945
        /// Chunks are kept enabled a little outside the frustum so they don't
        /// pop in at the screen edge.
        static let marginFraction: Float = 0.05
    }

    private var entries: [Entry] = []
    private var sceneDiagonal: Float = 0
    private var lastEvaluation: CFTimeInterval = 0
    private var lastCameraPosition: SIMD3<Float>?
    private var lastCameraForward: SIMD3<Float>?
    private var needsEvaluation = false
    private var isApplying = false

    /// Nothing to cull with a single chunk, and the readout would be noise.
    var isActive: Bool { entries.count > 1 }

    var chunkCount: Int { entries.count }
    private(set) var visibleChunkCount: Int = 0
    private(set) var visibleSplatCount: Int = 0

    func reset(entries: [Entry]) {
        self.entries = entries
        visibleChunkCount = entries.count
        visibleSplatCount = entries.reduce(0) { $0 + $1.splatCount }

        if let first = entries.first {
            var minimum = first.minimum
            var maximum = first.maximum
            for entry in entries.dropFirst() {
                minimum = simd_min(minimum, entry.minimum)
                maximum = simd_max(maximum, entry.maximum)
            }
            sceneDiagonal = simd_length(maximum - minimum)
        } else {
            sceneDiagonal = 0
        }

        lastCameraPosition = nil
        lastCameraForward = nil
        needsEvaluation = true
    }

    func removeAll() {
        entries.removeAll()
        sceneDiagonal = 0
        visibleChunkCount = 0
        visibleSplatCount = 0
        needsEvaluation = false
    }

    /// - Parameters:
    ///   - viewMatrix: the full asset-to-camera matrix the renderer hands
    ///     MetalSplatter — pose × anchor × model. Chunk bounds are in asset
    ///     space, so folding the model transform in here is what lets them stay
    ///     untouched while the user scales and moves the splat.
    func update(viewMatrix: simd_float4x4,
                projectionMatrix: simd_float4x4,
                renderer: MetalSplatter.SplatRenderer) {
        guard isActive, !isApplying else { return }

        let inverseView = simd_inverse(viewMatrix)
        let position = inverseView.columns.3.xyz
        // Camera looks down -Z in its own space.
        let forward = simd_normalize(-inverseView.columns.2.xyz)
        guard position.x.isFinite, forward.x.isFinite else { return }

        let now = CACurrentMediaTime()
        guard shouldEvaluate(now: now, position: position, forward: forward) else { return }

        lastEvaluation = now
        lastCameraPosition = position
        lastCameraForward = forward
        needsEvaluation = false

        let frustum = Frustum(viewProjection: projectionMatrix * viewMatrix)
        let margin = sceneDiagonal * Constants.marginFraction

        var changes: [(id: ChunkID, enabled: Bool)] = []
        var visibleChunks = 0
        var visibleSplats = 0
        for index in entries.indices {
            let entry = entries[index]
            let visible = frustum.intersects(minimum: entry.minimum,
                                             maximum: entry.maximum,
                                             margin: margin)
            if visible {
                visibleChunks += 1
                visibleSplats += entry.splatCount
            }
            if visible != entry.isEnabled {
                entries[index].isEnabled = visible
                changes.append((entry.id, visible))
            }
        }
        visibleChunkCount = visibleChunks
        visibleSplatCount = visibleSplats

        guard !changes.isEmpty else { return }
        apply(changes, to: renderer)
    }

    private func shouldEvaluate(now: CFTimeInterval,
                                position: SIMD3<Float>,
                                forward: SIMD3<Float>) -> Bool {
        if needsEvaluation { return true }
        guard let lastCameraPosition, let lastCameraForward else { return true }
        guard now - lastEvaluation >= Constants.minimumInterval else { return false }

        let moved = simd_distance(position, lastCameraPosition)
            > max(sceneDiagonal * Constants.movementFraction, 1e-5)
        let turned = simd_dot(forward, lastCameraForward) < Constants.rotationCosine
        return moved || turned
    }

    /// One `withChunkAccess` for the whole batch: it's reentrant, so the nested
    /// `setChunkEnabled` calls don't each pay for draining the render queue.
    private func apply(_ changes: [(id: ChunkID, enabled: Bool)],
                       to renderer: MetalSplatter.SplatRenderer) {
        isApplying = true
        let payload = changes.map { (id: $0.id, enabled: $0.enabled) }
        Task { [weak self] in
            await renderer.withChunkAccess {
                for change in payload {
                    await renderer.setChunkEnabled(change.id, enabled: change.enabled)
                }
            }
            self?.isApplying = false
        }
    }
}
