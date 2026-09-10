//
//  SplatGestures.swift
//  Lustre
//
//  Direct manipulation of the splat.
//
//  Two-finger gestures scale, rotate, and slide the splat. One finger — the
//  most-reached-for control, pushing a too-close splat away — is a vertical
//  dolly along the camera's heading.
//
//  One finger is safe *outside* the joystick wells: `VirtualJoystick` sits
//  above the render view with `.contentShape(Circle())`, so it only claims
//  touches inside its circle. The leading screen edge is excluded explicitly,
//  because `NavigationStack` owns it for interactive pop.
//
//  All three recognizers are UIKit rather than SwiftUI. A `UIView` hosting a
//  recognizer consumes touches before any SwiftUI gesture layered beneath it
//  runs, so mixing the two silently dropped pinch and rotate. Keeping them in
//  one recognizer set also makes simultaneous recognition explicit — users
//  pinch, rotate, and drag as one continuous motion.
//
//  Simultaneous recognition is also why axis lock exists: with all three live
//  at once, a two-finger drag that isn't perfectly steady also scales and
//  rotates a little. Locking makes the first clear intent win the whole
//  gesture.
//

import SwiftUI
import UIKit
import simd

struct SplatGestureLayer: UIViewRepresentable {
    var sceneState: SplatSceneState
    var isEnabled: Bool
    /// When true, one two-finger gesture changes one thing.
    var locksToSingleAxis: Bool
    /// Camera-to-world, read once per gesture to build a stable axis basis.
    var cameraTransform: () -> simd_float4x4

    func makeCoordinator() -> Coordinator {
        Coordinator(sceneState: sceneState, cameraTransform: cameraTransform)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let coordinator = context.coordinator

        let pinch = UIPinchGestureRecognizer(target: coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        let rotate = UIRotationGestureRecognizer(target: coordinator,
                                                 action: #selector(Coordinator.handleRotate(_:)))
        let pan = UIPanGestureRecognizer(target: coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2

        let dolly = UIPanGestureRecognizer(target: coordinator,
                                           action: #selector(Coordinator.handleDolly(_:)))
        dolly.minimumNumberOfTouches = 1
        // Ends as soon as a second finger lands, handing over to pan/pinch.
        dolly.maximumNumberOfTouches = 1

        for recognizer in [pinch, rotate, pan, dolly] as [UIGestureRecognizer] {
            recognizer.delegate = coordinator
            // Recognizing must not cancel or delay touches being delivered
            // elsewhere. By default a recognizer sends touchesCancelled to the
            // hit-tested view when it recognizes, which kills the continuous
            // tracking SwiftUI's `Toggle` depends on.
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            view.addGestureRecognizer(recognizer)
        }
        coordinator.recognizers = [pinch, rotate, pan, dolly]
        coordinator.twoFingerRecognizers = [pinch, rotate, pan]
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.sceneState = sceneState
        context.coordinator.cameraTransform = cameraTransform
        context.coordinator.locksToSingleAxis = locksToSingleAxis
        for recognizer in context.coordinator.recognizers {
            recognizer.isEnabled = isEnabled
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {

        /// Screen points per meter of movement. A full-width two-finger drag
        /// moves the splat about a meter.
        private static let pointsPerMeter: Float = 320

        /// Dolly is coarser than lateral panning — pushing a splat out of your
        /// face is a bigger movement than nudging it sideways.
        private static let dollyPointsPerMeter: Float = 160

        /// Touches starting this close to the leading edge are left to
        /// `NavigationStack`'s interactive-pop recognizer.
        private static let leadingEdgeExclusion: CGFloat = 24

        /// How far a gesture has to go before it can claim the interaction.
        /// Loose enough that a deliberate movement wins immediately, tight
        /// enough that the incidental drift in the other two never does.
        private static let translateThreshold: Float = 14      // points
        private static let scaleThreshold: Float = 0.08        // fraction
        private static let rotateThreshold: Float = 0.10       // radians

        /// What a two-finger gesture has committed to changing, while axis lock
        /// is on. Cleared when every finger is off the screen.
        private enum Claim {
            case translate
            case scale
            case rotate
        }

        private enum PanAxis {
            case horizontal
            case vertical
        }

        var sceneState: SplatSceneState
        var cameraTransform: () -> simd_float4x4
        var locksToSingleAxis = false
        var recognizers: [UIGestureRecognizer] = []
        var twoFingerRecognizers: [UIGestureRecognizer] = []

        private var claim: Claim?
        private var panAxis: PanAxis?

        // Captured at gesture start. UIKit reports cumulative values, so
        // composing against these is what keeps repeated gestures from
        // drifting — accumulating scale per callback compounds exponentially.
        private var scaleAtStart: Float?
        private var yawAtStart: Float?
        private var translationAtStart: SIMD3<Float>?
        private var basisAtStart: CameraRelativeBasis?
        private var dollyTranslationAtStart: SIMD3<Float>?
        private var dollyBasisAtStart: CameraRelativeBasis?

        init(sceneState: SplatSceneState, cameraTransform: @escaping () -> simd_float4x4) {
            self.sceneState = sceneState
            self.cameraTransform = cameraTransform
        }

        // MARK: - Axis lock

        /// Whether `candidate` may act this frame.
        ///
        /// With lock off, everything always may. With it on, the first gesture
        /// to move past its threshold takes the interaction and the others go
        /// quiet until the fingers lift — including the pinch, which is
        /// otherwise the easiest one to trigger by accident while dragging.
        private func mayAct(_ candidate: Claim, magnitude: Float, threshold: Float) -> Bool {
            guard locksToSingleAxis else { return true }
            if let claim { return claim == candidate }
            guard magnitude > threshold else { return false }
            claim = candidate
            return true
        }

        /// Only safe once every two-finger recognizer has stopped: they end a
        /// fraction apart, and clearing on the first would hand the tail of one
        /// gesture to another.
        private func releaseClaimIfIdle() {
            let stillActive = twoFingerRecognizers.contains {
                $0.state == .began || $0.state == .changed
            }
            guard !stillActive else { return }
            claim = nil
            panAxis = nil
        }

        // MARK: - Handlers

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                scaleAtStart = sceneState.scale
            case .changed:
                guard let scaleAtStart else { return }
                let factor = Float(recognizer.scale)
                guard mayAct(.scale, magnitude: abs(factor - 1), threshold: Self.scaleThreshold)
                else { return }
                sceneState.scale = SplatScale.clamp(scaleAtStart * factor)
            default:
                scaleAtStart = nil
                releaseClaimIfIdle()
            }
        }

        @objc func handleRotate(_ recognizer: UIRotationGestureRecognizer) {
            switch recognizer.state {
            case .began:
                yawAtStart = sceneState.yaw
            case .changed:
                guard let yawAtStart else { return }
                let rotation = Float(recognizer.rotation)
                guard mayAct(.rotate, magnitude: abs(rotation), threshold: Self.rotateThreshold)
                else { return }
                // Negated so the splat turns with the fingers, not against them.
                sceneState.yaw = yawAtStart - rotation
            default:
                yawAtStart = nil
                releaseClaimIfIdle()
            }
        }

        /// Horizontal drag slides the splat along the camera's flattened
        /// heading; vertical drag raises and lowers it in world space. Under
        /// axis lock only whichever of those the drag started as applies.
        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                translationAtStart = sceneState.translation
                // Snapshotted once so the axes can't rotate mid-gesture.
                basisAtStart = CameraRelativeBasis(cameraTransform: cameraTransform())
            case .changed:
                guard let translationAtStart, let basisAtStart else { return }
                let translation = recognizer.translation(in: recognizer.view)
                let dx = Float(translation.x)
                let dy = Float(-translation.y)
                guard mayAct(.translate,
                             magnitude: (dx * dx + dy * dy).squareRoot(),
                             threshold: Self.translateThreshold)
                else { return }

                var right = dx
                var up = dy
                if locksToSingleAxis {
                    // Decided once, at the moment the drag became a drag —
                    // re-deciding per frame would let the axis flip mid-gesture.
                    if panAxis == nil {
                        panAxis = abs(dx) >= abs(dy) ? .horizontal : .vertical
                    }
                    if panAxis == .horizontal { up = 0 } else { right = 0 }
                }

                sceneState.translation = translationAtStart + basisAtStart.worldDelta(
                    right: right / Self.pointsPerMeter,
                    up: up / Self.pointsPerMeter,
                    forward: 0)
            default:
                translationAtStart = nil
                basisAtStart = nil
                releaseClaimIfIdle()
            }
        }

        /// Vertical one-finger drag pushes the splat along the camera's
        /// heading: down pulls it toward you, up pushes it away. Horizontal
        /// movement is ignored so a sloppy drag doesn't also slide it sideways.
        ///
        /// Already single-axis by construction, so axis lock doesn't touch it.
        @objc func handleDolly(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                dollyTranslationAtStart = sceneState.translation
                dollyBasisAtStart = CameraRelativeBasis(cameraTransform: cameraTransform())
            case .changed:
                guard let dollyTranslationAtStart, let dollyBasisAtStart else { return }
                let translation = recognizer.translation(in: recognizer.view)
                // UIKit y grows downward, so dragging up is negative.
                let forward = Float(-translation.y) / Self.dollyPointsPerMeter
                sceneState.translation = dollyTranslationAtStart + dollyBasisAtStart.worldDelta(
                    right: 0, up: 0, forward: forward)
            default:
                dollyTranslationAtStart = nil
                dollyBasisAtStart = nil
            }
        }

        // MARK: - Delegate

        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Still simultaneous even under axis lock: the recognizers all need
            // to run so the *first* one past its threshold can be identified.
            // Arbitration happens in `mayAct`, not here.
            true
        }

        /// Only take touches that actually landed on the gesture layer itself.
        ///
        /// Without this, these recognizers observe touches destined for the
        /// SwiftUI controls layered above and cancel them. Buttons survive
        /// (they fire on touch-up), but `Toggle` tracks the touch continuously
        /// and would lose it.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            touch.view === recognizer.view
        }

        /// Keeps the one-finger dolly off the interactive-pop edge.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer,
                  pan.maximumNumberOfTouches == 1,
                  let view = pan.view else { return true }
            return pan.location(in: view).x > Self.leadingEdgeExclusion
        }
    }
}
