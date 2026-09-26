//
//  SplatModelTransform.swift
//  Lustre
//
//  The model-to-world transform for a splat, as a pure function of its
//  placement. The Viewer composes it every frame; Library thumbnails need the
//  exact same framing, and can't import the Viewer, so it lives in Core.
//

import simd

nonisolated enum SplatModelTransform {

    /// Read right to left: recenter the asset on its own pivot, apply the
    /// canonical up-flip, scale, apply user rotation, then place it. The pivot
    /// bracket is what makes scale and rotation act *in place*.
    ///
    /// Scale and the up-calibration commute because the scale is uniform, so
    /// their relative order is arbitrary; a test pins the rest of the order.
    ///
    /// `scale` is used as given — callers clamp it to their own range.
    static func matrix(pivot: SIMD3<Float>,
                       appliesUpCalibration: Bool,
                       scale: Float,
                       rotation: simd_float4x4 = matrix_identity_float4x4,
                       translation: SIMD3<Float> = .zero) -> simd_float4x4 {
        var matrix = matrix4x4_translation(translation)
        matrix *= rotation
        matrix *= matrix4x4_scale(scale)
        if appliesUpCalibration {
            matrix *= upCalibration
        }
        matrix *= matrix4x4_translation(-pivot)
        return matrix
    }

    /// The 180° roll about Z that turns a Y-down 3DGS capture rightside-up.
    static let upCalibration = matrix4x4_rotation(radians: .pi, axis: SIMD3<Float>(0, 0, 1))
}
