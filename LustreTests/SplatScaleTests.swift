//
//  SplatScaleTests.swift
//  LustreTests
//

import Foundation
import Testing
@testable import Lustre

struct SplatScaleTests {

    @Test func sliderEndsMapToRangeEnds() {
        #expect(SplatScale.sliderPosition(for: SplatScale.range.lowerBound) == 0)
        #expect(abs(SplatScale.sliderPosition(for: SplatScale.range.upperBound) - 1) < 1e-6)
    }

    @Test func sliderIsLogarithmic() {
        // Six decades centered on 1: authored scale sits at the midpoint.
        #expect(abs(SplatScale.sliderPosition(for: 1) - 0.5) < 1e-5)
        let perDecade = SplatScale.sliderPosition(for: 10) - SplatScale.sliderPosition(for: 1)
        #expect(abs(perDecade - 1.0 / 6.0) < 1e-5)
    }

    @Test("Slider round-trips", arguments: [Float(0.001), 0.02, 0.5, 1, 3.7, 250, 1000])
    func sliderRoundTrip(scale: Float) {
        let back = SplatScale.scale(forSliderPosition: SplatScale.sliderPosition(for: scale))
        #expect(abs(back - scale) / scale < 1e-4)
    }

    @Test func sliderPositionIsClampedToUnitInterval() {
        #expect(SplatScale.scale(forSliderPosition: -1) == SplatScale.range.lowerBound)
        #expect(SplatScale.scale(forSliderPosition: 2) == SplatScale.range.upperBound)
    }

    @Test("Degenerate scales clamp to the smallest usable value",
          arguments: [Float.nan, 0, -1, -.infinity, .infinity])
    func clampDegenerate(scale: Float) {
        #expect(SplatScale.clamp(scale) == SplatScale.range.lowerBound)
    }

    @Test func clampBoundsFiniteValues() {
        #expect(SplatScale.clamp(1e-6) == SplatScale.range.lowerBound)
        #expect(SplatScale.clamp(1e6) == SplatScale.range.upperBound)
        #expect(SplatScale.clamp(2.5) == 2.5)
    }

    @Test("Formatting scales its precision with magnitude", arguments: [
        (Float(0.005), "0.0050×"),
        (0.05, "0.050×"),
        (1, "1.00×"),
        (42, "42.0×"),
        (150, "150×"),
    ])
    func formatted(scale: Float, expected: String) {
        #expect(SplatScale.formatted(scale) == expected)
    }
}
