//
//  ThumbnailStore.swift
//  Lustre
//
//  The UI's handle on thumbnails: decoded images in memory in front of the
//  generator's on-disk cache. Views get it from the environment, so Home,
//  Library, and the detail sheet share one memory cache and one generator.
//

import SwiftUI
import UIKit

@MainActor
final class ThumbnailStore {

    let generator: ThumbnailGenerator

    /// Decoded, display-ready images keyed by cache hash. Bounded by decoded
    /// bytes (a 480×360 tile is ~0.7 MB), so a long scroll can't pile up.
    private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    /// Pause requests, chained so rapid Viewer push/pop lands in order.
    private var pauseTask: Task<Void, Never>?
    private var memoryWarningObserver: NSObjectProtocol?

    init(generator: ThumbnailGenerator = ThumbnailGenerator()) {
        self.generator = generator
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleMemoryWarning() }
            }
    }

    /// A decoded image already in memory. Cheap enough for a view body, which
    /// is what lets a reused cell show its image on the first frame.
    func memoryImage(for key: ThumbnailKey) -> UIImage? {
        images.object(forKey: key.hash as NSString)
    }

    /// The thumbnail for `fileURL`, generating it if there's none on disk.
    /// `onGenerating` runs only when real work is queued, so a cached image
    /// never flashes a spinner. Nil on failure or cancellation.
    func image(for key: ThumbnailKey, fileURL: URL, onGenerating: () -> Void) async -> UIImage? {
        if let cached = memoryImage(for: key) { return cached }

        let imageURL: URL
        switch await generator.cachedEntry(for: key) {
        case .image(let url):
            imageURL = url
        case .failed:
            return nil
        case .missing:
            onGenerating()
            guard case .image(let url)? = await generator.thumbnail(for: key, fileURL: fileURL) else {
                return nil
            }
            imageURL = url
        }

        // Cached even if the caller has gone: the decode is already paid for.
        guard let image = await Self.decode(imageURL) else { return nil }
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale) * 4
        images.setObject(image, forKey: key.hash as NSString, cost: cost)
        return image
    }

    /// Holds generation while the Viewer is open, so thumbnails never take
    /// memory or GPU time from it.
    func setPaused(_ paused: Bool) {
        let previous = pauseTask
        let generator = self.generator
        pauseTask = Task {
            await previous?.value
            await generator.setPaused(paused)
        }
    }

    private func handleMemoryWarning() {
        images.removeAllObjects()
        let generator = self.generator
        Task { await generator.releaseRenderer() }
    }

    /// Reads and decodes off the main actor. `byPreparingForDisplay` does the
    /// JPEG decode up front, so scrolling doesn't decode on the main thread.
    @concurrent
    private nonisolated static func decode(_ url: URL) async -> UIImage? {
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        return await image.byPreparingForDisplay()
    }
}

extension EnvironmentValues {
    /// Nil in previews and anywhere the app didn't inject one; views fall
    /// back to their placeholder.
    @Entry var thumbnailStore: ThumbnailStore? = nil
}
