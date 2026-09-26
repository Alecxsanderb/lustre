//
//  ThumbnailFramingTests.swift
//  LustreTests
//

import Foundation
import Testing
import simd
@testable import Lustre

struct ThumbnailFramingTests {

    private func isFinite(_ matrix: simd_float4x4) -> Bool {
        (0..<4).allSatisfy { column in
            (0..<4).allSatisfy { row in matrix[column][row].isFinite }
        }
    }

    private func cameraPosition(_ view: simd_float4x4) -> SIMD3<Float> {
        simd_inverse(view).columns.3.xyz
    }

    /// Camera-space forward (-Z) expressed in world space.
    private func forward(_ view: simd_float4x4) -> SIMD3<Float> {
        simd_normalize(-simd_inverse(view).columns.2.xyz)
    }

    private let offCenter = SplatBounds(minimum: SIMD3(2, -1, -7), maximum: SIMD3(6, 0.5, -3))

    @Test func cameraSitsOnPlusZSideAboveCenter() {
        let camera = ThumbnailFraming.camera(for: offCenter)
        let eye = cameraPosition(camera.view)
        #expect(eye.z > offCenter.maximum.z)
        #expect(eye.y > offCenter.center.y)
        #expect(abs(eye.x - offCenter.center.x) < 1e-4)
    }

    @Test func looksAtBoundsCenter() {
        let camera = ThumbnailFraming.camera(for: offCenter)
        let eye = cameraPosition(camera.view)
        let toCenter = simd_normalize(offCenter.center - eye)
        #expect(simd_dot(forward(camera.view), toCenter) > 0.9999)
        // The center projects to the middle of the image.
        let clip = camera.projection * camera.view * SIMD4(offCenter.center, 1)
        #expect(abs(clip.x / clip.w) < 1e-4 && abs(clip.y / clip.w) < 1e-4)
    }

    @Test func elevationIsAboutTwentyDegrees() {
        let pitch = asinf(-forward(ThumbnailFraming.camera(for: offCenter).view).y)
        #expect(abs(pitch - ThumbnailFraming.elevation) < 1e-4)
    }

    /// Wide, tall, and deep boxes at 4:3, plus a portrait aspect where the
    /// horizontal FOV is the tighter one.
    @Test(arguments: [
        (SplatBounds(minimum: SIMD3(-10, -0.2, -1), maximum: SIMD3(10, 0.2, 1)), Float(4.0 / 3.0)),
        (SplatBounds(minimum: SIMD3(-0.1, -5, -0.1), maximum: SIMD3(0.1, 5, 0.1)), Float(4.0 / 3.0)),
        (SplatBounds(minimum: SIMD3(-1, -1, -30), maximum: SIMD3(1, 1, 30)), Float(4.0 / 3.0)),
        (SplatBounds(minimum: SIMD3(2, -1, -7), maximum: SIMD3(6, 0.5, -3)), Float(4.0 / 3.0)),
        (SplatBounds(minimum: SIMD3(-10, -0.2, -1), maximum: SIMD3(10, 0.2, 1)), Float(0.5)),
    ])
    func allCornersProjectInsideNDC(bounds: SplatBounds, aspect: Float) {
        let camera = ThumbnailFraming.camera(for: bounds, aspect: aspect)
        let viewProjection = camera.projection * camera.view
        for corner in ThumbnailFraming.corners(of: bounds) {
            let clip = viewProjection * SIMD4(corner, 1)
            #expect(clip.w > 0)
            let ndc = clip.xyz / clip.w
            #expect(abs(ndc.x) <= 1 && abs(ndc.y) <= 1, "corner \(corner) at \(ndc)")
            // Metal depth range, so the near/far planes don't clip the box.
            #expect(ndc.z >= 0 && ndc.z <= 1, "corner \(corner) depth \(ndc.z)")
        }
    }

    @Test func fillsTheFrameReasonably() {
        // A cube shouldn't come out as a speck: its extreme corner reaches at
        // least half-way to the frame edge on the limiting axis.
        let cube = SplatBounds(minimum: SIMD3(repeating: -1), maximum: SIMD3(repeating: 1))
        let camera = ThumbnailFraming.camera(for: cube)
        let viewProjection = camera.projection * camera.view
        let reach = ThumbnailFraming.corners(of: cube).map { corner -> Float in
            let clip = viewProjection * SIMD4(corner, 1)
            return max(abs(clip.x / clip.w), abs(clip.y / clip.w))
        }.max() ?? 0
        #expect(reach > 0.5)
    }

    @Test func degenerateBoundsStayFinite() {
        let point = SplatBounds(minimum: SIMD3(1, 2, 3), maximum: SIMD3(1, 2, 3))
        let zero = SplatBounds(minimum: .zero, maximum: .zero)
        let nonFinite = SplatBounds(minimum: SIMD3(repeating: -.infinity), maximum: SIMD3(repeating: .infinity))
        for bounds in [point, zero, nonFinite] {
            let camera = ThumbnailFraming.camera(for: bounds)
            #expect(isFinite(camera.view))
            #expect(isFinite(camera.projection))
        }
        // Bad lens parameters fall back rather than producing NaN.
        let bad = ThumbnailFraming.camera(for: point, aspect: 0, fovY: .nan)
        #expect(isFinite(bad.view) && isFinite(bad.projection))
    }

    // MARK: - Model transform

    @Test func libraryModelRecentresAndFlips() {
        let bounds = SplatBounds(minimum: SIMD3(10, 20, 30), maximum: SIMD3(12, 26, 31))
        let model = ThumbnailFraming.libraryModelMatrix(for: bounds)

        // Same as the Viewer's for a library file at authored scale.
        let expected = SplatModelTransform.matrix(pivot: bounds.center, appliesUpCalibration: true,
                                                  scale: SplatScale.authored)
        #expect(model == expected)

        let world = ThumbnailFraming.transformed(bounds, by: model)
        #expect(simd_length(world.center) < 1e-4)
        #expect(simd_length(world.extent - bounds.extent) < 1e-4)

        // The flip: the asset's max-Y corner ends up at the bottom.
        let top = (model * SIMD4(SIMD3<Float>(11, 26, 30.5), 1)).xyz
        #expect(abs(top.y - -3) < 1e-4)
    }

    @Test func transformedHandlesRotation() {
        let bounds = SplatBounds(minimum: SIMD3(-2, -1, -1), maximum: SIMD3(2, 1, 1))
        let quarterTurn = matrix4x4_rotation(radians: .pi / 2, axis: SIMD3(0, 1, 0))
        let world = ThumbnailFraming.transformed(bounds, by: quarterTurn)
        // X and Z swap extents under a quarter turn about Y.
        #expect(simd_length(world.extent - SIMD3(2, 2, 4)) < 1e-4)
    }
}
