//
//  CaptureCTAButton.swift
//  Lustre
//
//  The prominent "Capture new" entry. Capture is build order step 4, so for
//  now this is shown disabled with a label saying so — it keeps the layout
//  honest about where Capture will go without pretending it works.
//

import SwiftUI

struct CaptureCTAButton: View {
    var action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 30))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Capture New")
                        .font(.headline)
                    Text(action == nil ? "Coming soon" : "Record a splat-friendly video")
                        .font(.subheadline)
                        .opacity(0.8)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(action == nil)
    }
}
