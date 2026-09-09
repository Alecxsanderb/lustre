//
//  SplatSceneState.swift
//  Lustre
//
//  What's loaded and how it's placed in the world. Owned by the Viewer screen,
//  read by the renderer each frame, mutated by the control menu and gestures.
//
//  Only render-loop state belongs here. The test for whether something belongs:
//  would you serialize it with the splat's placement? UI state (menu expanded,
//  gestures enabled) lives in `ViewerUIState` instead.
//

import Foundation
import Observation
import simd

@MainActor
@Observable
final class SplatSceneState {

    enum LoadState: Equatable {
        case empty
        case loading(String)
        case loaded(name: String, splatCount: Int)
        case failed(String)

        var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }
    }

    var loadState: LoadState = .empty

    // MARK: - Placement (user-controlled)

    /// Uniform scale. `1.0` means "as authored" — see `SplatScale.authored`.
    var scale: Float = SplatScale.authored

    /// Where the splat's center sits in world space, in meters.
    var translation: SIMD3<Float> = .zero

    /// Rotation about world up. The primary orientation control.
    var yaw: Float = 0

    /// Secondary axes, exposed behind a disclosure. Most captures only need
    /// yaw; pitch and roll are for fixing a capture that came out tilted.
    var pitch: Float = 0
    var roll: Float = 0

    // MARK: - Asset metadata (set at load, not user placement)

    /// The splat's own center, subtracted before scaling and rotating.
    ///
    /// SfM output has an arbitrary origin that can sit far outside the point
    /// cloud. Without this, scaling makes the splat fly across the room instead
    /// of growing in place, and rotation swings it in an arc. Not cleared by
    /// `resetPlacement()` — it describes the asset, not the user's placement.
    var pivot: SIMD3<Float> = .zero

    /// Whether to apply the 180° roll that turns most 3DGS PLY captures
    /// rightside-up.
    ///
    /// Real captures are conventionally authored Y-down, so files need this.
    /// `SampleSplatScene` is authored Y-up in our own coordinate system, so it
    /// must not get the correction — hence a flag rather than a constant.
    var appliesUpCalibration: Bool = true

    /// Scale computed from the splat's bounds at load, so "Fit" can return to
    /// it after the user has zoomed away.
    var fittedScale: Float = SplatScale.authored

    static let scaleRange = SplatScale.range

    /// Meters. The longest horizontal extent is fitted to this on load.
    ///
    /// Dollhouse-sized rather than room-sized on purpose: a splat that's too
    /// small is obviously there and can be scaled up, whereas one that's too
    /// large puts the camera inside geometry and looks like a failed load.
    static let autoFitExtent: Float = 1.5

    // MARK: - Transform

    /// Model-to-world transform handed to the renderer each frame.
    ///
    /// Read right to left: recenter the asset on its own pivot, apply the
    /// canonical up-flip, scale, apply user rotation, then place it. The pivot
    /// bracket is what makes scale and rotation act *in place*.
    ///
    /// Scale and the up-calibration commute because the scale is uniform, so
    /// their relative order is arbitrary; a test pins the rest of the order.
    var modelMatrix: simd_float4x4 {
        var matrix = matrix4x4_translation(translation)
        matrix *= rotationMatrix
        matrix *= matrix4x4_scale(SplatScale.clamp(scale))
        if appliesUpCalibration {
            matrix *= matrix4x4_rotation(radians: .pi, axis: SIMD3<Float>(0, 0, 1))
        }
        matrix *= matrix4x4_translation(-pivot)
        return matrix
    }

    /// Intrinsic Y-X-Z. Euler rather than a quaternion because the yaw slider
    /// has to round-trip exactly, which quaternion extraction can't guarantee
    /// once pitch or roll is non-zero.
    var rotationMatrix: simd_float4x4 {
        matrix4x4_rotation(radians: yaw, axis: SIMD3<Float>(0, 1, 0))
            * matrix4x4_rotation(radians: pitch, axis: SIMD3<Float>(1, 0, 0))
            * matrix4x4_rotation(radians: roll, axis: SIMD3<Float>(0, 0, 1))
    }

    // MARK: - Mutation

    /// Returns placement to defaults, keeping asset metadata (`pivot`,
    /// `appliesUpCalibration`, `fittedScale`) intact.
    func resetPlacement() {
        scale = fittedScale
        translation = .zero
        yaw = 0
        pitch = 0
        roll = 0
    }

    /// Back to the scale computed from the splat's own bounds.
    func fitToView() {
        scale = fittedScale
    }

    /// Render at the file's authored scale, which is meaningful for ARKit-derived
    /// captures — those genuinely are metric and shouldn't be rescaled.
    func useAuthoredScale() {
        scale = SplatScale.authored
    }

    func clear() {
        loadState = .empty
        pivot = .zero
        fittedScale = SplatScale.authored
        resetPlacement()
    }
}
