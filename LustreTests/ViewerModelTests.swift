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

    // MARK: - Display settings

    /// Every field differs from `ViewerDisplay.defaults`, so a field `apply`
    /// forgets can't pass by coinciding with `ViewerUIState`'s initial value.
    private static let customDisplay = AppPreferences.ViewerDisplay(
        areGesturesEnabled: false,
        locksToSingleAxis: true,
        showsPlacementIndicators: true,
        showsMeasuringTicks: false,
        rulerUnits: .feet,
        background: .black,
        occludesBehindSurfaces: true,
        quality: .balanced,
        expandedSection: nil,
        showsAdvancedRotation: true)

    private static func preferences(_ display: AppPreferences.ViewerDisplay) -> AppPreferences {
        AppPreferences(initialSize: .dollhouse, joystickSpeed: 1.8, viewerDisplay: display)
    }

    /// Has surfaces (the synthetic floor), so placement and indicators are
    /// available wherever the tests run.
    private static func modelWithSurfaces() -> ViewerModel {
        ViewerModel(makeProvider: { _ in SimulatedPoseProvider() })
    }

    @Test func applySetsEveryUIStateField() {
        let model = Self.modelWithSurfaces()
        model.apply(Self.preferences(Self.customDisplay))
        let ui = model.uiState
        #expect(ui.areGesturesEnabled == false)
        #expect(ui.locksToSingleAxis == true)
        #expect(ui.showsPlacementIndicators == true)
        #expect(ui.showsMeasuringTicks == false)
        #expect(ui.rulerUnits == .feet)
        #expect(ui.background == .black)
        #expect(ui.occludesBehindSurfaces == true)
        #expect(ui.quality == .balanced)
        #expect(ui.expandedSection == nil)
        #expect(ui.showsAdvancedRotation == true)
    }

    @Test func sessionOnlyStateIsNotApplied() {
        let model = Self.modelWithSurfaces()
        model.apply(Self.preferences(Self.customDisplay))
        #expect(model.uiState.isMenuExpanded == false)
    }

    /// Nil before `apply` is what lets the Viewer skip writing back the jump
    /// from the initial values to the stored ones.
    @Test func persistedDisplayWaitsForApply() {
        let model = Self.modelWithSurfaces()
        #expect(model.persistedDisplay == nil)
        model.apply(Self.preferences(Self.customDisplay))
        #expect(model.persistedDisplay == Self.customDisplay)
    }

    @Test func persistedDisplayFollowsUserChanges() {
        let model = Self.modelWithSurfaces()
        model.apply(Self.preferences(.defaults))

        model.uiState.areGesturesEnabled = false
        model.uiState.locksToSingleAxis = true
        model.setIndicatorsEnabled(true)
        model.setMeasuringTicksEnabled(false)
        model.setRulerUnits(.feet)
        model.setBackground(.black)
        model.setOcclusionEnabled(true)
        model.uiState.toggle(.display)
        model.uiState.showsAdvancedRotation = true

        var expected = AppPreferences.ViewerDisplay.defaults
        expected.areGesturesEnabled = false
        expected.locksToSingleAxis = true
        expected.showsPlacementIndicators = true
        expected.showsMeasuringTicks = false
        expected.rulerUnits = .feet
        expected.background = .black
        expected.occludesBehindSurfaces = true
        expected.expandedSection = .display
        expected.showsAdvancedRotation = true
        #expect(model.persistedDisplay == expected)

        model.uiState.toggle(.display)
        #expect(model.persistedDisplay?.expandedSection == nil)
    }

    /// Detail is a Settings default; changing it in the Viewer re-reads the
    /// splat on screen and nothing else.
    @Test func inViewerQualityIsNotPersisted() async {
        let model = Self.modelWithSurfaces()
        var display = AppPreferences.ViewerDisplay.defaults
        display.quality = .balanced
        model.apply(Self.preferences(display))

        await model.setQuality(.performance)
        #expect(model.uiState.quality == .performance)
        #expect(model.persistedDisplay?.quality == .balanced)
    }

    /// Save intent, not availability: a device without surfaces can't
    /// occlude, but that mustn't turn the user's setting off.
    @Test func unavailableOcclusionKeepsTheStoredSetting() {
        let model = ViewerModel(makeProvider: { _ in StubPoseProvider() })
        #expect(!model.isPlacementAvailable)
        #expect(!model.isOcclusionAvailable)

        var display = AppPreferences.ViewerDisplay.defaults
        display.occludesBehindSurfaces = true
        display.showsPlacementIndicators = true
        model.apply(Self.preferences(display))
        model.onAppear()
        defer { model.onDisappear() }

        #expect(model.uiState.occludesBehindSurfaces)
        #expect(!model.isOcclusionActive)
        #expect(model.uiState.showsPlacementIndicators)
        #expect(!model.areIndicatorsActive)
        #expect(model.rulerDescription == nil)
        #expect(model.persistedDisplay?.occludesBehindSurfaces == true)
        #expect(model.persistedDisplay?.showsPlacementIndicators == true)
    }

    /// A stored "indicators on" has to start surface detection at open, not
    /// only when the menu toggle is flipped.
    @Test func appliedIndicatorsStartSurfaceDetection() throws {
        let provider = SimulatedPoseProvider()
        let model = ViewerModel(makeProvider: { _ in provider })
        #expect(!provider.isSurfaceDetectionEnabled)

        var display = AppPreferences.ViewerDisplay.defaults
        display.showsPlacementIndicators = true
        model.apply(Self.preferences(display))
        model.onAppear()
        defer { model.onDisappear() }

        #expect(model.areIndicatorsActive)
        #expect(provider.isSurfaceDetectionEnabled)
        #expect(model.rulerDescription != nil)
    }

    #if targetEnvironment(simulator)
    /// The simulator's test-pattern camera makes occlusion available, so a
    /// stored setting should arm it (and surface detection) at open.
    @Test func appliedOcclusionStartsSurfaceDetection() {
        let provider = SimulatedPoseProvider()
        let model = ViewerModel(makeProvider: { _ in provider })
        var display = AppPreferences.ViewerDisplay.defaults
        display.occludesBehindSurfaces = true
        model.apply(Self.preferences(display))

        #expect(model.isOcclusionAvailable)
        #expect(model.isOcclusionActive)
        #expect(provider.isSurfaceDetectionEnabled)

        model.setBackground(.black)
        #expect(!model.isOcclusionActive)
        #expect(!provider.isSurfaceDetectionEnabled)
        #expect(model.uiState.occludesBehindSurfaces)
    }
    #endif
}

/// A pose provider with no surfaces and no camera: the shape of a device
/// without AR.
@MainActor
private final class StubPoseProvider: PoseProvider {
    var pose = CameraPose.identity
    var verticalFieldOfView: Float = 1
    func start() {}
    func stop() {}
    func update(deltaTime: TimeInterval) {}
    func recenter() {}
}
