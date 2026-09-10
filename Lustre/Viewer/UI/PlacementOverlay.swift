//
//  PlacementOverlay.swift
//  Lustre
//
//  The "where does this go?" step shown after loading a splat.
//
//  Deliberately its own interaction rather than a menu item: it's modal by
//  nature, it happens once per splat, and it needs the whole screen to coach
//  the user to sweep for a surface. Re-placing later is a menu action.
//

import SwiftUI

struct PlacementOverlay: View {
    var candidate: PlacementCandidate?
    var hasDetectedSurface: Bool
    var onPlace: () -> Void

    private var isReady: Bool { candidate?.isOnSurface == true }

    var body: some View {
        VStack {
            // Coaching text and crosshair are decoration — touches belong to
            // the gesture layer underneath, so the user can still frame the
            // splat while placing it.
            VStack {
                coachingBanner
                    .padding(.top, 8)
                Spacer()
                crosshair
                Spacer()
            }
            .allowsHitTesting(false)

            placeButton
                .padding(.bottom, 28)
        }
        .padding(.horizontal, 20)
    }

    private var coachingBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "viewfinder")
                .foregroundStyle(isReady ? .green : .secondary)
            Text(isReady
                 ? "Surface found — tap Place to set the splat here."
                 : "Point the camera at a flat surface and move slowly.")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    /// Marks the raycast origin, so it's obvious what the app is aiming at.
    private var crosshair: some View {
        ZStack {
            Circle()
                .stroke(isReady ? Color.green : Color.white.opacity(0.6), lineWidth: 2)
                .frame(width: 28, height: 28)
            Circle()
                .fill(isReady ? Color.green : Color.white.opacity(0.6))
                .frame(width: 4, height: 4)
        }
        .animation(.easeOut(duration: 0.15), value: isReady)
    }

    private var placeButton: some View {
        Button(action: onPlace) {
            Label(isReady ? "Place" : "Place anyway", systemImage: "arrow.down.to.line")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(isReady ? .accentColor : .secondary)
        // Placing without a surface is allowed — it drops the splat a fixed
        // distance ahead — but it's labelled so the user knows it's a guess.
        .disabled(candidate == nil)
    }
}
