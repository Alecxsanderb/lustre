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
