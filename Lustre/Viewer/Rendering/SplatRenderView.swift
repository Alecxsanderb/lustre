//
//  SplatRenderView.swift
//  Lustre
//
//  SwiftUI wrapper around the MTKView that SplatRenderer draws into.
//

import MetalKit
import SwiftUI

struct SplatRenderView: UIViewRepresentable {
    let renderer: SplatRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        renderer.configure(view)
        view.delegate = renderer
        view.isOpaque = false
        view.backgroundColor = .clear
        view.preferredFramesPerSecond = 60
        // Continuous rather than on-demand: the pose changes every frame while
        // a joystick is held or the device is moving.
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}
}
