//
//  ContentView.swift
//  Lustre
//
//  Created by Alec Borer on 6/24/26.
//
//  Navigation root. Home replaces this as the landing screen in build order
//  step 2; for now it's the shortest path into the Viewer.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                    Text("Lustre")
                        .font(.largeTitle.weight(.semibold))
                    Text("Capture and walk through Gaussian splats.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                NavigationLink {
                    ViewerScreen()
                } label: {
                    Label("Open Viewer", systemImage: "cube.transparent")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text(Self.poseModeDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
        }
    }

    /// Surfaces which pose path is active, so a simulator run doesn't look
    /// like broken AR.
    private static var poseModeDescription: String {
        #if targetEnvironment(simulator)
        "Simulator build — camera is driven by the on-screen joysticks. AR tracking needs a physical device."
        #else
        "Move the phone to walk through the splat."
        #endif
    }
}

#Preview {
    ContentView()
}
