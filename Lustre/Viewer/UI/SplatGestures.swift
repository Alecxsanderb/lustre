//
//  SplatGestures.swift
//  Lustre
//
//  Direct manipulation of the splat.
//
//  Everything here is two-finger, on purpose. Single-finger drags are already
//  spoken for: `VirtualJoystick` sits above the render view and uses
//  `DragGesture(minimumDistance: 0)`, and `NavigationStack` owns the leading
//  screen edge for interactive pop.
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
        // Two fingers exactly: one finger belongs to the joysticks and to the
        // navigation edge swipe.
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2

        for recognizer in [pinch, rotate, pan] as [UIGestureRecognizer] {
            recognizer.delegate = coordinator
            view.addGestureRecognizer(recognizer)
        }
        coordinator.recognizers = [pinch, rotate, pan]
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

        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
