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

    private var memoryWarningObserver: (any NSObjectProtocol)?

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
        // linearization, UV transform — is exercisable without a camera.
        // Everything except the ARKit plumbing gets verified here.
        let pattern = TestPatternCameraSource(device: device)
        testPatternSource = pattern
        renderer.setCameraFrameSource(pattern)
        #endif
    }

    var statusMessage: String? { poseProvider.statusMessage }

    /// Camera-to-world, for building a `CameraRelativeBasis` at gesture start.
    var cameraTransform: simd_float4x4 { poseProvider.pose.transform }

    var isPassthroughAvailable: Bool { renderer?.isPassthroughAvailable ?? false }

    func onAppear() {
        poseProvider.start()
        observeMemoryWarnings()
    }

    func onDisappear() {
        poseProvider.stop()
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
            self.memoryWarningObserver = nil
        }
    }

    func recenter() {
        poseProvider.recenter()
    }

    // MARK: - Background

    func setBackground(_ background: ViewerUIState.Background) {
        uiState.background = background
        renderer?.setPassthroughEnabled(background == .camera)
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
        // Authored Y-up in our own coordinates at a deliberate origin and in
        // real meters, so it skips the flip, the pivot, and the auto-fit that
        // real 3DGS captures all need.
        await load(name: "Sample Room", appliesUpCalibration: false, hasAuthoredPlacement: true) {
            SampleSplatScene.generate()
        }
    }

    func load(url: URL) async {
        // SfM output: arbitrary frame, arbitrary origin, arbitrary scale, so
        // every correction applies.
        await load(name: url.lastPathComponent, appliesUpCalibration: true, hasAuthoredPlacement: false) {
            try await SplatFileIO.loadPoints(from: url)
        }
    }

    private func load(name: String,
                      appliesUpCalibration: Bool,
                      hasAuthoredPlacement: Bool,
                      producePoints: @escaping @Sendable () async throws -> [SplatPoint]) async {
        guard let renderer else { return }

        sceneState.loadState = .loading(name)
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

            try await renderer.load(points: scene.points)
            applyPlacement(for: scene.bounds,
                           appliesUpCalibration: appliesUpCalibration,
                           hasAuthoredPlacement: hasAuthoredPlacement)
            sceneState.loadState = .loaded(name: name, splatCount: scene.points.count)
        } catch {
            sceneState.loadState = .failed(error.localizedDescription)
        }
    }

    private func applyPlacement(for bounds: SplatBounds?,
                                appliesUpCalibration: Bool,
                                hasAuthoredPlacement: Bool) {
        sceneState.appliesUpCalibration = appliesUpCalibration

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
