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

    /// Whether tracking is `.normal` right now, so `pose` is live rather than
    /// the identity placeholder or the last good pose held through limited
    /// tracking. Assigned only on change; the menu observes it.
    private(set) var hasTrackedPose = false

    /// Overwritten from ARKit's real intrinsics on the first frame; this is
    /// only the fallback used before tracking starts.
    private(set) var verticalFieldOfView: Float = 60 * .pi / 180

    private var latestCamera: ARCamera?
    private var isRunning = false
    private var hasRunSession = false

    /// Backing storage for `SurfaceProvider` (extensions can't add stored
    /// properties).
    fileprivate var detectsSurfaces = false
    fileprivate var planes: [DetectedPlane] = []
    /// Every anchor this provider added, kept at creation. An anchor only
    /// shows up in `session.currentFrame?.anchors` from the next frame on, so
    /// looking it up there to remove it misses one added this frame — two
    /// quick Recenters, or a Recenter right after Confirm, would orphan it.
    fileprivate var placedAnchors: [UUID: ARAnchor] = [:]
    fileprivate var wantsPlacementCandidate = false

    /// Refreshed once per frame in `update(deltaTime:)` while placement is
    /// active. Ignored by Observation because it changes every frame; the UI
    /// observes `placementReadiness`, which changes only when this crosses
    /// between nil / estimated / on-surface.
    @ObservationIgnored fileprivate var cachedCandidate: PlacementCandidate?
    fileprivate(set) var placementReadiness: PlacementReadiness = .unavailable

    func start() {
        guard Self.isSupported else {
            statusMessage = "AR tracking isn't available on this device."
            return
        }
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = detectsSurfaces ? [.horizontal] : []
        // Reset only on the first run. A restart after `stop()` (the app
        // coming back from the background) must keep the map and the placed
        // splat's anchor, or the splat would jump to wherever the phone is.
        let options: ARSession.RunOptions = hasRunSession ? [] : [.resetTracking, .removeExistingAnchors]
        session.run(configuration, options: options)
        hasRunSession = true
        isRunning = true
        statusMessage = "Move the phone slowly to start tracking."
    }

    func stop() {
        guard isRunning else { return }
        session.pause()
        isRunning = false
        // `update` stops polling while paused, so the cache would go stale.
        setPlacementCandidate(nil)
        setHasTrackedPose(false)
    }

    /// Polls the session rather than using ARSessionDelegate: the render loop
    /// already runs at display rate, and polling keeps everything on one actor.
    func update(deltaTime: TimeInterval) {
        guard isRunning, let frame = session.currentFrame else { return }

        let camera = frame.camera
        latestCamera = camera
        // Guarded because this runs every frame and Observation notifies on
        // every set; the placement overlay observes it.
        let status = message(for: camera.trackingState)
        if status != statusMessage { statusMessage = status }
        refreshPlanes(from: frame)
        refreshPlacementCandidate(from: frame)

        // A pose from a non-tracking camera is garbage; hold the last good one.
        guard case .normal = camera.trackingState else {
            setHasTrackedPose(false)
            return
        }

        let viewMatrix = camera.viewMatrix(for: interfaceOrientation)
        pose = CameraPose(transform: simd_inverse(viewMatrix))
        verticalFieldOfView = verticalFOV(from: camera)
        setHasTrackedPose(true)
    }

    /// Observation notifies on every set, and this is called every frame.
    private func setHasTrackedPose(_ value: Bool) {
        if value != hasTrackedPose { hasTrackedPose = value }
    }

    /// Deliberately does nothing. The camera here is the physical phone, so
    /// there is no virtual camera to reset, and `pose` must stay in raw ARKit
    /// world space: raycast hits, anchors, and planes are all reported there,
    /// and the renderer composes `pose.viewMatrix * anchor * model`. An offset
    /// folded into `pose` alone (what this used to do) put the splat away from
    /// the crosshair after a recenter. `ViewerModel.recenter()` moves the
    /// splat instead.
    func recenter() {}

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

// MARK: - SurfaceProvider

extension ARKitPoseProvider: SurfaceProvider {

    var isSurfaceDetectionEnabled: Bool {
        get { detectsSurfaces }
        set {
            guard newValue != detectsSurfaces else { return }
            detectsSurfaces = newValue
            // Actually stop the work rather than just hiding results — plane
            // detection costs CPU every frame, and this runs alongside splat
            // sorting on a thermally constrained device.
            reconfigureSession()
            if !newValue { planes.removeAll() }
        }
    }

    private(set) var detectedPlanes: [DetectedPlane] {
        get { planes }
        set { planes = newValue }
    }

    var isPlacementActive: Bool {
        get { wantsPlacementCandidate }
        set {
            guard newValue != wantsPlacementCandidate else { return }
            wantsPlacementCandidate = newValue
            if !newValue { setPlacementCandidate(nil) }
        }
    }

    /// The candidate from the most recent frame. Cached rather than raycast on
    /// read: the renderer reads it every frame, and SwiftUI can't observe a
    /// live raycast anyway.
    var placementCandidate: PlacementCandidate? { cachedCandidate }

    /// Called from `update(deltaTime:)`, which already polls the frame.
    fileprivate func refreshPlacementCandidate(from frame: ARFrame) {
        guard wantsPlacementCandidate else { return }
        setPlacementCandidate(computePlacementCandidate(from: frame))
    }

    /// The only writer of the candidate, so readiness can't fall out of sync
    /// with it, and readiness is assigned only on change.
    fileprivate func setPlacementCandidate(_ candidate: PlacementCandidate?) {
        cachedCandidate = candidate
        let readiness = PlacementReadiness(candidate: candidate)
        if readiness != placementReadiness { placementReadiness = readiness }
    }

    /// Raycast straight down the middle of the screen.
    ///
    /// `ARFrame.raycastQuery` takes a point in **normalized image space**, so
    /// screen center is (0.5, 0.5) and no view geometry is needed.
    private func computePlacementCandidate(from frame: ARFrame) -> PlacementCandidate? {
        guard isRunning else { return nil }
        guard case .normal = frame.camera.trackingState else { return nil }

        if detectsSurfaces {
            let query = frame.raycastQuery(from: CGPoint(x: 0.5, y: 0.5),
                                           allowing: .estimatedPlane,
                                           alignment: .horizontal)
            if let hit = session.raycast(query).first {
                return PlacementCandidate(transform: hit.worldTransform, isOnSurface: true)
            }
        }

        // Nothing under the crosshair: float it a fixed distance ahead and let
        // the UI say so, rather than implying it's grounded.
        let cameraTransform = simd_inverse(frame.camera.viewMatrix(for: interfaceOrientation))
        let origin = cameraTransform.columns.3.xyz
        let forward = -cameraTransform.columns.2.xyz
        return PlacementCandidate(
            transform: matrix4x4_translation(origin + forward * PlacementFallback.distance),
            isOnSurface: false)
    }

    func makeAnchor(at transform: simd_float4x4) -> UUID? {
        guard isRunning else { return nil }
        let anchor = ARAnchor(name: "splat", transform: transform)
        session.add(anchor: anchor)
        placedAnchors[anchor.identifier] = anchor
        return anchor.identifier
    }

    /// Re-read every frame. ARKit refines anchor transforms as its map
    /// improves; a cached copy is exactly what makes a splat appear to drift.
    ///
    /// Until the anchor reaches a frame (the frame after `makeAnchor`) the
    /// transform it was created with is the best there is. Nil only for an
    /// anchor this provider doesn't own.
    func anchorTransform(for id: UUID) -> simd_float4x4? {
        guard let placed = placedAnchors[id] else { return nil }
        return session.currentFrame?.anchors.first { $0.identifier == id }?.transform
            ?? placed.transform
    }

    /// Removes via the anchor kept at creation, not the current frame's
    /// copy, so it works even before the anchor has reached a frame. ARKit
    /// matches anchors by identifier, so the original object is enough.
    func removeAnchor(_ id: UUID) {
        guard let anchor = placedAnchors.removeValue(forKey: id) else { return }
        session.remove(anchor: anchor)
    }

    /// Mirrors ARKit's plane anchors into the ARKit-free `DetectedPlane` type.
    /// Called from `update(deltaTime:)`, which already polls the frame.
    func refreshPlanes(from frame: ARFrame) {
        guard detectsSurfaces else { return }
        planes = frame.anchors.compactMap { anchor in
            guard let plane = anchor as? ARPlaneAnchor,
                  plane.alignment == .horizontal else { return nil }
            // planeExtent is in the anchor's local space, centered on `center`.
            var transform = plane.transform
            transform.columns.3 += simd_float4(plane.center.x, plane.center.y, plane.center.z, 0)
            // Boundary vertices are relative to the anchor's own origin, so
            // they need the same `center` shift removed to line up with the
            // transform above. Without this the outline sits offset from the
            // plane it describes, and the occluder mesh with it.
            let boundary = plane.geometry.boundaryVertices.map {
                SIMD2<Float>($0.x - plane.center.x, $0.z - plane.center.z)
            }
            return DetectedPlane(id: plane.identifier,
                                 transform: transform,
                                 extent: SIMD2(plane.planeExtent.width, plane.planeExtent.height),
                                 boundary: boundary)
        }
    }

    /// Re-runs the session with the current plane-detection setting.
    /// Deliberately *without* `.resetTracking` — restarting would throw away
    /// the map and every placed anchor.
    private func reconfigureSession() {
        guard isRunning else { return }
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = detectsSurfaces ? [.horizontal] : []
        session.run(configuration)
    }
}
