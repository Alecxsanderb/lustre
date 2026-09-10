//
//  SimulatedPoseProvider.swift
//  Lustre
//
//  Joystick-driven pose for the simulator, where ARKit doesn't exist.
//  Left stick translates, right stick looks — the standard FPS mapping.
//

import Foundation
import Observation
import simd

@MainActor
@Observable
final class SimulatedPoseProvider: PoseProvider {

    private enum Constants {
        static let metersPerSecond: Float = 1.8
        static let radiansPerSecond: Float = 1.6
        /// Stop just short of straight up/down; at exactly ±90° yaw becomes
        /// ambiguous and the view snaps.
        static let maximumPitch: Float = .pi / 2 - 0.01
        static let startingPosition = SIMD3<Float>(0, 0, 3)
    }

    /// Left stick: x strafes, y moves forward/back.
    var moveInput: SIMD2<Float> = .zero

    /// Right stick: x yaws, y pitches.
    var lookInput: SIMD2<Float> = .zero

    var verticalFieldOfView: Float = 65 * .pi / 180

    private(set) var pose: CameraPose = .identity

    /// Backing storage for `SurfaceProvider`. Stored here rather than in the
    /// extension because Swift extensions can't add stored properties.
    var detectsSurfaces = false
    var anchors: [UUID: simd_float4x4] = [:]

    static let syntheticFloorID = UUID()

    private var position = Constants.startingPosition
    private var yaw: Float = 0
    private var pitch: Float = 0

    init() {
        rebuildPose()
    }

    func start() {}
    func stop() {}

    func update(deltaTime: TimeInterval) {
        let dt = Float(deltaTime)
        // A hitch (or a debugger pause) shouldn't teleport the camera.
        guard dt > 0, dt < 0.5 else { return }

        yaw -= lookInput.x * Constants.radiansPerSecond * dt
        pitch += lookInput.y * Constants.radiansPerSecond * dt
        pitch = min(max(pitch, -Constants.maximumPitch), Constants.maximumPitch)

        if moveInput != .zero {
            // Move along the heading only: looking up shouldn't fly you upward.
            let forward = SIMD3<Float>(-sin(yaw), 0, -cos(yaw))
            let right = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
            let delta = (forward * moveInput.y + right * moveInput.x)
                * Constants.metersPerSecond * dt
            position += delta
        }

        rebuildPose()
    }

    func recenter() {
        position = Constants.startingPosition
        yaw = 0
        pitch = 0
        rebuildPose()
    }

    private func rebuildPose() {
        let rotation = matrix4x4_rotation(radians: yaw, axis: SIMD3<Float>(0, 1, 0))
            * matrix4x4_rotation(radians: pitch, axis: SIMD3<Float>(1, 0, 0))
        pose = CameraPose(transform: matrix4x4_translation(position) * rotation)
    }
}

// MARK: - SurfaceProvider

/// A synthetic floor, so the placement flow, the gizmo, and anchoring are all
/// exercisable without ARKit. Matches `SampleSplatScene`'s floor height, so the
/// simulator behaves like standing in the sample room.
extension SimulatedPoseProvider: SurfaceProvider {

    private static let syntheticFloorY: Float = -1.5
    private static let syntheticFloorExtent = SIMD2<Float>(6, 6)
    /// Where the candidate goes when the camera points at the sky and the ray
    /// never meets the floor.
    private static let fallbackDistance: Float = 2.0

    var isSurfaceDetectionEnabled: Bool {
        get { detectsSurfaces }
        set { detectsSurfaces = newValue }
    }

    var detectedPlanes: [DetectedPlane] {
        guard detectsSurfaces else { return [] }
        return [DetectedPlane(id: Self.syntheticFloorID,
                              transform: matrix4x4_translation(0, Self.syntheticFloorY, 0),
                              extent: Self.syntheticFloorExtent)]
    }

    var placementCandidate: PlacementCandidate? {
        guard detectsSurfaces else { return nil }

        let origin = pose.position
        let forward = -pose.transform.columns.2.xyz

        // Intersect the view ray with the floor plane. A ray pointing up or
        // level never meets it.
        if forward.y < -1e-4 {
            let distance = (Self.syntheticFloorY - origin.y) / forward.y
            if distance > 0, distance < 20 {
                let hit = origin + forward * distance
                return PlacementCandidate(transform: matrix4x4_translation(hit),
                                          isOnSurface: true)
            }
        }

        let estimate = origin + forward * Self.fallbackDistance
        return PlacementCandidate(transform: matrix4x4_translation(estimate),
                                  isOnSurface: false)
    }

    func makeAnchor(at transform: simd_float4x4) -> UUID? {
        let id = UUID()
        anchors[id] = transform
        return id
    }

    /// No refinement to apply — a simulated world never drifts, which is
    /// precisely why this path can't validate the drift fix.
    func anchorTransform(for id: UUID) -> simd_float4x4? {
        anchors[id]
    }

    func removeAnchor(_ id: UUID) {
        anchors.removeValue(forKey: id)
    }
}
