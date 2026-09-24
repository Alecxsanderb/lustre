//
//  SplatRenderer.swift
//  Lustre
//
//  Lustre's render loop. Drives MetalSplatter's renderer from whatever
//  PoseProvider the Viewer handed us, so the same code path runs on device
//  (ARKit) and in the simulator (joysticks).
//
//  Note: this type shadows `MetalSplatter.SplatRenderer`. Unqualified
//  `SplatRenderer` in this app means *this* type; the library's is always
//  written out as `MetalSplatter.SplatRenderer`.
//
//  Frame order: splats (offscreen when compositing) → occluder depth →
//  camera composite → indicators, straight into the drawable.
//

import Foundation
import Metal
import MetalKit
import os
import simd
import MetalSplatter
import SplatIO

@MainActor
final class SplatRenderer: NSObject, MTKViewDelegate {

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Lustre",
                                    category: "SplatRenderer")

    /// Command buffers that may be outstanding at once. Anything writing
    /// CPU-visible buffers per frame needs this many copies, or it will
    /// overwrite data an earlier frame's GPU work is still reading.
    static let framesInFlight = 3

    private enum Constants {
        static let maxSimultaneousRenders = SplatRenderer.framesInFlight
        static let nearZ: Float = 0.05
        static let farZ: Float = 100.0
        static let colorFormat = MTLPixelFormat.bgra8Unorm_srgb
        static let depthFormat = MTLPixelFormat.depth32Float
        static let sampleCount = 1
    }

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let inFlightSemaphore = DispatchSemaphore(value: Constants.maxSimultaneousRenders)

    private var splatRenderer: MetalSplatter.SplatRenderer?
    private var drawableSize: CGSize = .zero
    private var lastFrameTimestamp: CFTimeInterval?

    private let sceneState: SplatSceneState
    private var poseProvider: any PoseProvider

    // MARK: - Culling

    private let culler = SplatChunkCuller()

    /// Copies the culler's counters into `SplatSceneState`, which is what the
    /// menu observes. Only on change: these are `@Observable` properties, and
    /// writing them every frame would re-render the viewer at display rate.
    private func publishCullingSummary() {
        let total = culler.isActive ? culler.chunkCount : 0
        guard sceneState.chunkCount != total
                || sceneState.visibleChunkCount != culler.visibleChunkCount
                || sceneState.visibleSplatCount != culler.visibleSplatCount
        else { return }
        sceneState.chunkCount = total
        sceneState.visibleChunkCount = culler.visibleChunkCount
        sceneState.visibleSplatCount = culler.visibleSplatCount
    }


    // MARK: - Passthrough

    private var isPassthroughEnabled = false
    private weak var cameraFrameSource: (any CameraFrameSource)?
    private var compositor: PassthroughCompositor?

    // MARK: - Occlusion

    private var isOcclusionEnabled = false
    private var occluderRenderer: OccluderRenderer?

    // MARK: - Placement

    /// Supplies the splat's world anchor each frame. Owned by `ViewerModel`,
    /// which holds the placement policy; the renderer only multiplies it in.
    var anchorTransformSource: (() -> simd_float4x4)?

    /// Supplies detected surfaces each frame, for both the indicators and the
    /// occlusion pass. Nil disables the indicator pass entirely.
    var surfaceStateSource: (() -> (planes: [DetectedPlane], isPlacing: Bool)?)?

    /// Units for the measuring notches, or nil for plain axis bars.
    var rulerUnits: RulerUnits?

    private var gizmoRenderer: GizmoRenderer?

    init?(device: MTLDevice, sceneState: SplatSceneState, poseProvider: any PoseProvider) {
        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        self.sceneState = sceneState
        self.poseProvider = poseProvider
        super.init()
    }

    /// Applies the pixel formats MetalSplatter was configured for. Must run
    /// before the first `draw(in:)`.
    func configure(_ view: MTKView) {
        view.device = device
        view.colorPixelFormat = Constants.colorFormat
        view.depthStencilPixelFormat = Constants.depthFormat
        view.sampleCount = Constants.sampleCount
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        drawableSize = view.drawableSize
    }

    func setPoseProvider(_ provider: any PoseProvider) {
        poseProvider = provider
        cameraFrameSource = provider as? any CameraFrameSource
    }

    /// The camera image source. Nil in the simulator, where no provider adopts
    /// `CameraFrameSource` — which is why passthrough silently stays off there.
    func setCameraFrameSource(_ source: (any CameraFrameSource)?) {
        cameraFrameSource = source
    }

    var isPassthroughAvailable: Bool {
        cameraFrameSource != nil
    }

    func setPassthroughEnabled(_ enabled: Bool) {
        guard enabled != isPassthroughEnabled else { return }
        isPassthroughEnabled = enabled
        if enabled {
            if compositor == nil {
                compositor = PassthroughCompositor(device: device, colorFormat: Constants.colorFormat)
            }
        } else {
            // ~24 MB at phone resolution; don't hold it for a black background.
            compositor?.releaseTargets()
        }
    }

    /// Occlusion only means anything over the camera: hiding splats behind a
    /// surface you can't see just deletes them.
    func setOcclusionEnabled(_ enabled: Bool) {
        guard enabled != isOcclusionEnabled else { return }
        isOcclusionEnabled = enabled
        if enabled {
            if occluderRenderer == nil {
                occluderRenderer = OccluderRenderer(device: device, depthFormat: Constants.depthFormat)
            }
        } else {
            occluderRenderer = nil
        }
    }

    /// Drops the discretionary GPU memory. Called on a memory warning, where a
    /// multi-hundred-megabyte splat is usually the real problem but this is the
    /// part we can give back immediately.
    func releaseDiscretionaryResources() {
        compositor?.releaseTargets()
    }

    func setIndicatorsEnabled(_ enabled: Bool) {
        if enabled {
            if gizmoRenderer == nil {
                gizmoRenderer = GizmoRenderer(device: device, colorFormat: Constants.colorFormat)
            }
        } else {
            gizmoRenderer = nil
        }
    }

    // MARK: - Loading

    /// Replaces the current scene. Parsing already happened off-actor in
    /// `SplatFileIO`; this partitions and uploads.
    ///
    /// - Returns: how many splats were actually loaded, which is below
    ///   `points.count` whenever the quality budget strided some out.
    @discardableResult
    func load(points: [SplatPoint], bounds: SplatBounds?, quality: SplatQuality) async throws -> Int {
        let renderer = try existingOrNewRenderer()
        await renderer.removeAllChunks()
        culler.removeAll()

        // Partitioning walks every point and encodes each one into a Metal
        // buffer — far too much for the main actor on a multi-million-splat
        // capture. `SplatChunk` is Sendable, so the whole thing can happen off
        // it and only the handles come back.
        let device = self.device
        let built = try await Task.detached(priority: .userInitiated) {
            try SplatChunking.build(points: points,
                                    bounds: bounds,
                                    budget: quality.budget,
                                    device: device)
        }.value

        // One `withChunkAccess` for all of them. Each `addChunk` otherwise takes
        // exclusive access on its own, and taking it drains the render queue and
        // blocks new frames — 128 of those back to back is a visible stall, and
        // a reload can happen at runtime when the quality picker changes.
        let (entries, loaded) = await renderer.withChunkAccess {
            () -> ([SplatChunkCuller.Entry], Int) in
            var entries: [SplatChunkCuller.Entry] = []
            entries.reserveCapacity(built.count)
            var loaded = 0
            for item in built {
                let id = await renderer.addChunk(item.chunk)
                entries.append(SplatChunkCuller.Entry(id: id,
                                                      minimum: item.minimum,
                                                      maximum: item.maximum,
                                                      splatCount: item.chunk.splatCount))
                loaded += item.chunk.splatCount
            }
            return (entries, loaded)
        }
        culler.reset(entries: entries, sceneBounds: bounds)
        splatRenderer = renderer
        Self.log.info("Loaded \(loaded) splats in \(built.count) chunk(s)")
        return loaded
    }

    func unload() async {
        await splatRenderer?.removeAllChunks()
        culler.removeAll()
    }

    /// The library renderer is expensive to build and its pixel formats are
    /// fixed at init, so it's created once and reused across loads.
    private func existingOrNewRenderer() throws -> MetalSplatter.SplatRenderer {
        if let splatRenderer { return splatRenderer }
        return try MetalSplatter.SplatRenderer(device: device,
                                               colorFormat: Constants.colorFormat,
                                               depthFormat: Constants.depthFormat,
                                               sampleCount: Constants.sampleCount,
                                               maxViewCount: 1,
                                               maxSimultaneousRenders: Constants.maxSimultaneousRenders,
                                               // Defaults true; it exists for Vision Pro frame
                                               // reprojection and gates a slower multi-stage
                                               // pipeline. Monoscopic iPhone has no reprojection,
                                               // so it's pure cost.
                                               highQualityDepth: false)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
    }

    func draw(in view: MTKView) {
        advanceClock()

        // Note: with nothing loaded this returns early, so passthrough shows
        // nothing rather than a bare camera feed. The Viewer always loads the
        // sample scene on appear, so in practice a splat is always present.
        guard let splatRenderer, splatRenderer.isReadyToRender else { return }
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        guard let drawable = view.currentDrawable else { return }

        let projectionMatrix = currentProjection()
        let viewMatrix = currentViewMatrix()
        culler.update(viewMatrix: viewMatrix,
                      projectionMatrix: projectionMatrix,
                      renderer: splatRenderer)
        publishCullingSummary()

        let surfaces = surfaceStateSource?()
        let occludingPlanes = isOcclusionEnabled ? (surfaces?.planes ?? []) : []
        let cameraFrame = currentPassthroughFrame(includesOccluder: !occludingPlanes.isEmpty)

        inFlightSemaphore.wait()

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }
        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }

        // Passthrough renders splats offscreen so they can be composited over
        // the camera; the black path renders straight into the drawable, which
        // is byte-for-byte the pre-passthrough behavior.
        let colorTexture: MTLTexture
        let depthTexture: MTLTexture?
        let colorStoreAction: MTLStoreAction
        if cameraFrame != nil,
           let offscreenColor = compositor?.splatColorTexture {
            colorTexture = offscreenColor
            depthTexture = compositor?.splatDepthTexture
            colorStoreAction = .store
        } else {
            colorTexture = view.multisampleColorTexture ?? drawable.texture
            depthTexture = view.depthStencilTexture
            colorStoreAction = view.multisampleColorTexture == nil ? .store : .multisampleResolve
        }

        var didRender: Bool
        do {
            didRender = try splatRenderer.render(
                viewports: [ViewportDescriptorBuilder.make(size: drawableSize,
                                                           projectionMatrix: projectionMatrix,
                                                           viewMatrix: viewMatrix)],
                colorTexture: colorTexture,
                colorStoreAction: colorStoreAction,
                depthTexture: depthTexture,
                rasterizationRateMap: nil,
                renderTargetArrayLength: 0,
                to: commandBuffer)
        } catch {
            Self.log.error("Render failed: \(error.localizedDescription)")
            didRender = false
        }

        if didRender, let cameraFrame, let compositor {
            let worldViewProjection = projectionMatrix * poseProvider.pose.viewMatrix
            let occlusion = encodeOccluders(occludingPlanes,
                                            viewProjection: worldViewProjection,
                                            compositor: compositor,
                                            commandBuffer: commandBuffer)
            didRender = compositor.composite(cameraFrame: cameraFrame,
                                             occlusion: occlusion,
                                             into: drawable.texture,
                                             commandBuffer: commandBuffer)
        }

        // Indicators go last, straight into the drawable, over whichever path
        // produced the image.
        if didRender {
            drawIndicators(surfaces: surfaces,
                           projectionMatrix: projectionMatrix,
                           into: drawable.texture,
                           commandBuffer: commandBuffer)
        }

        // Presenting a frame the renderer bailed on would show a partial image.
        if didRender {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }

    /// Rasterizes the surfaces into the occluder depth buffer. Returns the
    /// settings the composite needs, or nil when there's nothing to occlude
    /// with — in which case the composite skips the comparison entirely.
    private func encodeOccluders(_ planes: [DetectedPlane],
                                 viewProjection: simd_float4x4,
                                 compositor: PassthroughCompositor,
                                 commandBuffer: MTLCommandBuffer) -> OcclusionSettings? {
        guard !planes.isEmpty,
              let occluderRenderer,
              let depthTexture = compositor.occluderDepthTexture,
              occluderRenderer.draw(planes: planes,
                                    viewProjection: viewProjection,
                                    into: depthTexture,
                                    commandBuffer: commandBuffer)
        else { return nil }
        return OcclusionSettings(nearZ: Constants.nearZ, farZ: Constants.farZ)
    }

    private func drawIndicators(surfaces: (planes: [DetectedPlane], isPlacing: Bool)?,
                                projectionMatrix: simd_float4x4,
                                into target: MTLTexture,
                                commandBuffer: MTLCommandBuffer) {
        guard let gizmoRenderer, let surfaces else { return }

        // The gizmo is authored in world space, so it gets view × projection
        // without the model matrix. The splat's pivot maps to its placed
        // position through the full anchor × model chain.
        let anchor = anchorTransformSource?() ?? matrix_identity_float4x4
        let center = (anchor * sceneState.modelMatrix
                      * SIMD4<Float>(sceneState.pivot, 1)).xyz

        let axisLength = sceneState.indicatorAxisLength
        let ruler = rulerUnits.map { RulerScale.fitting(axisLength: axisLength, units: $0) }

        gizmoRenderer.draw(splatCenter: center,
                           axisLength: axisLength,
                           ruler: ruler,
                           planes: surfaces.planes,
                           isPlacing: surfaces.isPlacing,
                           viewProjection: projectionMatrix * poseProvider.pose.viewMatrix,
                           into: target,
                           commandBuffer: commandBuffer)
    }

    // MARK: - Frame setup

    /// Nil whenever passthrough should not run this frame — disabled, no
    /// source, no frame yet, or the offscreen targets couldn't be allocated.
    /// Every one of those falls back to the black path.
    private func currentPassthroughFrame(includesOccluder: Bool) -> CameraFrame? {
        guard isPassthroughEnabled,
              let cameraFrameSource,
              cameraFrameSource.isCameraFrameAvailable,
              let compositor,
              compositor.prepareTargets(size: SIMD2(Int(drawableSize.width), Int(drawableSize.height)),
                                        colorFormat: Constants.colorFormat,
                                        depthFormat: Constants.depthFormat,
                                        includesOccluder: includesOccluder)
        else { return nil }
        return cameraFrameSource.currentCameraFrame(viewportSize: drawableSize)
    }

    /// Feeds the pose provider real elapsed time, so joystick movement is
    /// frame-rate independent.
    private func advanceClock() {
        let now = CACurrentMediaTime()
        defer { lastFrameTimestamp = now }
        guard let lastFrameTimestamp else { return }
        poseProvider.update(deltaTime: now - lastFrameTimestamp)
    }

    private func currentProjection() -> simd_float4x4 {
        let aspectRatio = Float(drawableSize.width / drawableSize.height)
        return poseProvider.projectionMatrix(viewportSize: drawableSize,
                                             nearZ: Constants.nearZ,
                                             farZ: Constants.farZ)
            ?? perspectiveProjection(fovyRadians: poseProvider.verticalFieldOfView,
                                     aspectRatio: aspectRatio,
                                     nearZ: Constants.nearZ,
                                     farZ: Constants.farZ)
    }

    /// The splat's placement is folded into the view matrix; MetalSplatter
    /// takes only view and projection, not a separate model transform. The
    /// anchor sits outermost so ARKit's per-frame corrections apply to the
    /// whole splat rather than being fought by the local transform.
    ///
    /// This is also what the chunk culler tests against, which is why chunk
    /// bounds can stay in the splat's own coordinates.
    private func currentViewMatrix() -> simd_float4x4 {
        let anchor = anchorTransformSource?() ?? matrix_identity_float4x4
        return poseProvider.pose.viewMatrix * anchor * sceneState.modelMatrix
    }
}

/// Small shim so the viewport descriptor's long argument list doesn't sit in
/// the middle of `draw(in:)`.
private enum ViewportDescriptorBuilder {
    static func make(size: CGSize,
                     projectionMatrix: simd_float4x4,
                     viewMatrix: simd_float4x4) -> MetalSplatter.SplatRenderer.ViewportDescriptor {
        .init(viewport: MTLViewport(originX: 0,
                                    originY: 0,
                                    width: size.width,
                                    height: size.height,
                                    znear: 0,
                                    zfar: 1),
              projectionMatrix: projectionMatrix,
              viewMatrix: viewMatrix,
              screenSize: SIMD2(x: Int(size.width), y: Int(size.height)))
    }
}
