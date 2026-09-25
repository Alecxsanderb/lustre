//
//  SimulatedPoseProviderTests.swift
//  LustreTests
//

import Foundation
import Testing
import simd
@testable import Lustre

@MainActor
struct SimulatedPoseProviderTests {

    @Test func defaultSpeedIsThePreferenceDefault() {
        #expect(SimulatedPoseProvider().metersPerSecond == AppPreferences.defaults.joystickSpeed)
    }

    @Test("Forward travel follows the speed", arguments: [Float(0.5), 1.8, 5])
    func travelScalesWithSpeed(speed: Float) {
        let provider = SimulatedPoseProvider()
        let start = provider.pose.position
        provider.metersPerSecond = speed
        provider.moveInput = SIMD2(0, 1)
        provider.update(deltaTime: 0.25)

        // Unrotated, forward is -Z.
        let moved = provider.pose.position - start
        #expect(abs(moved.z + speed * 0.25) < 1e-5)
        #expect(abs(moved.x) < 1e-5 && abs(moved.y) < 1e-5)
    }
}
