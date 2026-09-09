//
//  VirtualJoystick.swift
//  Lustre
//
//  Reusable analog stick. Lives in Components because the Viewer's simulator
//  controls and (eventually) any other on-screen control surface both need it.
//

import simd
import SwiftUI

/// A thumb-stick that reports a normalized vector in the unit circle.
///
/// `value.x` is right-positive, `value.y` is **up-positive** — the y axis is
/// flipped relative to SwiftUI's downward-growing coordinate space so callers
/// get the convention they expect from a stick.
struct VirtualJoystick: View {
    @Binding var value: SIMD2<Float>

    var label: String
    var diameter: CGFloat = 120

    private var knobRadius: CGFloat { diameter / 5 }
    private var travel: CGFloat { diameter / 2 - knobRadius }

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))

            Circle()
                .fill(.white.opacity(0.75))
                .frame(width: knobRadius * 2, height: knobRadius * 2)
                .offset(x: CGFloat(value.x) * travel,
                        y: CGFloat(-value.y) * travel)
                .animation(.interactiveSpring, value: value)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    value = normalized(translation: gesture.translation)
                }
                .onEnded { _ in
                    value = .zero
                }
        )
        .accessibilityLabel(label)
    }

    /// Clamps the drag to the stick's travel and flips y to up-positive.
    private func normalized(translation: CGSize) -> SIMD2<Float> {
        var offset = SIMD2<Float>(Float(translation.width), Float(-translation.height))
        let magnitude = length(offset)
        guard magnitude > 0 else { return .zero }

        // Clamp to the edge of the well, then express as a fraction of full travel.
        let clamped = min(magnitude, Float(travel))
        offset = offset / magnitude * (clamped / Float(travel))
        return offset
    }
}

#Preview {
    struct Harness: View {
        @State private var value = SIMD2<Float>.zero
        var body: some View {
            VStack(spacing: 24) {
                Text(String(format: "%.2f, %.2f", value.x, value.y))
                    .monospacedDigit()
                VirtualJoystick(value: $value, label: "Preview stick")
            }
            .padding()
            .background(.black)
        }
    }
    return Harness()
}
