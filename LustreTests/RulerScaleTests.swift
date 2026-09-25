//
//  RulerScaleTests.swift
//  LustreTests
//

import Foundation
import Testing
@testable import Lustre

struct RulerScaleTests {

    @Test("Metric spacing keeps ticks readable", arguments: [
        (Float(0.25), Float(0.05), "5 cm", "50 cm"),
        (0.01, 0.001, "1 mm", "1 cm"),
        (1.0, 0.1, "10 cm", "1 m"),
        (2.0, 0.25, "25 cm", "1 m"),
    ])
    func metric(axisLength: Float, spacing: Float, minor: String, major: String) {
        let ruler = RulerScale.fitting(axisLength: axisLength, units: .meters)
        #expect(ruler.spacing == spacing)
        #expect(ruler.minorTickDescription == minor)
        #expect(ruler.majorTickDescription == major)
    }

    @Test("Imperial spacing keeps ticks readable", arguments: [
        (Float(0.25), "1 in", "1 ft"),
        (0.8, "3 in", "1 ft"),
        (1.0, "6 in", "1 ft"),
        (2.0, "1 ft", "3 ft"),
    ])
    func imperial(axisLength: Float, minor: String, major: String) {
        let ruler = RulerScale.fitting(axisLength: axisLength, units: .feet)
        #expect(ruler.minorTickDescription == minor)
        #expect(ruler.majorTickDescription == major)
    }

    @Test("Tick count never exceeds the limit", arguments: [RulerUnits.meters, .feet])
    func tickCountBounded(units: RulerUnits) {
        for length in stride(from: Float(0.002), through: 20, by: 0.037) {
            let ruler = RulerScale.fitting(axisLength: length, units: units)
            #expect(length / ruler.spacing <= 12.0001, "axis \(length) m")
        }
    }

    @Test func oversizedAxisUsesTheCoarsestInterval() {
        #expect(RulerScale.fitting(axisLength: 10_000, units: .meters).spacing == 5)
    }

    @Test("Degenerate lengths use the finest interval", arguments: [Float(0), -1, 1e-9])
    func degenerateLength(length: Float) {
        #expect(RulerScale.fitting(axisLength: length, units: .meters).spacing == 0.001)
    }
}
