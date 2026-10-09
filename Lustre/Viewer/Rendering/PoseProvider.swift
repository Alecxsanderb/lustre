//
//  PoseProvider.swift
//  Lustre
//
//  The testing seam for the Viewer. ARKit doesn't run in the simulator, so
//  everything downstream of this protocol — the renderer, the scene state,
//  the overlays — stays testable without a device.
//
//  Two implementations: ARKitPoseProvider on device, SimulatedPoseProvider
//  (dual joysticks) everywhere else.
//

import Foundation
import simd

/// Where the virtual camera is, in world space.
struct CameraPose: Equatable {
    /// Camera-to-world transform. The camera looks down -Z with +Y up, which
    /// is both Metal's and ARKit's convention.
    var transform: simd_float4x4

    static let identity = CameraPose(transform: matrix_identity_float4x4)

    var position: SIMD3<Float> { transform.columns.3.xyz }

    /// World-to-camera. This is what the renderer actually needs.
    var viewMatrix: simd_float4x4 { simd_inverse(transform) }
}

/// Supplies a camera pose once per frame.
///
/// Implementations are `@MainActor` because they're read from the render loop
/// and written from UI gestures; keeping them on one actor avoids a lock.
@MainActor
protocol PoseProvider: AnyObject {
    /// The pose to render from. Read once per frame, after `update`.
    var pose: CameraPose { get }

    /// Vertical field of view in radians, used when `projectionMatrix` returns nil.
    var verticalFieldOfView: Float { get }

    /// A short message for the overlay when tracking isn't nominal, else nil.
    var statusMessage: String? { get }

    /// Begin producing poses.
    func start()

    /// Stop producing poses and release any hardware.
    func stop()

    /// Advance time-based integration. Called once per rendered frame.
    func update(deltaTime: TimeInterval)

    /// Reset the provider's own virtual camera, if it has one.
    ///
    /// Called by `ViewerModel.recenter()` on every provider. Where the camera
    /// is the physical phone (ARKit) there's nothing to reset and this is a
    /// no-op; the poses a provider reports must stay in the same world frame
    /// as its anchors and surfaces, so it may not shift its origin either.
    /// Moving the splat to the camera is the model's job, done for any
    /// provider that is also a `SurfaceProvider`.
    func recenter()

    /// A provider-supplied projection, e.g. from real camera intrinsics.
    ///
    /// Returning nil falls back to `perspectiveProjection` built from
    /// `verticalFieldOfView`. ARKit overrides this so rendered splats line up
    /// with the passthrough camera image.
    func projectionMatrix(viewportSize: CGSize, nearZ: Float, farZ: Float) -> simd_float4x4?
}

extension PoseProvider {
    var statusMessage: String? { nil }

    func projectionMatrix(viewportSize: CGSize, nearZ: Float, farZ: Float) -> simd_float4x4? {
        nil
    }
}
