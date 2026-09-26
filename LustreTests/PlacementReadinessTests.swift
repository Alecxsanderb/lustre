//
//  PlacementReadinessTests.swift
//  LustreTests
//
//  The placement overlay can only observe readiness, never the per-frame
//  candidate. These pin the mapping from candidate to readiness to overlay,
//  and that providers publish readiness only when it changes.
//

import Foundation
import Observation
import Testing
import simd
@testable import Lustre

@MainActor
struct PlacementReadinessTests {

    // MARK: - Candidate → readiness

    @Test func noCandidateIsUnavailable() {
        #expect(PlacementReadiness(candidate: nil) == .unavailable)
    }

    @Test func estimatedCandidateIsEstimated() {
        let candidate = PlacementCandidate(transform: matrix_identity_float4x4, isOnSurface: false)
        #expect(PlacementReadiness(candidate: candidate) == .estimated)
    }

    @Test func surfaceCandidateIsOnSurface() {
        let candidate = PlacementCandidate(transform: matrix_identity_float4x4, isOnSurface: true)
        #expect(PlacementReadiness(candidate: candidate) == .onSurface)
    }

    // MARK: - Readiness → overlay

    @Test func onSurfaceOffersProminentPlace() {
        let presentation = PlacementOverlay.Presentation(readiness: .onSurface, statusMessage: nil)
        #expect(presentation.isButtonEnabled)
        #expect(presentation.buttonTitle == "Place")
        #expect(presentation.buttonEmphasis == .grounded)
        #expect(presentation.isOnSurface)
    }

    /// The device bug: this state must be tappable.
    @Test func estimatedOffersEnabledPlaceAnyway() {
        let presentation = PlacementOverlay.Presentation(readiness: .estimated, statusMessage: nil)
        #expect(presentation.isButtonEnabled)
        #expect(presentation.buttonTitle == "Place anyway")
        #expect(presentation.buttonEmphasis == .tentative)
        #expect(!presentation.isOnSurface)
    }

    @Test func unavailableDisablesAndSaysTrackingIsStarting() {
        let presentation = PlacementOverlay.Presentation(readiness: .unavailable, statusMessage: nil)
        #expect(!presentation.isButtonEnabled)
        #expect(presentation.bannerText == PlacementOverlay.Presentation.startingTrackingText)
    }

    @Test func unavailablePrefersTheProviderStatusMessage() {
        let message = "Slow down — moving too fast to track."
        let presentation = PlacementOverlay.Presentation(readiness: .unavailable, statusMessage: message)
        #expect(presentation.bannerText == message)
    }

    // MARK: - Simulated provider

    @Test func inactivePlacementIsUnavailableWithNoCandidate() {
        let provider = SimulatedPoseProvider()
        provider.isSurfaceDetectionEnabled = true
        #expect(provider.placementReadiness == .unavailable)
        #expect(provider.placementCandidate == nil)
    }

    @Test func lookingLevelIsEstimated() {
        let provider = activeProvider()
        #expect(provider.placementReadiness == .estimated)
    }

    @Test func lookingDownAtTheFloorIsOnSurface() {
        let provider = activeProvider()
        lookDown(provider)
        #expect(provider.placementReadiness == .onSurface)
    }

    @Test func endingPlacementReturnsToUnavailable() {
        let provider = activeProvider()
        provider.isPlacementActive = false
        #expect(provider.placementReadiness == .unavailable)
    }

    /// Observation notifies on every assignment, equal or not; a provider that
    /// wrote readiness every frame would re-render the overlay at 60 Hz.
    @Test func readinessNotifiesOnlyWhenItChanges() {
        let provider = activeProvider()
        lookDown(provider)

        var notified = false
        withObservationTracking {
            _ = provider.placementReadiness
        } onChange: {
            notified = true
        }

        // Still on the floor after a small move: the candidate changes, the
        // readiness doesn't.
        provider.moveInput = SIMD2(0.2, 0)
        provider.update(deltaTime: 0.1)
        provider.moveInput = .zero
        #expect(provider.placementReadiness == .onSurface)
        #expect(!notified)

        // Look back up to level: now it does change.
        provider.lookInput = SIMD2(0, 1)
        provider.update(deltaTime: 0.4)
        #expect(provider.placementReadiness == .estimated)
        #expect(notified)
    }

    // MARK: - Model wiring

    #if targetEnvironment(simulator)
    @Test func modelActivatesPlacementOnlyWhileAwaitingSurface() throws {
        let model = ViewerModel()
        let provider = try #require(model.simulatedProvider)

        model.beginPlacement()
        #expect(provider.isPlacementActive)
        #expect(model.placementReadiness == .estimated)

        model.confirmPlacement()
        #expect(!provider.isPlacementActive)
        #expect(model.placementReadiness == .unavailable)
    }
    #endif

    // MARK: - Helpers

    private func activeProvider() -> SimulatedPoseProvider {
        let provider = SimulatedPoseProvider()
        provider.isSurfaceDetectionEnabled = true
        provider.isPlacementActive = true
        return provider
    }

    /// Pitches down ~37°, which puts the synthetic floor 2.5 m ahead.
    private func lookDown(_ provider: SimulatedPoseProvider) {
        provider.lookInput = SIMD2(0, -1)
        provider.update(deltaTime: 0.4)
        provider.lookInput = .zero
    }
}
