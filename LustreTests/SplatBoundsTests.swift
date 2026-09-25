//
//  SplatBoundsTests.swift
//  LustreTests
//

import Foundation
import Testing
import simd
@testable import Lustre

struct SplatBoundsTests {

    @Test func emptyInputHasNoBounds() {
        #expect(SplatBounds.robust(of: [SIMD3<Float>]()) == nil)
    }

    @Test func nonFiniteOnlyInputHasNoBounds() {
        let points: [SIMD3<Float>] = [SIMD3(.nan, 0, 0), SIMD3(0, .infinity, 0)]
        #expect(SplatBounds.robust(of: points) == nil)
    }

    @Test func singlePointIsDegenerate() {
        let bounds = SplatBounds.robust(of: [SIMD3<Float>(1, 2, 3)])
        #expect(bounds == SplatBounds(minimum: SIMD3(1, 2, 3), maximum: SIMD3(1, 2, 3)))
        #expect(bounds?.fittedScale(targetExtent: 1.5) == SplatScale.authored)
    }

    @Test func farFloatersAreDiscarded() throws {
        // 1000 points spread across 0...1 on every axis, plus a floater a
        // kilometer away. Raw min/max would be dominated by the floater.
        var points = (0..<1000).map { i -> SIMD3<Float> in
            let t = Float(i) / 999
            return SIMD3(t, t, t)
        }
        points.append(SIMD3(1000, -1000, 1000))

        let bounds = try #require(SplatBounds.robust(of: points))
        for axis in 0..<3 {
            #expect(bounds.minimum[axis] >= -0.01)
            #expect(bounds.maximum[axis] <= 1.01)
            #expect(bounds.extent[axis] > 0.9)
        }
    }

    @Test func nonFinitePointsAreSkipped() throws {
        let points: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(.nan, 5, 5), SIMD3(2, 2, 2)]
        let bounds = try #require(SplatBounds.robust(of: points, percentile: 0))
        #expect(bounds == SplatBounds(minimum: .zero, maximum: SIMD3(2, 2, 2)))
    }

    @Test func subsamplingIsDeterministic() {
        let points = (0..<10_000).map { i -> SIMD3<Float> in
            let t = Float((i * 7919) % 10_000)
            return SIMD3(t, -t, t * 0.5)
        }
        let first = SplatBounds.robust(of: points, maximumSamples: 1_000)
        let second = SplatBounds.robust(of: points, maximumSamples: 1_000)
        #expect(first != nil)
        #expect(first == second)
    }

    @Test func centerAndExtent() {
        let bounds = SplatBounds(minimum: SIMD3(-1, 0, 2), maximum: SIMD3(3, 4, 4))
        #expect(bounds.center == SIMD3(1, 2, 3))
        #expect(bounds.extent == SIMD3(4, 4, 2))
    }

    @Test func fittedScaleUsesLongestHorizontalExtent() {
        // Y is the tallest axis but must not drive the fit.
        let bounds = SplatBounds(minimum: .zero, maximum: SIMD3(2, 100, 4))
        #expect(bounds.longestHorizontalExtent == 4)
        #expect(bounds.fittedScale(targetExtent: 1.5) == 0.375)
        #expect(bounds.fittedScale(targetExtent: 4) == 1)
    }

    @Test func fittedScaleIsClamped() {
        let tiny = SplatBounds(minimum: .zero, maximum: SIMD3(1e-6, 0, 0))
        #expect(tiny.fittedScale(targetExtent: 1.5) == SplatScale.range.upperBound)
        let huge = SplatBounds(minimum: .zero, maximum: SIMD3(1e7, 0, 0))
        #expect(huge.fittedScale(targetExtent: 1.5) == SplatScale.range.lowerBound)
        let bounds = SplatBounds(minimum: .zero, maximum: SIMD3(1, 0, 0))
        #expect(bounds.fittedScale(targetExtent: 5, clampedTo: 0.1...2) == 2)
    }

    @Test func infiniteExtentFallsBackToAuthored() {
        let bounds = SplatBounds(minimum: SIMD3(-.infinity, 0, 0), maximum: SIMD3(.infinity, 0, 0))
        #expect(bounds.fittedScale(targetExtent: 1.5) == SplatScale.authored)
    }
}
