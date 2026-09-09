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

    /// Composes a world-space offset from camera-relative components, in meters.
    func worldDelta(right rightAmount: Float,
                    up upAmount: Float,
                    forward forwardAmount: Float) -> SIMD3<Float> {
        right * rightAmount + up * upAmount + forward * forwardAmount
    }
}
