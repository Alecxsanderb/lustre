//
//  CameraRelativeBasisTests.swift
//  LustreTests
//
//  The translation a gesture edits lives in the anchor's frame, and ARKit
//  surface anchors carry an arbitrary yaw. These pin that a basis built from
//  the camera in anchor space moves the splat along the camera's heading in
//  the world, whatever that yaw is.
//

import Foundation
import Testing
import simd
@testable import Lustre

@MainActor
struct CameraRelativeBasisTests {

    private let up = SIMD3<Float>(0, 1, 0)

    /// Yawed 20°, pitched 25° down, off the origin: an ordinary handheld pose
    /// that exercises the flattening.
    private let camera = matrix4x4_translation(0.3, 1.4, 0.5)
        * matrix4x4_rotation(radians: 20 * .pi / 180, axis: SIMD3(0, 1, 0))
        * matrix4x4_rotation(radians: -25 * .pi / 180, axis: SIMD3(1, 0, 0))

    /// Gravity-aligned, like an ARKit hit on a horizontal plane.
    private func anchor(yawDegrees: Float) -> simd_float4x4 {
        matrix4x4_translation(1, -0.8, -2)
            * matrix4x4_rotation(radians: yawDegrees * .pi / 180, axis: SIMD3(0, 1, 0))
    }

    /// Where a local-space offset ends up in the world: rotation only, since
    /// it's a direction, not a point.
    private func worldImage(of local: SIMD3<Float>, under anchor: simd_float4x4) -> SIMD3<Float> {
        (anchor * SIMD4(local, 0)).xyz
    }

    private var flattenedWorldForward: SIMD3<Float> {
        let forward = -camera.columns.2.xyz
        return simd_normalize(SIMD3(forward.x, 0, forward.z))
    }

    private func isClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
        simd_length(a - b) < 1e-4
    }

    @Test("Forward follows the camera heading under any anchor yaw",
          arguments: [Float(0), 30, 90, 180])
    func forwardFollowsHeading(yawDegrees: Float) {
        let anchor = anchor(yawDegrees: yawDegrees)
        let local = CameraRelativeBasis.cameraTransform(camera, inFrameOf: anchor)
        let basis = CameraRelativeBasis(cameraTransform: local)

        let world = worldImage(of: basis.worldDelta(right: 0, up: 0, forward: 1), under: anchor)
        #expect(isClose(world, flattenedWorldForward))
    }

    @Test("Right and up follow the camera under any anchor yaw",
          arguments: [Float(0), 30, 90, 180])
    func rightAndUpFollowCamera(yawDegrees: Float) {
        let anchor = anchor(yawDegrees: yawDegrees)
        let basis = CameraRelativeBasis(
            cameraTransform: CameraRelativeBasis.cameraTransform(camera, inFrameOf: anchor))

        let right = worldImage(of: basis.worldDelta(right: 1, up: 0, forward: 0), under: anchor)
        let upImage = worldImage(of: basis.worldDelta(right: 0, up: 1, forward: 0), under: anchor)
        #expect(isClose(right, simd_normalize(simd_cross(flattenedWorldForward, up))))
        #expect(isClose(upImage, up))
    }

    /// With an unrotated anchor the anchor frame's axes are world axes, so the
    /// fix must change nothing — this is why the simulator never showed it.
    @Test func translationOnlyAnchorMatchesTheWorldBasis() {
        let anchor = matrix4x4_translation(1, -0.8, -2)
        let local = CameraRelativeBasis(
            cameraTransform: CameraRelativeBasis.cameraTransform(camera, inFrameOf: anchor))
        let world = CameraRelativeBasis(cameraTransform: camera)
        #expect(isClose(local.forward, world.forward))
        #expect(isClose(local.right, world.right))
    }

    /// The bug itself: a world basis applied inside a yawed anchor is off by
    /// exactly the anchor's yaw.
    @Test func worldBasisInsideAYawedAnchorIsOffByTheYaw() {
        let anchor = anchor(yawDegrees: 30)
        let worldBasis = CameraRelativeBasis(cameraTransform: camera)
        let world = worldImage(of: worldBasis.forward, under: anchor)
        let angle = acos(min(1, simd_dot(world, flattenedWorldForward)))
        #expect(abs(angle - 30 * .pi / 180) < 1e-3)
    }

    #if targetEnvironment(simulator)
    /// The model hands gestures the camera in anchor space, not world space.
    @Test func modelSuppliesTheCameraInAnchorSpace() throws {
        let model = ViewerModel()
        let provider = try #require(model.simulatedProvider)
        let placed = anchor(yawDegrees: 90)
        model.sceneState.placedTransform = placed
        model.sceneState.placementState = .placed

        let expected = simd_inverse(placed) * provider.pose.transform
        let actual = model.cameraTransformInAnchorSpace
        for column in 0..<4 {
            #expect(simd_length(actual[column] - expected[column]) < 1e-5)
        }
    }
    #endif
}
