//
//  CameraRelativeBasis.swift
//  Lustre
//
//  Turns "drag right" into a world-space direction that still means right
//  after the user has turned around.
//
//  In Core because Capture's path planner will need the same basis.
//

import Foundation
import simd

nonisolated struct CameraRelativeBasis: Equatable, Sendable {

    /// World up. Both pose providers guarantee it: `ARKitPoseProvider` runs
    /// `worldAlignment = .gravity`, and `SimulatedPoseProvider` only yaws
    /// about Y.
    static let worldUp = SIMD3<Float>(0, 1, 0)

    let right: SIMD3<Float>
    let up: SIMD3<Float>
    let forward: SIMD3<Float>

    /// Builds a gravity-aligned basis from a camera-to-world transform.
    ///
    /// Forward is flattened into the XZ plane so that pushing "away" slides the
    /// splat along the floor instead of burying it or launching it. Vertical is
    /// always world up — "up is up" never confuses anyone.
    ///
    /// Snapshot this once at gesture start. Rebuilding it per frame makes the
    /// splat swim while the user walks.
    init(cameraTransform: simd_float4x4) {
        // Camera looks down -Z in its own space; column 2 is +Z in world space.
        let cameraForward = -cameraTransform.columns.2.xyz
        var flattened = SIMD3<Float>(cameraForward.x, 0, cameraForward.z)

        if simd_length(flattened) < 1e-4 {
            // Looking straight up or down: the heading is undefined. Fall back
            // to the camera's own up vector flattened, which is the direction
            // the top of the phone points.
            let cameraUp = cameraTransform.columns.1.xyz
            flattened = SIMD3<Float>(cameraUp.x, 0, cameraUp.z)
        }
        if simd_length(flattened) < 1e-4 {
            // Fully degenerate (a rolled camera looking straight down). Any
            // stable heading beats NaN.
            flattened = SIMD3<Float>(0, 0, -1)
        }

        forward = simd_normalize(flattened)
        up = Self.worldUp
        right = simd_normalize(simd_cross(forward, Self.worldUp))
    }

    /// Builds the basis in world space from a camera-to-world transform, then
    /// expresses its axes in the local frame of `parent` (parent-to-world).
    ///
    /// Needed whenever the offset is added to a position that lives in a
    /// child frame rather than in world space: a world-space delta added to a
    /// local position comes out rotated by the parent's rotation.
    ///
    /// The flattening and "up" are decided in world space first, so they stay
    /// gravity-true even when the parent is tilted — ARKit raycast hits follow
    /// the real surface normal and can be a few degrees off level. Only then
    /// are the three axes mapped through the inverse of the parent's linear
    /// part. `worldDelta` is linear, so that's the same as mapping the final
    /// delta, and `parent * worldDelta(...)` (as a direction) is exactly the
    /// world-space offset. The axes are therefore not generally unit X/Y/Z in
    /// local terms, and `up` is not `worldUp` unless the parent only yaws.
    init(cameraTransform: simd_float4x4, expressedIn parent: simd_float4x4) {
        let world = CameraRelativeBasis(cameraTransform: cameraTransform)
        let linear = simd_float3x3(parent.columns.0.xyz,
                                   parent.columns.1.xyz,
                                   parent.columns.2.xyz)
        // Full inverse rather than transpose: anchors carry no scale today,
        // but this stays correct if a parent ever does.
        let worldToLocal = simd_inverse(linear)
        self.init(right: worldToLocal * world.right,
                  up: worldToLocal * world.up,
                  forward: worldToLocal * world.forward)
    }

    private init(right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>) {
        self.right = right
        self.up = up
        self.forward = forward
    }

    /// Composes an offset from camera-relative components, in meters, in the
    /// frame the basis is expressed in: world for `init(cameraTransform:)`,
    /// the parent's local frame for `init(cameraTransform:expressedIn:)`.
    func worldDelta(right rightAmount: Float,
                    up upAmount: Float,
                    forward forwardAmount: Float) -> SIMD3<Float> {
        right * rightAmount + up * upAmount + forward * forwardAmount
    }
}
