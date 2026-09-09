//
//  CameraFrameSource.swift
//  Lustre
//
//  How the renderer gets a camera image without importing ARKit.
//
//  Same idea as `PoseProvider`: the renderer talks to this protocol, and only
//  `ARKitPoseProvider` knows what an `ARFrame` is. Deliberately free of ARKit
//  types in the signature so `Rendering/` stays device-agnostic and the
//  passthrough compositor is testable against a synthetic source.
//

import CoreVideo
import Metal
import simd

/// One camera image, as the two planes the compositor actually samples.
struct CameraFrame {
    /// Full-resolution luma, `.r8Unorm`.
    let luma: MTLTexture

    /// Half-resolution interleaved Cb/Cr, `.rg8Unorm`.
    let chroma: MTLTexture

    /// Maps capture-space UVs to view-space UVs, covering both the
    /// aspect-ratio crop and the interface orientation.
    let displayTransform: simd_float3x3

    /// True for a full-range (`420f`) buffer, false for video-range (`420v`).
    /// Chooses the YCbCr matrix; getting it wrong washes the image out.
    let isFullRange: Bool
}

@MainActor
protocol CameraFrameSource: AnyObject {
    /// False until the first frame arrives, so the renderer can fall back to
    /// the black path instead of showing an empty drawable.
    var isCameraFrameAvailable: Bool { get }

    /// The current frame's textures, or nil if none is ready.
    ///
    /// The returned textures are valid for the current frame only — the
    /// underlying `CVPixelBuffer` comes from a small pool, and holding it
    /// stalls the capture session.
    func currentCameraFrame(viewportSize: CGSize) -> CameraFrame?
}
