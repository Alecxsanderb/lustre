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

import SwiftUI
import UIKit
import simd

struct SplatGestureLayer: UIViewRepresentable {
    var sceneState: SplatSceneState
    var isEnabled: Bool
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
            // tracking SwiftUI's `Toggle` depends on — every switch in the
            // control menu silently stopped working.
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            view.addGestureRecognizer(recognizer)
        }
        coordinator.recognizers = [pinch, rotate, pan, dolly]
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.sceneState = sceneState
        context.coordinator.cameraTransform = cameraTransform
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

        var sceneState: SplatSceneState
        var cameraTransform: () -> simd_float4x4
        var recognizers: [UIGestureRecognizer] = []

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

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                scaleAtStart = sceneState.scale
            case .changed:
                guard let scaleAtStart else { return }
                sceneState.scale = SplatScale.clamp(scaleAtStart * Float(recognizer.scale))
            default:
                scaleAtStart = nil
            }
        }

        @objc func handleRotate(_ recognizer: UIRotationGestureRecognizer) {
            switch recognizer.state {
            case .began:
                yawAtStart = sceneState.yaw
            case .changed:
                guard let yawAtStart else { return }
                // Negated so the splat turns with the fingers, not against them.
                sceneState.yaw = yawAtStart - Float(recognizer.rotation)
            default:
                yawAtStart = nil
            }
        }

        /// Horizontal drag slides the splat along the camera's flattened
        /// heading; vertical drag raises and lowers it in world space.
        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                translationAtStart = sceneState.translation
                // Snapshotted once so the axes can't rotate mid-gesture.
                basisAtStart = CameraRelativeBasis(cameraTransform: cameraTransform())
            case .changed:
                guard let translationAtStart, let basisAtStart else { return }
                let translation = recognizer.translation(in: recognizer.view)
                sceneState.translation = translationAtStart + basisAtStart.worldDelta(
                    right: Float(translation.x) / Self.pointsPerMeter,
                    up: Float(-translation.y) / Self.pointsPerMeter,
                    forward: 0)
            default:
                translationAtStart = nil
                basisAtStart = nil
            }
        }

        /// Vertical one-finger drag pushes the splat along the camera's
        /// heading: down pulls it toward you, up pushes it away. Horizontal
        /// movement is ignored so a sloppy drag doesn't also slide it sideways.
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

        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        /// Only take touches that actually landed on the gesture layer itself.
        ///
        /// Without this, these recognizers observe touches destined for the
        /// SwiftUI controls layered above and cancel them. Buttons survive
        /// (they fire on touch-up), but `Toggle` tracks the touch continuously
        /// and loses it — which silently broke every switch in the menu.
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
