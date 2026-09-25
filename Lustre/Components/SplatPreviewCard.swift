//
//  SplatPreviewCard.swift
//  Lustre
//
//  Thumbnail + metadata cell shared by Home's recents row and the Library
//  grid. The thumbnail is a placeholder until `ThumbnailGenerator` exists
//  (Polish pass, build order step 8).
//

import SwiftUI

struct SplatPreviewCard: View {
    let item: SplatItem
    /// Home's row has no room for a second line; the Library grid does.
    var showsDetail = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SplatThumbnailPlaceholder(item: item)
                .aspectRatio(4 / 3, contentMode: .fit)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if showsDetail {
                    Text("\(item.dateAdded.formatted(date: .abbreviated, time: .omitted)) · \(item.fileSize.formatted(.byteCount(style: .file)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A tinted tile with the format badge. The tint is derived from the name so
/// neighbouring cells don't all look identical.
struct SplatThumbnailPlaceholder: View {
    let item: SplatItem

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(tint.gradient)
            .overlay {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .overlay(alignment: .topLeading) {
                Text(item.formatLabel)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }
    }

    private var tint: Color {
        // FNV-1a: stable across launches, unlike `hashValue`, which is seeded
        // per run — and unlike a plain byte sum, similar names spread apart.
        let hash = item.name.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.45, brightness: 0.6)
    }
}
