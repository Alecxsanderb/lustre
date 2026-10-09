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

    // MARK: - Recenter

    /// At (1, 1.4, 2), facing -X and pitched 30° down at the floor.
    private static let recenterCamera = matrix4x4_translation(1, 1.4, 2)
        * matrix4x4_rotation(radians: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        * matrix4x4_rotation(radians: -.pi / 6, axis: SIMD3<Float>(1, 0, 0))

    /// Placed on a raycast-style anchor carrying its own yaw, then nudged,
    /// scaled, and rotated by the user.
    private static func placedModel() -> (ViewerModel, StubSurfacePoseProvider) {
        let provider = StubSurfacePoseProvider()
        provider.candidate = PlacementCandidate(
            transform: matrix4x4_translation(0, 0, -2)
                * matrix4x4_rotation(radians: 0.7, axis: SIMD3<Float>(0, 1, 0)),
            isOnSurface: true)
        let model = ViewerModel(makeProvider: { _ in provider })
        model.beginPlacement()
        model.confirmPlacement()
        model.sceneState.translation = SIMD3(0.3, 0.1, -0.2)
        model.sceneState.scale = 0.4
        model.sceneState.yaw = 1.1
        provider.pose = CameraPose(transform: recenterCamera)
        return (model, provider)
    }

    @Test func recenterReanchorsAPlacedSplatInFrontOfTheCamera() throws {
        let (model, provider) = Self.placedModel()
        let oldAnchor = try #require(model.sceneState.anchorID)

        model.recenter()

        let newAnchor = try #require(model.sceneState.anchorID)
        #expect(newAnchor != oldAnchor)
        #expect(provider.anchors[oldAnchor] == nil)
        #expect(provider.anchors.count == 1)

        // Level with the camera and `distance` along its flattened heading,
        // not down the pitched view ray into the floor.
        let anchor = try #require(provider.anchors[newAnchor])
        let expected = SIMD3<Float>(1 - PlacementFallback.distance, 1.4, 2)
        #expect(simd_distance(anchor.columns.3.xyz, expected) < 1e-4)
        #expect(model.sceneState.placedTransform == anchor)
        #expect(model.currentAnchorTransform == anchor)

        #expect(model.sceneState.translation == .zero)
        #expect(model.sceneState.scale == 0.4)
        #expect(model.sceneState.yaw == 1.1)
        #expect(model.sceneState.placementState == .placed)
    }

    /// The old anchor's heading survives, so the splat doesn't visibly spin.
    @Test func recenterKeepsTheAnchorHeading() throws {
        let (model, provider) = Self.placedModel()
        model.recenter()
        let anchor = try #require(model.sceneState.anchorID.flatMap { provider.anchors[$0] })
        let expected = matrix4x4_rotation(radians: 0.7, axis: SIMD3<Float>(0, 1, 0))
        for column in 0..<3 {
            #expect(simd_distance(anchor[column], expected[column]) < 1e-4)
        }
    }

    @Test func recenterWhileAwaitingPlacementIsANoOp() {
        let (model, provider) = Self.placedModel()
        model.beginPlacement()
        let anchors = provider.anchors
        let placed = model.sceneState.placedTransform
        let translation = model.sceneState.translation

        model.recenter()

        #expect(model.sceneState.placementState == .awaitingSurface)
        #expect(model.sceneState.anchorID == nil)
        #expect(provider.anchors == anchors)
        #expect(model.sceneState.placedTransform == placed)
        #expect(model.sceneState.translation == translation)
        #expect(provider.recenterCount == 1)
    }

    /// The simulator resets its joystick camera, then the splat lands ahead
    /// of where it reset to.
    @Test func simulatedRecenterResetsTheCameraAndFollowsIt() throws {
        let provider = SimulatedPoseProvider()
        let model = ViewerModel(makeProvider: { _ in provider })
        let start = provider.pose
        model.beginPlacement()
        model.confirmPlacement()
        provider.moveInput = SIMD2(1, 1)
        provider.lookInput = SIMD2(1, 0)
        provider.update(deltaTime: 0.4)
        #expect(provider.pose != start)

        model.recenter()

        #expect(provider.pose == start)
        let anchor = try #require(model.sceneState.anchorID.flatMap { provider.anchorTransform(for: $0) })
        let expected = start.position + SIMD3(0, 0, -PlacementFallback.distance)
        #expect(simd_distance(anchor.columns.3.xyz, expected) < 1e-4)
    }

    /// The second Recenter must remove the anchor the first one made, not
    /// only the original. On device that anchor may not have reached a frame
    /// yet, which is what used to orphan it.
    @Test func doubleRecenterRemovesTheFirstRecenterAnchor() throws {
        let (model, provider) = Self.placedModel()
        let original = try #require(model.sceneState.anchorID)

        model.recenter()
        let first = try #require(model.sceneState.anchorID)
        model.recenter()
        let second = try #require(model.sceneState.anchorID)

        #expect(provider.removedAnchorIDs == [original, first])
        #expect(Set(provider.anchors.keys) == [second])
    }

    /// No anchor (e.g. the session isn't running) still moves the splat:
    /// the unanchored placed transform is what renders.
    @Test func recenterWhenMakeAnchorFailsFallsBackToThePlacedTransform() throws {
        let (model, provider) = Self.placedModel()
        let original = try #require(model.sceneState.anchorID)
        provider.makesAnchors = false

        model.recenter()

        #expect(model.sceneState.anchorID == nil)
        #expect(provider.removedAnchorIDs == [original])
        #expect(provider.anchors.isEmpty)
        let expected = SIMD3<Float>(1 - PlacementFallback.distance, 1.4, 2)
        #expect(simd_distance(model.sceneState.placedTransform.columns.3.xyz, expected) < 1e-4)
        #expect(model.currentAnchorTransform == model.sceneState.placedTransform)
        #expect(model.sceneState.translation == .zero)
    }

    /// Before tracking gets going the pose is a placeholder; anchoring there
    /// would put the splat at the world origin, not in front of the user.
    @Test func recenterWithoutATrackedPoseIsANoOp() {
        let (model, provider) = Self.placedModel()
        provider.hasTrackedPose = false
        #expect(!model.canRecenter)
        let anchorID = model.sceneState.anchorID
        let anchors = provider.anchors
        let placed = model.sceneState.placedTransform
        let translation = model.sceneState.translation

        model.recenter()

        #expect(model.sceneState.anchorID == anchorID)
        #expect(provider.anchors == anchors)
        #expect(provider.removedAnchorIDs.isEmpty)
        #expect(model.sceneState.placedTransform == placed)
        #expect(model.sceneState.translation == translation)
        #expect(provider.recenterCount == 0)

        provider.hasTrackedPose = true
        #expect(model.canRecenter)
    }

    @Test func simulatedProviderAlwaysAllowsRecenter() {
        let model = ViewerModel(makeProvider: { _ in SimulatedPoseProvider() })
        #expect(model.canRecenter)
    }

    @Test func recenterWithoutSurfacesOnlyRecentersTheProvider() {
        let provider = StubPoseProvider()
        let model = ViewerModel(makeProvider: { _ in provider })
        model.recenter()
        #expect(provider.recenterCount == 1)
        #expect(model.sceneState.anchorID == nil)
        #expect(model.sceneState.placedTransform == matrix_identity_float4x4)
    }

    /// Straight down has no horizontal forward; screen-up is where the user
    /// faces, so the splat goes there rather than onto the camera.
    @Test func recenterLookingStraightDownUsesScreenUp() {
        let camera = matrix4x4_translation(0, 1.5, 0)
            * matrix4x4_rotation(radians: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
        let target = ViewerModel.recenterAnchorTransform(cameraTransform: camera,
                                                         currentAnchor: matrix_identity_float4x4)
        let expected = SIMD3<Float>(0, 1.5, -PlacementFallback.distance)
        #expect(simd_distance(target.columns.3.xyz, expected) < 1e-4)
    }

    @Test func recenterLookingStraightUpUsesScreenDown() {
        let camera = matrix4x4_translation(0, 1.5, 0)
            * matrix4x4_rotation(radians: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        let target = ViewerModel.recenterAnchorTransform(cameraTransform: camera,
                                                         currentAnchor: matrix_identity_float4x4)
        let expected = SIMD3<Float>(0, 1.5, -PlacementFallback.distance)
        #expect(simd_distance(target.columns.3.xyz, expected) < 1e-4)
    }

    // MARK: Recenter heading near vertical

    /// Facing -X (yaw 90°) so a sign or axis slip can't pass by landing on -Z.
    private static func headingCamera(pitchDegrees: Float,
                                      rollDegrees: Float = 0,
                                      localYawDegrees: Float = 0) -> simd_float4x4 {
        let radians = Float.pi / 180
        return matrix4x4_translation(0, 1.5, 0)
            * matrix4x4_rotation(radians: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
            * matrix4x4_rotation(radians: pitchDegrees * radians, axis: SIMD3<Float>(1, 0, 0))
            * matrix4x4_rotation(radians: localYawDegrees * radians, axis: SIMD3<Float>(0, 1, 0))
            * matrix4x4_rotation(radians: rollDegrees * radians, axis: SIMD3<Float>(0, 0, 1))
    }

    /// Unit horizontal direction from the camera to the recenter target.
    private static func recenterDirection(_ camera: simd_float4x4) -> SIMD3<Float> {
        let target = ViewerModel.recenterAnchorTransform(cameraTransform: camera,
                                                         currentAnchor: matrix_identity_float4x4)
        let offset = target.columns.3.xyz - camera.columns.3.xyz
        #expect(abs(offset.y) < 1e-5)
        #expect(abs(simd_length(offset) - PlacementFallback.distance) < 1e-4)
        return simd_normalize(offset)
    }

    private static let facing = SIMD3<Float>(-1, 0, 0)

    @Test("Nearly vertical still lands where the user faces", arguments: [Float(-89), 89])
    func recenterNearVerticalLandsInFront(pitchDegrees: Float) {
        let direction = Self.recenterDirection(Self.headingCamera(pitchDegrees: pitchDegrees))
        #expect(simd_distance(direction, Self.facing) < 1e-4)
    }

    /// No jump anywhere in the pitch range: an unrolled phone always gets its
    /// facing direction, which the old hard switch at ~0.06° only did by luck.
    @Test func recenterHeadingIsSteadyAcrossPitch() {
        for step in -179...179 {
            let direction = Self.recenterDirection(Self.headingCamera(pitchDegrees: Float(step) / 2))
            #expect(simd_distance(direction, Self.facing) < 1e-4, "pitch \(Float(step) / 2)°")
        }
    }

    /// The flip bug: at 89.5° a 1° sideways wobble of the view direction used
    /// to swing the flattened forward ~60°. Screen-up barely moves, so now
    /// the heading barely moves.
    @Test("A small wobble near vertical doesn't swing the heading", arguments: [Float(-89.5), 89.5])
    func recenterNearVerticalIgnoresWobble(pitchDegrees: Float) {
        for wobble: Float in [-1, 1] {
            let camera = Self.headingCamera(pitchDegrees: pitchDegrees, localYawDegrees: wobble)
            let direction = Self.recenterDirection(camera)
            let degreesOff = acos(min(1, simd_dot(direction, Self.facing))) * 180 / .pi
            #expect(degreesOff < 2, "wobble \(wobble)°: \(degreesOff)° off")
        }
    }

    /// Below 60° the blend is fully off, so a rolled phone gets the exact
    /// flattened forward, as before.
    @Test func recenterAtOrdinaryPitchIgnoresRoll() {
        let camera = Self.headingCamera(pitchDegrees: -45, rollDegrees: 25)
        let forward = -camera.columns.2.xyz
        let expected = simd_normalize(SIMD3<Float>(forward.x, 0, forward.z))
        #expect(simd_distance(Self.recenterDirection(camera), expected) < 1e-5)
    }
}

/// A pose provider with no surfaces and no camera: the shape of a device
/// without AR.
@MainActor
private final class StubPoseProvider: PoseProvider {
    var pose = CameraPose.identity
    var verticalFieldOfView: Float = 1
    var hasTrackedPose = true
    private(set) var recenterCount = 0
    func start() {}
    func stop() {}
    func update(deltaTime: TimeInterval) {}
    func recenter() { recenterCount += 1 }
}

/// Shaped like ARKit for Recenter: surfaces and anchors, a camera the test
/// sets directly, and a `recenter()` that moves nothing.
@MainActor
private final class StubSurfacePoseProvider: PoseProvider, SurfaceProvider {
    var pose = CameraPose.identity
    var verticalFieldOfView: Float = 1
    var hasTrackedPose = true
    private(set) var recenterCount = 0
    func start() {}
    func stop() {}
    func update(deltaTime: TimeInterval) {}
    func recenter() { recenterCount += 1 }

    var candidate: PlacementCandidate?
    private(set) var anchors: [UUID: simd_float4x4] = [:]

    var isSurfaceDetectionEnabled = false
    var detectedPlanes: [DetectedPlane] { [] }
    var isPlacementActive = false
    var placementCandidate: PlacementCandidate? { isPlacementActive ? candidate : nil }
    var placementReadiness: PlacementReadiness { PlacementReadiness(candidate: placementCandidate) }

    /// False models ARKit's `makeAnchor` while the session isn't running.
    var makesAnchors = true

    func makeAnchor(at transform: simd_float4x4) -> UUID? {
        guard makesAnchors else { return nil }
        let id = UUID()
        anchors[id] = transform
        return id
    }

    func anchorTransform(for id: UUID) -> simd_float4x4? { anchors[id] }

    /// Every id passed to `removeAnchor`, in order, whether or not it existed.
    private(set) var removedAnchorIDs: [UUID] = []

    func removeAnchor(_ id: UUID) {
        removedAnchorIDs.append(id)
        anchors.removeValue(forKey: id)
    }
}
