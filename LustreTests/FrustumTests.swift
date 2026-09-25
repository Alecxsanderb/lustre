//
//  FrustumTests.swift
//  LustreTests
//

import Foundation
import Testing
import simd
@testable import Lustre

struct FrustumTests {

    /// Identity is Metal's clip volume itself: -1...1 in x and y, 0...1 in z.
    private let clipVolume = Frustum(viewProjection: matrix_identity_float4x4)

    @Test func planesAreNormalized() {
        for plane in clipVolume.planes {
            #expect(abs(simd_length(plane.xyz) - 1) < 1e-6)
        }
        #expect(clipVolume.planes.count == 6)
    }

    @Test func boxInsideIntersects() {
        #expect(clipVolume.intersects(minimum: SIMD3(-0.5, -0.5, 0.2), maximum: SIMD3(0.5, 0.5, 0.8)))
    }

    @Test func boxStraddlingAPlaneIntersects() {
        #expect(clipVolume.intersects(minimum: SIMD3(0.5, 0, 0.5), maximum: SIMD3(3, 0.1, 0.6)))
    }

    @Test("Box outside any one plane is rejected", arguments: [
        (SIMD3<Float>(-3, 0, 0.5), SIMD3<Float>(-2, 0.1, 0.6)),   // left
        (SIMD3<Float>(2, 0, 0.5), SIMD3<Float>(3, 0.1, 0.6)),     // right
        (SIMD3<Float>(0, -3, 0.5), SIMD3<Float>(0.1, -2, 0.6)),   // bottom
        (SIMD3<Float>(0, 2, 0.5), SIMD3<Float>(0.1, 3, 0.6)),     // top
        (SIMD3<Float>(0, 0, -0.5), SIMD3<Float>(0.1, 0.1, -0.1)), // near: z < 0, not z < -w
        (SIMD3<Float>(0, 0, 1.5), SIMD3<Float>(0.1, 0.1, 2)),     // far
    ])
    func outside(minimum: SIMD3<Float>, maximum: SIMD3<Float>) {
        #expect(!clipVolume.intersects(minimum: minimum, maximum: maximum))
    }

    @Test func marginIsADistance() {
        // 0.5 past the right plane: a 0.4 margin isn't enough, 0.6 is.
        let minimum = SIMD3<Float>(1.5, 0, 0.5), maximum = SIMD3<Float>(2, 0.1, 0.6)
        #expect(!clipVolume.intersects(minimum: minimum, maximum: maximum, margin: 0.4))
        #expect(clipVolume.intersects(minimum: minimum, maximum: maximum, margin: 0.6))
    }

    @Test func perspectiveCullsBehindAndBeside() {
        // Camera at the origin looking down -Z, 90° vertical field of view.
        let projection = perspectiveProjection(fovyRadians: .pi / 2, aspectRatio: 1, nearZ: 0.1, farZ: 100)
        let frustum = Frustum(viewProjection: projection)
        let unit = SIMD3<Float>(repeating: 0.5)

        func box(at center: SIMD3<Float>) -> Bool {
            frustum.intersects(minimum: center - unit, maximum: center + unit)
        }
        #expect(box(at: SIMD3(0, 0, -5)))
        #expect(!box(at: SIMD3(0, 0, 5)))       // behind
        #expect(!box(at: SIMD3(20, 0, -5)))     // far outside the 45° half-angle
        #expect(!box(at: SIMD3(0, 0, -200)))    // past far
    }

    @Test func modelTransformMovesThePlanesIntoModelSpace() {
        // A splat translated 10 m forward: its origin should be visible,
        // though the same box would be behind a camera without the transform.
        let projection = perspectiveProjection(fovyRadians: .pi / 2, aspectRatio: 1, nearZ: 0.1, farZ: 100)
        let model = matrix4x4_translation(0, 0, -10)
        let frustum = Frustum(viewProjection: projection * model)
        #expect(frustum.intersects(minimum: SIMD3(-0.5, -0.5, -0.5), maximum: SIMD3(0.5, 0.5, 0.5)))
        #expect(!frustum.intersects(minimum: SIMD3(-0.5, -0.5, 11), maximum: SIMD3(0.5, 0.5, 12)))
    }
}
