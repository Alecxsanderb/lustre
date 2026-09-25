//
//  ViewerModelTests.swift
//  LustreTests
//

import Foundation
import Testing
import simd
@testable import Lustre

@MainActor
struct ViewerModelTests {

    /// 4 m across the longest horizontal axis, so each preset's fitted scale
    /// is easy to read off: target / 4.
    private let bounds = SplatBounds(minimum: SIMD3(-2, -10, -1), maximum: SIMD3(2, 10, 1))

    @Test("Fitted presets open at their fit", arguments: [
        (AppPreferences.InitialSize.tabletop, Float(0.125)),
        (.dollhouse, 0.375),
        (.room, 1),
    ])
    func fittedPresets(size: AppPreferences.InitialSize, expected: Float) {
        let scales = ViewerModel.initialScales(for: bounds, initialSize: size, hasAuthoredPlacement: false)
        #expect(scales.fitted == expected)
        #expect(scales.initial == expected)
    }

    @Test func lifeSizeOpensAuthoredButFitStillFits() {
        let scales = ViewerModel.initialScales(for: bounds, initialSize: .lifeSize, hasAuthoredPlacement: false)
        #expect(scales.initial == SplatScale.authored)
        #expect(scales.fitted == SplatSceneState.autoFitExtent / 4)
    }

    @Test("Authored placement ignores the preference", arguments: AppPreferences.InitialSize.allCases)
    func authoredIgnoresPreference(size: AppPreferences.InitialSize) {
        let scales = ViewerModel.initialScales(for: bounds, initialSize: size, hasAuthoredPlacement: true)
        #expect(scales.fitted == SplatScale.authored)
        #expect(scales.initial == SplatScale.authored)
    }

    @Test("No bounds means authored", arguments: AppPreferences.InitialSize.allCases)
    func missingBounds(size: AppPreferences.InitialSize) {
        let scales = ViewerModel.initialScales(for: nil, initialSize: size, hasAuthoredPlacement: false)
        #expect(scales.fitted == SplatScale.authored)
        #expect(scales.initial == SplatScale.authored)
    }

    #if targetEnvironment(simulator)
    @Test func applySetsTheSimulatedJoystickSpeed() throws {
        let model = ViewerModel()
        let provider = try #require(model.simulatedProvider)
        model.apply(AppPreferences(initialSize: .room, joystickSpeed: 3.5))
        #expect(provider.metersPerSecond == 3.5)
    }
    #endif
}
