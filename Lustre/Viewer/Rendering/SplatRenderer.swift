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

    private enum Constants {
        static let maxSimultaneousRenders = 3
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

    // MARK: - Passthrough

    private var isPassthroughEnabled = false
    private weak var cameraFrameSource: (any CameraFrameSource)?
    private var compositor: PassthroughCompositor?

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

    /// Drops the discretionary GPU memory. Called on a memory warning, where a
    /// multi-hundred-megabyte splat is usually the real problem but this is the
    /// part we can give back immediately.
    func releaseDiscretionaryResources() {
        compositor?.releaseTargets()
    }

    // MARK: - Loading

    /// Replaces the current scene. Parsing already happened off-actor in
    /// `SplatFileIO`; this is the GPU-side upload.
    func load(points: [SplatPoint]) async throws {
        let renderer = try existingOrNewRenderer()
        await renderer.removeAllChunks()
        let chunk = try SplatChunk(device: device, from: points)
        await renderer.addChunk(chunk)
        splatRenderer = renderer
    }

    func unload() async {
        await splatRenderer?.removeAllChunks()
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

        let cameraFrame = currentPassthroughFrame()

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
                viewports: [currentViewport()],
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
            didRender = compositor.composite(cameraFrame: cameraFrame,
                                             into: drawable.texture,
                                             commandBuffer: commandBuffer)
        }

        // Presenting a frame the renderer bailed on would show a partial image.
        if didRender {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }

    // MARK: - Frame setup

    /// Nil whenever passthrough should not run this frame — disabled, no
    /// source, no frame yet, or the offscreen targets couldn't be allocated.
    /// Every one of those falls back to the black path.
    private func currentPassthroughFrame() -> CameraFrame? {
        guard isPassthroughEnabled,
              let cameraFrameSource,
              cameraFrameSource.isCameraFrameAvailable,
              let compositor,
              compositor.prepareTargets(size: SIMD2(Int(drawableSize.width), Int(drawableSize.height)),
                                        colorFormat: Constants.colorFormat,
                                        depthFormat: Constants.depthFormat)
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

    private func currentViewport() -> MetalSplatter.SplatRenderer.ViewportDescriptor {
        let aspectRatio = Float(drawableSize.width / drawableSize.height)
        let projectionMatrix = poseProvider.projectionMatrix(viewportSize: drawableSize,
                                                             nearZ: Constants.nearZ,
                                                             farZ: Constants.farZ)
            ?? perspectiveProjection(fovyRadians: poseProvider.verticalFieldOfView,
                                     aspectRatio: aspectRatio,
                                     nearZ: Constants.nearZ,
                                     farZ: Constants.farZ)

        // The splat's placement is folded into the view matrix; MetalSplatter
        // takes only view and projection, not a separate model transform.
        let viewMatrix = poseProvider.pose.viewMatrix * sceneState.modelMatrix

        return .init(viewport: MTLViewport(originX: 0,
                                           originY: 0,
                                           width: drawableSize.width,
                                           height: drawableSize.height,
                                           znear: 0,
                                           zfar: 1),
                     projectionMatrix: projectionMatrix,
                     viewMatrix: viewMatrix,
                     screenSize: SIMD2(x: Int(drawableSize.width), y: Int(drawableSize.height)))
    }
}
