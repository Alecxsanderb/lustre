//
//  ViewerModel.swift
//  Lustre
//
//  Wires the Viewer's pieces together: picks a pose provider for the current
//  environment, owns the renderer, and drives loading.
//

import Foundation
import Metal
import Observation
import UIKit
import simd
import SplatIO

@MainActor
@Observable
final class ViewerModel {

    /// Points plus the bounds derived from them, so both cross the actor
    /// boundary from the loading task in one hop.
    private struct LoadedScene: Sendable {
        let points: [SplatPoint]
        let bounds: SplatBounds?
    }

    /// What to re-read when the quality budget changes. The parsed points
    /// aren't retained — a second copy of a multi-million-point capture is the
    /// one allocation an iPhone can't spare — so re-reading is the only way
    /// back to a different budget.
    private enum LoadSource {
        case sample
        case file(URL)
    }

    let sceneState = SplatSceneState()
    let uiState = ViewerUIState()
    let poseProvider: any PoseProvider
    private(set) var renderer: SplatRenderer?

    /// Non-nil when the pose is simulated, which is what the joystick overlay
    /// binds to. Nil on a device with working AR.
    let simulatedProvider: SimulatedPoseProvider?

    /// Set when Metal or the renderer couldn't be created at all, e.g. no GPU.
    private(set) var initializationError: String?

    /// Kept alive so the renderer's weak reference stays valid; only used in
    /// the simulator, where no pose provider supplies camera frames.
    private var testPatternSource: TestPatternCameraSource?

    /// Nil where the pose provider can't find surfaces. Placement then falls
    /// back to committing wherever the splat already is.
    private var surfaceProvider: (any SurfaceProvider)?

    private var memoryWarningObserver: (any NSObjectProtocol)?
    private var lastLoadSource: LoadSource?

    /// Guards against overlapping loads. The UI already disables the import
    /// button and the quality picker while loading, but two concurrent loads
    /// would interleave `removeAllChunks` and `addChunk` on the same renderer,
    /// so this doesn't rely on the view layer getting it right.
    private var isLoading = false

    /// Tracked here rather than asked of the provider so the scene-phase path
    /// works the same through the `PoseProvider` protocol for every
    /// implementation, and never starts one twice.
    private var isViewerVisible = false
    private var isPoseProviderRunning = false

    init() {
        // Device first: `ARKitPoseProvider` needs it for its texture cache.
        let device = MTLCreateSystemDefaultDevice()
        let provider = Self.makeProvider(device: device)
        poseProvider = provider
        simulatedProvider = provider as? SimulatedPoseProvider

        guard let device else {
            initializationError = "This device has no Metal GPU, so splats can't be rendered."
            return
        }
        guard let renderer = SplatRenderer(device: device,
                                           sceneState: sceneState,
                                           poseProvider: provider) else {
            initializationError = "Couldn't create a Metal command queue."
            return
        }
        self.renderer = renderer
        attachCameraFrameSource(to: renderer, provider: provider, device: device)

        surfaceProvider = provider as? any SurfaceProvider
        renderer.anchorTransformSource = { [weak self] in
            self?.currentAnchorTransform ?? matrix_identity_float4x4
        }
        renderer.surfaceStateSource = { [weak self] in
            guard let self else { return nil }
            return (planes: surfaceProvider?.detectedPlanes ?? [],
                    isPlacing: sceneState.placementState == .awaitingSurface)
        }
    }

    /// ARKit is unavailable in the simulator and on older hardware; the
    /// joystick provider is the fallback in both cases.
    private static func makeProvider(device: MTLDevice?) -> any PoseProvider {
        #if targetEnvironment(simulator)
        return SimulatedPoseProvider()
        #else
        guard let device, ARKitPoseProvider.isSupported else { return SimulatedPoseProvider() }
        return ARKitPoseProvider(device: device)
        #endif
    }

    private func attachCameraFrameSource(to renderer: SplatRenderer,
                                         provider: any PoseProvider,
                                         device: MTLDevice) {
        if let cameraSource = provider as? any CameraFrameSource {
            renderer.setCameraFrameSource(cameraSource)
            return
        }
        #if targetEnvironment(simulator)
        // Synthetic frames so the composite path — premultiplied alpha, sRGB
        // linearization, UV transform, and now the occlusion depth compare —
        // is exercisable without a camera. Everything except the ARKit
        // plumbing gets verified here.
        let pattern = TestPatternCameraSource(device: device)
        testPatternSource = pattern
        renderer.setCameraFrameSource(pattern)
        #endif
    }

    var statusMessage: String? { poseProvider.statusMessage }

    /// Camera-to-world, for building a `CameraRelativeBasis` at gesture start.
    var cameraTransform: simd_float4x4 { poseProvider.pose.transform }

    var isPassthroughAvailable: Bool { renderer?.isPassthroughAvailable ?? false }

    var isPlacementAvailable: Bool { surfaceProvider != nil }

    /// Occlusion needs both halves: surfaces to occlude with, and a camera
    /// image to reveal underneath. Without the camera it would just delete
    /// splats against black.
    var isOcclusionAvailable: Bool { isPlacementAvailable && isPassthroughAvailable }

    /// Chunks drawn vs. total, or nil when the splat is a single chunk and
    /// there's nothing to report.
    var cullingSummary: (visibleChunks: Int, totalChunks: Int, visibleSplats: Int)? {
        guard sceneState.chunkCount > 1 else { return nil }
        return (sceneState.visibleChunkCount, sceneState.chunkCount, sceneState.visibleSplatCount)
    }


    /// What the placement UI shows while awaiting a surface.
    var placementCandidate: PlacementCandidate? { surfaceProvider?.placementCandidate }

    var isAwaitingPlacement: Bool { sceneState.placementState == .awaitingSurface }

    /// Interval one small notch on the axis bars represents, for the menu —
    /// the gizmo draws no text, so this is the only place the marks get named.
    var rulerDescription: (minor: String, major: String)? {
        guard uiState.showsPlacementIndicators, uiState.showsMeasuringTicks else { return nil }
        let ruler = RulerScale.fitting(axisLength: sceneState.indicatorAxisLength,
                                       units: uiState.rulerUnits)
        return (ruler.minorTickDescription, ruler.majorTickDescription)
    }

    /// The splat's world anchor for this frame.
    ///
    /// While placing, it tracks the crosshair so the splat previews where it
    /// will land. Once placed it comes from the anchor, re-read every frame so
    /// platform map refinements move the splat with the world instead of
    /// letting it drift.
    var currentAnchorTransform: simd_float4x4 {
        switch sceneState.placementState {
        case .awaitingSurface:
            return placementCandidate?.transform ?? sceneState.placedTransform
        case .placed:
            if let anchorID = sceneState.anchorID,
               let transform = surfaceProvider?.anchorTransform(for: anchorID) {
                return transform
            }
            return sceneState.placedTransform
        }
    }

    // MARK: - Placement

    /// Enters placement mode. Called after every load, and from the menu to
    /// re-place an already-placed splat.
    func beginPlacement() {
        guard isPlacementAvailable else { return }
        if let anchorID = sceneState.anchorID {
            surfaceProvider?.removeAnchor(anchorID)
            sceneState.anchorID = nil
        }
        sceneState.placementState = .awaitingSurface
        syncSurfaceDetection()
    }

    func confirmPlacement() {
        guard sceneState.placementState == .awaitingSurface else { return }
        let transform = placementCandidate?.transform ?? sceneState.placedTransform
        sceneState.placedTransform = transform
        sceneState.anchorID = surfaceProvider?.makeAnchor(at: transform)
        sceneState.placementState = .placed
        syncSurfaceDetection()
    }

    // MARK: - Indicators and occlusion

    func setIndicatorsEnabled(_ enabled: Bool) {
        uiState.showsPlacementIndicators = enabled
        renderer?.setIndicatorsEnabled(enabled)
        syncIndicatorStyle()
        syncSurfaceDetection()
    }

    func setMeasuringTicksEnabled(_ enabled: Bool) {
        uiState.showsMeasuringTicks = enabled
        syncIndicatorStyle()
    }

    func setRulerUnits(_ units: RulerUnits) {
        uiState.rulerUnits = units
        syncIndicatorStyle()
    }

    func setOcclusionEnabled(_ enabled: Bool) {
        uiState.occludesBehindSurfaces = enabled
        applyOcclusionSetting()
        syncSurfaceDetection()
    }

    private func syncIndicatorStyle() {
        renderer?.rulerUnits = uiState.showsMeasuringTicks ? uiState.rulerUnits : nil
    }

    /// Occlusion is only armed when the camera background is actually showing.
    private func applyOcclusionSetting() {
        renderer?.setOcclusionEnabled(uiState.occludesBehindSurfaces && uiState.background == .camera)
    }

    /// Surface detection runs only when something needs it — the indicators, an
    /// active placement, or occlusion. It costs CPU every frame otherwise.
    private func syncSurfaceDetection() {
        let occlusionNeedsSurfaces = uiState.occludesBehindSurfaces && uiState.background == .camera
        surfaceProvider?.isSurfaceDetectionEnabled =
            uiState.showsPlacementIndicators
            || sceneState.placementState == .awaitingSurface
            || occlusionNeedsSurfaces
    }

    func onAppear() {
        isViewerVisible = true
        startPoseProvider()
        observeMemoryWarnings()
        // Apply the defaults; nothing has pushed them to the renderer yet.
        renderer?.setPassthroughEnabled(uiState.background == .camera)
        applyOcclusionSetting()
        syncIndicatorStyle()
        syncSurfaceDetection()
    }

    func onDisappear() {
        isViewerVisible = false
        stopPoseProvider()
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
            self.memoryWarningObserver = nil
        }
    }

    /// Releases the camera and tracking while the app is backgrounded rather
    /// than leaving it to the platform.
    func onEnterBackground() {
        stopPoseProvider()
    }

    /// Only restarts if the Viewer is actually on screen; a foregrounded app
    /// showing some other screen shouldn't power up the camera.
    func onBecomeActive() {
        guard isViewerVisible else { return }
        startPoseProvider()
    }

    private func startPoseProvider() {
        guard !isPoseProviderRunning else { return }
        poseProvider.start()
        isPoseProviderRunning = true
    }

    private func stopPoseProvider() {
        guard isPoseProviderRunning else { return }
        poseProvider.stop()
        isPoseProviderRunning = false
    }

    func recenter() {
        poseProvider.recenter()
    }

    // MARK: - Background

    func setBackground(_ background: ViewerUIState.Background) {
        uiState.background = background
        renderer?.setPassthroughEnabled(background == .camera)
        applyOcclusionSetting()
        syncSurfaceDetection()
    }

    /// The offscreen passthrough targets are the largest allocation we can hand
    /// back immediately. The splat itself is usually the real memory problem,
    /// but dropping it would lose the user's work.
    private func observeMemoryWarnings() {
        guard memoryWarningObserver == nil else { return }
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.renderer?.releaseDiscretionaryResources()
                }
            }
    }

    // MARK: - Loading

    func loadSample() async {
        lastLoadSource = .sample
        // Authored Y-up in our own coordinates at a deliberate origin and in
        // real meters, so it skips the flip, the pivot, and the auto-fit that
        // real 3DGS captures all need.
        await load(name: "Sample Room", appliesUpCalibration: false, hasAuthoredPlacement: true) {
            SampleSplatScene.generate()
        }
    }

    func load(url: URL) async {
        lastLoadSource = .file(url)
        // SfM output: arbitrary frame, arbitrary origin, arbitrary scale, so
        // every correction applies.
        await load(name: url.lastPathComponent, appliesUpCalibration: true, hasAuthoredPlacement: false) {
            try await SplatFileIO.loadPoints(from: url)
        }
    }

    /// Re-reads the current splat. The only way to change the quality budget,
    /// since the parsed points aren't kept.
    func setQuality(_ quality: SplatQuality) async {
        guard quality != uiState.quality else { return }
        uiState.quality = quality
        switch lastLoadSource {
        case .sample: await loadSample()
        case .file(let url): await load(url: url)
        case nil: break
        }
    }

    private func load(name: String,
                      appliesUpCalibration: Bool,
                      hasAuthoredPlacement: Bool,
                      producePoints: @escaping @Sendable () async throws -> [SplatPoint]) async {
        guard let renderer, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        sceneState.loadState = .loading(name)
        let quality = uiState.quality
        do {
            // Off the main actor: generating the sample room, parsing a
            // multi-megabyte PLY, and the bounds pass are all long enough to
            // drop frames.
            let scene = try await Task.detached(priority: .userInitiated) {
                let points = try await producePoints()
                // `lazy` matters: an eager map would allocate another copy of
                // every position, ~60 MB at 5M splats, on top of the decode peak.
                let bounds = SplatBounds.robust(of: points.lazy.map(\.position))
                return LoadedScene(points: points, bounds: bounds)
            }.value

            let sourceCount = scene.points.count
            let loadedCount = try await renderer.load(points: scene.points,
                                                      bounds: scene.bounds,
                                                      quality: quality)
            applyPlacement(for: scene.bounds,
                           appliesUpCalibration: appliesUpCalibration,
                           hasAuthoredPlacement: hasAuthoredPlacement)
            sceneState.sourceSplatCount = loadedCount < sourceCount ? sourceCount : nil
            sceneState.loadState = .loaded(name: name, splatCount: loadedCount)
            // Ask the user where it goes rather than dropping it on their face.
            beginPlacement()
        } catch {
            sceneState.loadState = .failed(error.localizedDescription)
        }
    }

    private func applyPlacement(for bounds: SplatBounds?,
                                appliesUpCalibration: Bool,
                                hasAuthoredPlacement: Bool) {
        sceneState.appliesUpCalibration = appliesUpCalibration
        // Drives the length of the measuring axes, so it's set either way.
        sceneState.assetExtent = bounds?.extent ?? .zero

        if hasAuthoredPlacement {
            // The author already chose the origin and the units — re-centering
            // on the bounding box would shift a deliberately placed scene, and
            // rescaling a metric one is just wrong.
            sceneState.pivot = .zero
            sceneState.fittedScale = SplatScale.authored
        } else {
            // SfM output: the origin can sit anywhere relative to the points and
            // the units are arbitrary, so derive both. Pivot is in raw asset
            // coordinates, which is what the model matrix subtracts first —
            // before the up-calibration flip.
            sceneState.pivot = bounds?.center ?? .zero
            sceneState.fittedScale = bounds?.fittedScale(targetExtent: SplatSceneState.autoFitExtent)
                ?? SplatScale.authored
        }
        sceneState.resetPlacement()
    }
}
