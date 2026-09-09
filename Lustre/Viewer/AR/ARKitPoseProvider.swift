//
//  ARKitPoseProvider.swift
//  Lustre
//
//  6DoF pose from ARKit world tracking — physically walking through the splat.
//  Device only: ARKit reports unsupported in the simulator, where
//  SimulatedPoseProvider takes over instead.
//

import CoreVideo
import Foundation
import Metal
import Observation
import simd
import UIKit
import ARKit

@MainActor
@Observable
final class ARKitPoseProvider: NSObject, PoseProvider {

    /// Whether this device can actually produce poses. The Viewer checks this
    /// to decide between AR and simulated input.
    static var isSupported: Bool {
        ARWorldTrackingConfiguration.isSupported
    }

    private let session = ARSession()

    /// Zero-copy wrapping of `ARFrame.capturedImage`'s planes. Creating
    /// textures per frame with `makeTexture` instead would allocate at 60 Hz.
    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?

    /// `CVMetalTexture` must outlive the command buffer that samples it. Three
    /// generations matches the renderer's `maxSimultaneousRenders`.
    private var retainedTextureGenerations: [[CVMetalTexture]] = []

    init(device: MTLDevice) {
        self.device = device
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    private(set) var pose: CameraPose = .identity
    private(set) var statusMessage: String?

    /// Overwritten from ARKit's real intrinsics on the first frame; this is
    /// only the fallback used before tracking starts.
    private(set) var verticalFieldOfView: Float = 60 * .pi / 180

    /// Applied so that "recenter" makes the current position the origin
    /// without restarting the session and losing tracking.
    private var originOffset: simd_float4x4 = matrix_identity_float4x4

    private var latestCamera: ARCamera?
    private var isRunning = false

    func start() {
        guard Self.isSupported else {
            statusMessage = "AR tracking isn't available on this device."
            return
        }
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = []
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
        statusMessage = "Move the phone slowly to start tracking."
    }

    func stop() {
        guard isRunning else { return }
        session.pause()
        isRunning = false
    }

    /// Polls the session rather than using ARSessionDelegate: the render loop
    /// already runs at display rate, and polling keeps everything on one actor.
    func update(deltaTime: TimeInterval) {
        guard isRunning, let frame = session.currentFrame else { return }

        let camera = frame.camera
        latestCamera = camera
        statusMessage = message(for: camera.trackingState)

        // A pose from a non-tracking camera is garbage; hold the last good one.
        guard case .normal = camera.trackingState else { return }

        let viewMatrix = camera.viewMatrix(for: interfaceOrientation)
        pose = CameraPose(transform: originOffset * simd_inverse(viewMatrix))
        verticalFieldOfView = verticalFOV(from: camera)
    }

    func recenter() {
        guard let camera = latestCamera else { return }
        // Cancel out wherever the camera currently is, so it becomes the origin.
        let current = simd_inverse(camera.viewMatrix(for: interfaceOrientation))
        originOffset = simd_inverse(current)
    }

    /// ARKit's own projection, built from the physical camera's intrinsics.
    /// Using it (rather than a guessed FOV) is what makes splats sit still
    /// relative to the room.
    func projectionMatrix(viewportSize: CGSize, nearZ: Float, farZ: Float) -> simd_float4x4? {
        guard let camera = latestCamera, viewportSize.width > 0, viewportSize.height > 0 else {
            return nil
        }
        return camera.projectionMatrix(for: interfaceOrientation,
                                       viewportSize: viewportSize,
                                       zNear: CGFloat(nearZ),
                                       zFar: CGFloat(farZ))
    }

    // MARK: - Helpers

    private var interfaceOrientation: UIInterfaceOrientation {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        return scene?.interfaceOrientation ?? .portrait
    }

    /// Derives vertical FOV from the focal length in the intrinsics matrix.
    private func verticalFOV(from camera: ARCamera) -> Float {
        let focalLengthY = camera.intrinsics[1][1]
        let imageHeight = Float(camera.imageResolution.height)
        guard focalLengthY > 0 else { return verticalFieldOfView }
        return 2 * atan(imageHeight / (2 * focalLengthY))
    }

    private func message(for state: ARCamera.TrackingState) -> String? {
        switch state {
        case .normal:
            return nil
        case .notAvailable:
            return "Starting AR tracking…"
        case .limited(.initializing):
            return "Move the phone slowly to start tracking."
        case .limited(.excessiveMotion):
            return "Slow down — moving too fast to track."
        case .limited(.insufficientFeatures):
            return "Not enough detail here to track. Try a busier surface."
        case .limited(.relocalizing):
            return "Recovering tracking…"
        case .limited:
            return "Tracking is limited."
        }
    }
}

// MARK: - CameraFrameSource

extension ARKitPoseProvider: CameraFrameSource {

    var isCameraFrameAvailable: Bool {
        isRunning && textureCache != nil && session.currentFrame != nil
    }

    /// Wraps the current frame's YCbCr planes as Metal textures.
    ///
    /// Reads `session.currentFrame` fresh rather than holding an `ARFrame`
    /// across frames — the capture pool is small and retaining frames stalls
    /// ARKit. Only the derived `CVMetalTexture` handles are kept, and only long
    /// enough for the GPU to finish with them.
    func currentCameraFrame(viewportSize: CGSize) -> CameraFrame? {
        guard isRunning,
              let textureCache,
              let frame = session.currentFrame,
              viewportSize.width > 0, viewportSize.height > 0
        else { return nil }

        let pixelBuffer = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return nil }

        guard let luma = makeTexture(from: pixelBuffer, plane: 0, format: .r8Unorm, cache: textureCache),
              let chroma = makeTexture(from: pixelBuffer, plane: 1, format: .rg8Unorm, cache: textureCache)
        else { return nil }

        retain([luma.reference, chroma.reference])

        return CameraFrame(luma: luma.texture,
                           chroma: chroma.texture,
                           displayTransform: viewToCaptureTransform(frame: frame, viewportSize: viewportSize),
                           isFullRange: CVPixelBufferGetPixelFormatType(pixelBuffer)
                               == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer,
                             plane: Int,
                             format: MTLPixelFormat,
                             cache: CVMetalTextureCache) -> (texture: MTLTexture, reference: CVMetalTexture)? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)

        var reference: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            format, width, height, plane, &reference)

        guard status == kCVReturnSuccess,
              let reference,
              let texture = CVMetalTextureGetTexture(reference)
        else { return nil }
        return (texture, reference)
    }

    private func retain(_ textures: [CVMetalTexture]) {
        retainedTextureGenerations.append(textures)
        if retainedTextureGenerations.count > 3 {
            retainedTextureGenerations.removeFirst()
        }
    }

    /// The shader samples the camera using *view* UVs, so it needs view→capture.
    /// ARKit's `displayTransform` goes capture→view, hence the inverse.
    private func viewToCaptureTransform(frame: ARFrame, viewportSize: CGSize) -> simd_float3x3 {
        let transform = frame
            .displayTransform(for: interfaceOrientation, viewportSize: viewportSize)
            .inverted()
        // CGAffineTransform maps (x,y) to (a·x + c·y + tx, b·x + d·y + ty);
        // as a column-major 3×3 that's these three columns.
        return simd_float3x3(columns: (SIMD3<Float>(Float(transform.a), Float(transform.b), 0),
                                       SIMD3<Float>(Float(transform.c), Float(transform.d), 0),
                                       SIMD3<Float>(Float(transform.tx), Float(transform.ty), 1)))
    }
}
