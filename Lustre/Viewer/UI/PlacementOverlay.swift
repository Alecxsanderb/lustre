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
    /// Observed, and only changes when the state does, so this view doesn't
    /// re-render every frame while the crosshair moves.
    var readiness: PlacementReadiness
    /// The pose provider's tracking message, shown while there's no candidate.
    var statusMessage: String?
    var onPlace: () -> Void

    private var presentation: Presentation {
        Presentation(readiness: readiness, statusMessage: statusMessage)
    }

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
            Image(systemName: presentation.bannerSymbol)
                .foregroundStyle(presentation.isOnSurface ? .green : .secondary)
            Text(presentation.bannerText)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    /// Marks the raycast origin, so it's obvious what the app is aiming at.
    private var crosshair: some View {
        let color = presentation.isOnSurface ? Color.green : Color.white.opacity(0.6)
        return ZStack {
            Circle()
                .stroke(color, lineWidth: 2)
                .frame(width: 28, height: 28)
            Circle()
                .fill(color)
                .frame(width: 4, height: 4)
        }
        .animation(.easeOut(duration: 0.15), value: presentation.isOnSurface)
    }

    private var placeButton: some View {
        Button(action: onPlace) {
            Label(presentation.buttonTitle, systemImage: "arrow.down.to.line")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        // Orange, not `.secondary`: a grey prominent button reads as disabled,
        // and "Place anyway" is a real, tappable choice — just a flagged one.
        .tint(presentation.buttonEmphasis == .grounded ? Color.accentColor : Color.orange)
        .disabled(!presentation.isButtonEnabled)
    }
}

extension PlacementOverlay {

    /// Everything the overlay shows, derived from readiness alone, so the
    /// mapping is testable without rendering a view.
    nonisolated struct Presentation: Equatable, Sendable {

        nonisolated enum ButtonEmphasis: Equatable, Sendable {
            /// On a surface: the normal, expected action.
            case grounded
            /// No surface: allowed, but visibly a guess.
            case tentative
        }

        let isOnSurface: Bool
        let isButtonEnabled: Bool
        let buttonTitle: String
        let buttonEmphasis: ButtonEmphasis
        let bannerSymbol: String
        let bannerText: String

        static let startingTrackingText = "Starting tracking — move the phone slowly."

        init(readiness: PlacementReadiness, statusMessage: String?) {
            switch readiness {
            case .onSurface:
                isOnSurface = true
                isButtonEnabled = true
                buttonTitle = "Place"
                buttonEmphasis = .grounded
                bannerSymbol = "checkmark.circle.fill"
                bannerText = "Surface found — tap Place to set the splat here."
            case .estimated:
                // Placing without a surface drops the splat a fixed distance
                // ahead; it's labelled so the user knows it's a guess.
                isOnSurface = false
                isButtonEnabled = true
                buttonTitle = "Place anyway"
                buttonEmphasis = .tentative
                bannerSymbol = "viewfinder"
                bannerText = "Point the camera at a flat surface and move slowly."
            case .unavailable:
                // No candidate means tracking isn't ready, so "point at a
                // surface" would be the wrong instruction.
                isOnSurface = false
                isButtonEnabled = false
                buttonTitle = "Place anyway"
                buttonEmphasis = .tentative
                bannerSymbol = "arrow.triangle.2.circlepath"
                bannerText = statusMessage ?? Self.startingTrackingText
            }
        }
    }
}
