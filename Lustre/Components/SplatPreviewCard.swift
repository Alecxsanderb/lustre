//
//  SplatPreviewCard.swift
//  Lustre
//
//  Thumbnail + metadata cell shared by Home's recents row and the Library
//  grid. The thumbnail comes from the environment's `ThumbnailStore`; until
//  it exists (or when it can't be made) the tile is a tinted placeholder.
//

import SwiftUI

struct SplatPreviewCard: View {
    let item: SplatItem
    /// Home's row has no room for a second line; the Library grid does.
    var showsDetail = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SplatThumbnail(item: item)
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

/// The rendered thumbnail when there is one, the placeholder otherwise, and
/// a small spinner over the placeholder while it's being generated.
///
/// Everything loaded is tagged with the key it was loaded for and only shown
/// while that key is current, so a LazyVGrid cell reused for another item
/// (or an item whose file changed) never shows the previous image.
struct SplatThumbnail: View {
    let item: SplatItem

    @Environment(\.thumbnailStore) private var store
    @State private var loaded: (key: ThumbnailKey, image: UIImage)?
    @State private var generatingKey: ThumbnailKey?

    var body: some View {
        let key = ThumbnailKey(item: item)
        let image = loaded?.key == key ? loaded?.image : store?.memoryImage(for: key)

        SplatThumbnailPlaceholder(item: item, showsIcon: image == nil) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if image == nil && generatingKey == key {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .padding(8)
            }
        }
        .task(id: key) {
            loaded = nil
            generatingKey = nil
            guard let store, store.memoryImage(for: key) == nil else { return }
            let image = await store.image(for: key, fileURL: item.url) { generatingKey = key }
            guard !Task.isCancelled else { return }
            generatingKey = nil
            if let image { loaded = (key, image) }
        }
    }
}

/// A tinted tile with the format badge. The tint is derived from the name so
/// neighbouring cells don't all look identical. `content` draws over the
/// tint, under the badge, clipped to the tile.
struct SplatThumbnailPlaceholder<Content: View>: View {
    let item: SplatItem
    var showsIcon = true
    @ViewBuilder var content: Content

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(tint.gradient)
            .overlay {
                if showsIcon {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .overlay { content }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

extension SplatThumbnailPlaceholder where Content == EmptyView {
    init(item: SplatItem) {
        self.init(item: item) { EmptyView() }
    }
}
