//
//  RecentSplatsRow.swift
//  Lustre
//

import SwiftUI

struct RecentSplatsRow: View {
    let items: [SplatItem]
    let onOpen: (SplatItem) -> Void
    let onOpenSample: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent")
                .font(.title3.weight(.semibold))

            if items.isEmpty {
                // The sample stands in until there's something real, so a
                // first launch still has one tap to a rendered scene.
                Button(action: onOpenSample) {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.title2)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open the Sample Room")
                                .font(.subheadline.weight(.medium))
                            Text("Nothing here yet. Import a splat from the Library, or try the built-in scene.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding()
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(items) { item in
                            Button { onOpen(item) } label: {
                                SplatPreviewCard(item: item, showsDetail: false)
                                    .frame(width: 150)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
            }
        }
    }
}
