//
//  SimulatorControlsOverlay.swift
//  Lustre
//
//  Dual joysticks, shown only when the pose is simulated. Lives in the Viewer
//  (not Components) because it's bound to SimulatedPoseProvider; the generic
//  stick it's built from is the reusable part, and that's in Components.
//

import SwiftUI

struct SimulatorControlsOverlay: View {
    @Bindable var provider: SimulatedPoseProvider

    var body: some View {
        HStack {
            VirtualJoystick(value: $provider.moveInput, label: "Move")
            Spacer()
            VirtualJoystick(value: $provider.lookInput, label: "Look")
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 32)
    }
}
