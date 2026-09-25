//
//  SplatSceneStateTests.swift
//  LustreTests
//

import Foundation
import Testing
import simd
@testable import Lustre

@MainActor
struct SplatSceneStateTests {

    private func state(fitted: Float, initial: Float) -> SplatSceneState {
        let state = SplatSceneState()
        state.fittedScale = fitted
        state.initialScale = initial
        state.scale = 42
        state.translation = SIMD3(1, 2, 3)
        state.yaw = 1
        state.pitch = 0.5
        state.roll = 0.25
        return state
    }

    @Test func resetReturnsToInitialScaleNotFitted() {
        let state = state(fitted: 0.3, initial: SplatScale.authored)
        state.resetPlacement()
        #expect(state.scale == SplatScale.authored)
        #expect(state.translation == .zero)
        #expect(state.yaw == 0 && state.pitch == 0 && state.roll == 0)
    }

    @Test func resetKeepsAssetMetadata() {
        let state = state(fitted: 0.3, initial: 0.7)
        state.pivot = SIMD3(5, 5, 5)
        state.resetPlacement()
        #expect(state.fittedScale == 0.3)
        #expect(state.initialScale == 0.7)
        #expect(state.pivot == SIMD3(5, 5, 5))
    }

    @Test func fitUsesFittedScale() {
        let state = state(fitted: 0.3, initial: SplatScale.authored)
        state.fitToView()
        #expect(state.scale == 0.3)
    }
}
