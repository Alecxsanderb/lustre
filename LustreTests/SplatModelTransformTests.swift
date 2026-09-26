//
//  SplatModelTransformTests.swift
//  LustreTests
//

import Foundation
import Testing
import simd
@testable import Lustre

struct SplatModelTransformTests {

    private func apply(_ matrix: simd_float4x4, _ point: SIMD3<Float>) -> SIMD3<Float> {
        (matrix * SIMD4(point, 1)).xyz
    }

    private func isClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, tolerance: Float = 1e-4) -> Bool {
        simd_length(a - b) < tolerance
    }

    /// Pins the whole order with a point whose image differs under any
    /// reordering of pivot, flip, rotation, and translation.
    @Test func pinsOperationOrder() {
        let pivot = SIMD3<Float>(1, 2, 3)
        let yaw = matrix4x4_rotation(radians: .pi / 2, axis: SIMD3(0, 1, 0))
        let matrix = SplatModelTransform.matrix(pivot: pivot,
                                                appliesUpCalibration: true,
                                                scale: 2,
                                                rotation: yaw,
                                                translation: SIMD3(10, 0, 0))
        // The pivot lands exactly on the translation: it's subtracted first.
        #expect(isClose(apply(matrix, pivot), SIMD3(10, 0, 0)))
        // One unit along +X from the pivot: flipped to -X, scaled to -2,
        // yawed 90° onto +Z, then placed.
        #expect(isClose(apply(matrix, pivot + SIMD3(1, 0, 0)), SIMD3(10, 0, 2)))
        // +Y from the pivot flips to -Y and yaw leaves it there.
        #expect(isClose(apply(matrix, pivot + SIMD3(0, 1, 0)), SIMD3(10, -2, 0)))
    }

    @Test func noCalibrationLeavesAxesAlone() {
        let matrix = SplatModelTransform.matrix(pivot: .zero, appliesUpCalibration: false, scale: 1)
        #expect(isClose(apply(matrix, SIMD3(1, 2, 3)), SIMD3(1, 2, 3)))
    }

    /// The Viewer's per-frame matrix must be exactly the shared transform, or
    /// thumbnails would frame a differently oriented splat than the Viewer shows.
    @MainActor
    @Test(arguments: [false, true])
    func sceneStateMatchesSharedTransform(appliesUpCalibration: Bool) {
        let state = SplatSceneState()
        state.pivot = SIMD3(0.5, -3, 7)
        state.appliesUpCalibration = appliesUpCalibration
        state.scale = 0.4
        state.yaw = 0.7
        state.pitch = -0.2
        state.roll = 0.1
        state.translation = SIMD3(-1, 0.25, 2)

        let expected = SplatModelTransform.matrix(pivot: state.pivot,
                                                  appliesUpCalibration: appliesUpCalibration,
                                                  scale: SplatScale.clamp(state.scale),
                                                  rotation: state.rotationMatrix,
                                                  translation: state.translation)
        #expect(state.modelMatrix == expected)
    }

    /// The scene state clamps an out-of-range scale before composing.
    @MainActor
    @Test func sceneStateClampsScale() {
        let state = SplatSceneState()
        state.scale = 1e9
        let expected = SplatModelTransform.matrix(pivot: .zero,
                                                  appliesUpCalibration: true,
                                                  scale: SplatScale.clamp(1e9))
        #expect(state.modelMatrix == expected)
    }
}
