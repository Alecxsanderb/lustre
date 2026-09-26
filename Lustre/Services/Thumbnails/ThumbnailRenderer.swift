//
//  ThumbnailRenderer.swift
//  Lustre
//
//  Renders a decimated splat into a 480×360 JPEG, framed the way the Viewer
//  first shows it: recentred, up-flipped, seen from a raised 3/4 angle.
//
//  Split in two so the sequencing is testable without a GPU:
//  - `ThumbnailRenderer` owns the policy: framing, how many times to prime
//    the sorter, how many skipped frames to retry, JPEG encoding.
//  - `ThumbnailRenderBackend` is the GPU step. `MetalThumbnailBackend` is the
//    real one; tests substitute a stub.
//
//  Why the priming: MetalSplatter's sorter learns the camera only from
//  `render()`, and `render()` draws with whatever sort it already has. The
//  first frame after `addChunk` is therefore sorted for some other pose (or
//  not at all), which shows as a smeared, inside-out splat. So: render a
//  frame and throw it away to hand the sorter the pose, wait for a sort,
//  repeat once (the first wait can be satisfied by a sort that was already
//  running for the old pose), then render the frame that's kept.
//

import CoreGraphics
import Foundation
import ImageIO
import Metal
import MetalSplatter
import os
import simd
import SplatIO
import UniformTypeIdentifiers

/// View and projection for one thumbnail. The view already includes the
/// model transform: MetalSplatter has no model-matrix parameter.
nonisolated struct ThumbnailCamera: Equatable, Sendable {
    var view: simd_float4x4
    var projection: simd_float4x4
}

/// The GPU step, one scene at a time. Calls are strictly sequential.
nonisolated protocol ThumbnailRenderBackend: AnyObject, Sendable {
    func load(_ points: [SplatPoint]) async throws
    func unload() async
    /// Hands the sorter `camera` via a discarded frame, then waits (bounded)
    /// for a sort that follows it. False if none arrived in time, which isn't
    /// an error: the kept frame's own retries decide.
    func primeSort(camera: ThumbnailCamera) async throws -> Bool
    /// Renders and reads back one frame. Nil when the renderer skipped it.
    func renderFrame(camera: ThumbnailCamera) async throws -> CGImage?
}

/// What the generator needs from a renderer, so it can be stubbed too.
nonisolated protocol ThumbnailRendering: AnyObject, Sendable {
    /// `@concurrent` so framing and JPEG encoding never run on the caller's
    /// actor (the generator's, or the main actor).
    @concurrent func renderJPEG(points: [SplatPoint]) async throws -> Data
}

nonisolated final class ThumbnailRenderer: ThumbnailRendering {

    /// Bump whenever framing or look changes: it's part of every cache key,
    /// so old thumbnails stop matching and get swept.
    static let version = 1

    static let width = 480
    static let height = 360
    static let jpegQuality: CGFloat = 0.8

    /// Discard-and-sort rounds before the kept frame. See the file comment
    /// for why one isn't enough.
    static let primingRounds = 2
    /// Kept-frame attempts before giving up. Each skip gets another priming
    /// round first, since a skip usually means no valid sort yet.
    static let maxFrameAttempts = 3

    enum RenderError: Error, Equatable {
        /// No point had a finite position, so there's nothing to frame.
        case noFinitePoints
        /// Every attempt was skipped by the renderer. Transient, not a damaged file.
        case renderSkipped
        case encodingFailed
    }

    private let backend: any ThumbnailRenderBackend

    init(backend: any ThumbnailRenderBackend) {
        self.backend = backend
    }

    /// The real GPU renderer. Throws if Metal or MetalSplatter can't start.
    convenience init() throws {
        try self.init(backend: MetalThumbnailBackend(width: Self.width, height: Self.height))
    }

    @concurrent func renderJPEG(points: [SplatPoint]) async throws -> Data {
        let image = try await renderImage(points: points)
        guard let data = Self.jpegData(from: image, quality: Self.jpegQuality) else {
            throw RenderError.encodingFailed
        }
        return data
    }

    func renderImage(points: [SplatPoint]) async throws -> CGImage {
        guard let camera = Self.camera(for: points) else { throw RenderError.noFinitePoints }
        try Task.checkCancellation()

        try await backend.load(points)
        do {
            let image = try await renderLoaded(camera: camera)
            await backend.unload()
            return image
        } catch {
            await backend.unload()
            throw error
        }
    }

    private func renderLoaded(camera: ThumbnailCamera) async throws -> CGImage {
        for _ in 0..<Self.primingRounds {
            try Task.checkCancellation()
            _ = try await backend.primeSort(camera: camera)
        }
        for attempt in 1...Self.maxFrameAttempts {
            try Task.checkCancellation()
            if let image = try await backend.renderFrame(camera: camera) { return image }
            if attempt < Self.maxFrameAttempts {
                _ = try await backend.primeSort(camera: camera)
            }
        }
        throw RenderError.renderSkipped
    }

    /// Frames the points exactly as the Viewer's library transform places
    /// them. Nil when no position is finite.
    static func camera(for points: [SplatPoint],
                       aspect: Float = Float(width) / Float(height)) -> ThumbnailCamera? {
        guard let bounds = SplatBounds.robust(of: points.lazy.map(\.position)) else { return nil }
        let model = ThumbnailFraming.libraryModelMatrix(for: bounds)
        let world = ThumbnailFraming.transformed(bounds, by: model)
        let framing = ThumbnailFraming.camera(for: world, aspect: aspect)
        return ThumbnailCamera(view: framing.view * model, projection: framing.projection)
    }

    static func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString,
                                                                 1, nil) else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

// MARK: - Metal backend

/// Offscreen MetalSplatter rendering into a fixed-size texture.
///
/// `render()` blocks its thread (it sleeps while waiting for render access
/// and for a sort), so every render runs on a private serial queue, never on
/// the main thread or the cooperative pool. The textures and readback buffer
/// are allocated once and reused for every thumbnail this backend draws.
///
/// `@unchecked Sendable`: the Metal objects are only touched from `queue` or
/// from the owner's strictly sequential calls (the generator draws one file
/// at a time), and MetalSplatter's renderer is itself `@unchecked Sendable`.
nonisolated final class MetalThumbnailBackend: ThumbnailRenderBackend, @unchecked Sendable {

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Lustre",
                                    category: "ThumbnailRenderer")

    /// Same format as the Viewer's drawable, so colors match.
    static let colorFormat = MTLPixelFormat.bgra8Unorm_srgb
    /// Opaque black: the Viewer's black background, and a JPEG has no alpha.
    static let clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    /// How long to wait for a sort after handing the sorter a pose. A 300k
    /// sort is tens of milliseconds on device; this only bounds a stall.
    static let sortWait: Duration = .seconds(3)
    /// `render()`'s own blocking limits. Generous: nothing else is waiting on
    /// this queue, and a skipped frame costs a whole retry.
    static let accessTimeout: TimeInterval = 1
    static let sortTimeout: TimeInterval = 1

    let width: Int
    let height: Int

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let splatRenderer: MetalSplatter.SplatRenderer
    private let colorTexture: MTLTexture
    private let readbackBuffer: MTLBuffer
    private let bytesPerRow: Int
    private let queue = DispatchQueue(label: "com.alecborer.lustre.thumbnail-render", qos: .utility)

    enum SetupError: Error {
        case noDevice
        case allocationFailed
    }

    init(width: Int, height: Int, device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw SetupError.noDevice }
        guard let commandQueue = device.makeCommandQueue() else { throw SetupError.allocationFailed }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.colorFormat,
                                                                         width: width, height: height,
                                                                         mipmapped: false)
        textureDescriptor.usage = [.renderTarget]
        // Private plus a blit into a shared buffer, rather than a shared
        // texture, so readback works the same on device and in the simulator.
        textureDescriptor.storageMode = .private
        let bytesPerRow = width * 4
        guard let colorTexture = device.makeTexture(descriptor: textureDescriptor),
              let readbackBuffer = device.makeBuffer(length: bytesPerRow * height,
                                                     options: .storageModeShared) else {
            throw SetupError.allocationFailed
        }
        colorTexture.label = "Thumbnail Color"
        readbackBuffer.label = "Thumbnail Readback"

        self.width = width
        self.height = height
        self.device = device
        self.commandQueue = commandQueue
        self.colorTexture = colorTexture
        self.readbackBuffer = readbackBuffer
        self.bytesPerRow = bytesPerRow
        self.splatRenderer = try MetalSplatter.SplatRenderer(device: device,
                                                             colorFormat: Self.colorFormat,
                                                             // No depth: nothing tests it, and a
                                                             // thumbnail composites over nothing.
                                                             depthFormat: .invalid,
                                                             sampleCount: 1,
                                                             maxViewCount: 1,
                                                             maxSimultaneousRenders: 1,
                                                             // Vision Pro reprojection only; see
                                                             // the Viewer's SplatRenderer.
                                                             highQualityDepth: false,
                                                             clearColor: Self.clearColor)
    }

    func load(_ points: [SplatPoint]) async throws {
        let device = self.device
        // Encoding 300k points is real CPU work; keep it off the cooperative pool too.
        let chunk = try await onQueue { try SplatChunk(device: device, from: points) }
        await splatRenderer.addChunk(chunk)
    }

    func unload() async {
        await splatRenderer.removeAllChunks()
    }

    func primeSort(camera: ThumbnailCamera) async throws -> Bool {
        let signal = OneShotSignal()
        // Registered before the render that sets the pose: if the sort
        // finished before registration, the handler would wait for a sort
        // that nothing ever requests.
        splatRenderer.afterNextSort { signal.fire() }
        _ = try await onQueue { try self.encodeAndWait(camera: camera, readBack: false) }
        return await signal.wait(timeout: Self.sortWait)
    }

    func renderFrame(camera: ThumbnailCamera) async throws -> CGImage? {
        guard try await onQueue({ try self.encodeAndWait(camera: camera, readBack: true) }) else {
            return nil
        }
        return makeImage()
    }

    // MARK: - Queue work

    /// Encodes one frame and blocks until the GPU finishes. The command
    /// buffer is committed even when the renderer skipped: `render()` can
    /// attach completion handlers (which release its sorted-index buffer)
    /// before deciding there's nothing to draw.
    private func encodeAndWait(camera: ThumbnailCamera, readBack: Bool) throws -> Bool {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }
        commandBuffer.label = "Thumbnail"
        let viewport = MetalSplatter.SplatRenderer.ViewportDescriptor(
            viewport: MTLViewport(originX: 0, originY: 0,
                                  width: Double(width), height: Double(height),
                                  znear: 0, zfar: 1),
            projectionMatrix: camera.projection,
            viewMatrix: camera.view,
            screenSize: SIMD2(width, height))

        let didRender: Bool
        do {
            didRender = try splatRenderer.render(viewports: [viewport],
                                                 colorTexture: colorTexture,
                                                 colorStoreAction: .store,
                                                 depthTexture: nil,
                                                 rasterizationRateMap: nil,
                                                 renderTargetArrayLength: 0,
                                                 accessTimeout: Self.accessTimeout,
                                                 sortTimeout: Self.sortTimeout,
                                                 to: commandBuffer)
        } catch {
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            throw error
        }

        if didRender && readBack, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: colorTexture, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: readbackBuffer, destinationOffset: 0,
                      destinationBytesPerRow: bytesPerRow,
                      destinationBytesPerImage: bytesPerRow * height)
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            Self.log.error("Thumbnail command buffer failed: \(error.localizedDescription)")
            return false
        }
        return didRender
    }

    /// Copies the readback buffer into an image. Copied, not wrapped, because
    /// the buffer is reused for the next thumbnail.
    private func makeImage() -> CGImage? {
        let data = Data(bytes: readbackBuffer.contents(), count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // BGRA in memory is 32-bit little-endian ARGB. The clear is opaque
        // and the blend keeps alpha at 1, so the alpha byte is ignored.
        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                      | CGImageAlphaInfo.noneSkipFirst.rawValue)
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: colorSpace, bitmapInfo: bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
