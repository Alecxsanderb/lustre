//
//  CameraRelativeBasisTests.swift
//  LustreTests
//
//  The translation a gesture edits lives in the anchor's frame. ARKit surface
//  anchors carry an arbitrary yaw and, because raycast hits follow the real
//  surface normal, can be tilted a few degrees off level. These pin that the
//  basis moves the splat along the camera's gravity-true heading, world right,
//  and world up in the world, whatever the anchor's orientation.
//

import Foundation
import Testing
import simd
@testable import Lustre

/// An anchor orientation, in degrees. Pitch is about X, roll about Z, both
/// applied after yaw about Y.
struct AnchorOrientation: Sendable, CustomTestStringConvertible {
    var yaw: Float
    var pitch: Float = 0
    var roll: Float = 0

    var testDescription: String { "yaw \(yaw)° pitch \(pitch)° roll \(roll)°" }

    var transform: simd_float4x4 {
        let degrees = Float.pi / 180
        return matrix4x4_translation(1, -0.8, -2)
            * matrix4x4_rotation(radians: yaw * degrees, axis: SIMD3(0, 1, 0))
            * matrix4x4_rotation(radians: pitch * degrees, axis: SIMD3(1, 0, 0))
            * matrix4x4_rotation(radians: roll * degrees, axis: SIMD3(0, 0, 1))
    }
}

@MainActor
struct CameraRelativeBasisTests {

    private let up = SIMD3<Float>(0, 1, 0)

    /// Yawed 20°, pitched 25° down, off the origin: an ordinary handheld pose
    /// that exercises the flattening.
    private let camera = matrix4x4_translation(0.3, 1.4, 0.5)
        * matrix4x4_rotation(radians: 20 * .pi / 180, axis: SIMD3(0, 1, 0))
        * matrix4x4_rotation(radians: -25 * .pi / 180, axis: SIMD3(1, 0, 0))

    /// Gravity-aligned yaws plus surface-tilted anchors like an
    /// `.estimatedPlane` hit on a slightly sloped floor.
    static let orientations: [AnchorOrientation] = [
        AnchorOrientation(yaw: 0),
        AnchorOrientation(yaw: 30),
        AnchorOrientation(yaw: 90),
        AnchorOrientation(yaw: 180),
        AnchorOrientation(yaw: 30, pitch: 5),
        AnchorOrientation(yaw: 0, roll: 8),
        AnchorOrientation(yaw: -120, pitch: -6, roll: 4),
    ]

    /// Where a local-space offset ends up in the world: rotation only, since
    /// it's a direction, not a point.
    private func worldImage(of local: SIMD3<Float>, under anchor: simd_float4x4) -> SIMD3<Float> {
        (anchor * SIMD4(local, 0)).xyz
    }

    private var flattenedWorldForward: SIMD3<Float> {
        let forward = -camera.columns.2.xyz
        return simd_normalize(SIMD3(forward.x, 0, forward.z))
    }

    private var worldRight: SIMD3<Float> {
        simd_normalize(simd_cross(flattenedWorldForward, up))
    }

    private func isClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
        simd_length(a - b) < 1e-4
    }

    private func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        acos(min(1, simd_dot(simd_normalize(a), simd_normalize(b))))
    }

    @Test("Forward follows the gravity-true camera heading under any anchor",
          arguments: orientations)
    func forwardFollowsHeading(orientation: AnchorOrientation) {
        let anchor = orientation.transform
        let basis = CameraRelativeBasis(cameraTransform: camera, expressedIn: anchor)

        let world = worldImage(of: basis.worldDelta(right: 0, up: 0, forward: 1), under: anchor)
        #expect(isClose(world, flattenedWorldForward))
    }

    @Test("Right is world right and up is world up under any anchor",
          arguments: orientations)
    func rightAndUpFollowCamera(orientation: AnchorOrientation) {
        let anchor = orientation.transform
        let basis = CameraRelativeBasis(cameraTransform: camera, expressedIn: anchor)

        let right = worldImage(of: basis.worldDelta(right: 1, up: 0, forward: 0), under: anchor)
        let upImage = worldImage(of: basis.worldDelta(right: 0, up: 1, forward: 0), under: anchor)
        #expect(isClose(right, worldRight))
        #expect(isClose(upImage, up))
    }

    /// Linearity: mapping the axes is the same as mapping the combined delta.
    @Test(arguments: orientations)
    func combinedDeltaMapsToTheWorldDelta(orientation: AnchorOrientation) {
        let anchor = orientation.transform
        let local = CameraRelativeBasis(cameraTransform: camera, expressedIn: anchor)
        let world = CameraRelativeBasis(cameraTransform: camera)

        let localDelta = local.worldDelta(right: 0.3, up: -0.2, forward: 0.7)
        let worldDelta = world.worldDelta(right: 0.3, up: -0.2, forward: 0.7)
        #expect(isClose(worldImage(of: localDelta, under: anchor), worldDelta))
    }

    /// With an unrotated anchor the anchor frame's axes are world axes, so the
    /// fix must change nothing — this is why the simulator never showed it.
    @Test func translationOnlyAnchorMatchesTheWorldBasis() {
        let anchor = matrix4x4_translation(1, -0.8, -2)
        let local = CameraRelativeBasis(cameraTransform: camera, expressedIn: anchor)
        let world = CameraRelativeBasis(cameraTransform: camera)
        #expect(isClose(local.forward, world.forward))
        #expect(isClose(local.right, world.right))
        #expect(isClose(local.up, world.up))
    }

    /// Anchors carry no scale today, but the inverse must still round-trip if
    /// one ever does.
    @Test func scaledAnchorStillMapsBackToTheWorldBasis() {
        let anchor = AnchorOrientation(yaw: 45, pitch: 3).transform * matrix4x4_scale(2)
        let basis = CameraRelativeBasis(cameraTransform: camera, expressedIn: anchor)
        let world = worldImage(of: basis.worldDelta(right: 0, up: 0, forward: 1), under: anchor)
        #expect(isClose(world, flattenedWorldForward))
    }

    /// The original bug: a world basis applied inside a yawed anchor is off by
    /// exactly the anchor's yaw.
    @Test func worldBasisInsideAYawedAnchorIsOffByTheYaw() {
        let anchor = AnchorOrientation(yaw: 30).transform
        let worldBasis = CameraRelativeBasis(cameraTransform: camera)
        let world = worldImage(of: worldBasis.forward, under: anchor)
        #expect(abs(angle(world, flattenedWorldForward) - 30 * .pi / 180) < 1e-3)
    }

    /// Why the first fix wasn't enough: flattening the camera in a tilted
    /// anchor's frame makes "up" the anchor's up, not gravity's.
    @Test func flatteningInsideATiltedAnchorMissesWorldUp() {
        let anchor = AnchorOrientation(yaw: 0, roll: 8).transform
        let naive = CameraRelativeBasis(cameraTransform: simd_inverse(anchor) * camera)
        let upImage = worldImage(of: naive.up, under: anchor)
        #expect(abs(angle(upImage, up) - 8 * .pi / 180) < 1e-3)
    }

    #if targetEnvironment(simulator)
    /// The model hands gestures a basis built from the world camera and
    /// expressed in the current anchor's frame.
    @Test func modelBuildsTheGestureBasisInAnchorSpace() throws {
        let model = ViewerModel()
        let provider = try #require(model.simulatedProvider)
        let placed = AnchorOrientation(yaw: 90, pitch: 5, roll: -3).transform
        model.sceneState.placedTransform = placed
        model.sceneState.placementState = .placed

        let camera = provider.pose.transform
        let expected = CameraRelativeBasis(cameraTransform: camera, expressedIn: placed)
        let actual = model.makeGestureBasis()
        #expect(isClose(actual.right, expected.right))
        #expect(isClose(actual.up, expected.up))
        #expect(isClose(actual.forward, expected.forward))

        // And it lands on world up in the world, despite the tilt.
        #expect(isClose(worldImage(of: actual.up, under: placed), up))
    }
    #endif
}
