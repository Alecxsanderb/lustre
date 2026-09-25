//
//  HomeView.swift
//  Lustre
//
//  Landing screen: recent splats, the way into the Library and Settings, and
//  the (not yet built) Capture entry. Reads the library; never mutates it.
//

import SwiftUI

struct HomeView: View {
    let library: SplatLibrary
    let onOpen: (SplatItem) -> Void
    let onOpenSample: () -> Void
    let onBrowseLibrary: () -> Void
    let onOpenSettings: () -> Void

    private static let recentLimit = 5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                CaptureCTAButton()

                RecentSplatsRow(items: library.recentItems(limit: Self.recentLimit),
                                onOpen: onOpen,
                                onOpenSample: onOpenSample)

                Button(action: onBrowseLibrary) {
                    HStack {
                        Label("Browse Library", systemImage: "square.grid.2x2")
                        Spacer()
                        Text(library.items.count, format: .number)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding()
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                Text(Self.poseModeDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
        .navigationTitle("Lustre")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape", action: onOpenSettings)
            }
        }
        .refreshable { library.refresh() }
    }

    /// Surfaces which pose path is active, so a simulator run doesn't look
    /// like broken AR.
    private static var poseModeDescription: String {
        #if targetEnvironment(simulator)
        "Simulator build — the camera is driven by on-screen joysticks. AR tracking needs a physical device."
        #else
        "Open a splat, then move the phone to walk through it."
        #endif
    }
}
