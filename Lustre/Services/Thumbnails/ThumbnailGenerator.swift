//
//  ThumbnailGenerator.swift
//  Lustre
//
//  Turns library files into cached thumbnails, strictly one file at a time.
//
//  One at a time because each render holds a decimated scene (a few tens of
//  MB) plus a MetalSplatter renderer, and the point is to never compete with
//  the Viewer. Actors are reentrant, so an actor alone doesn't serialize
//  anything across its `await`s: requests go into a pending list that a
//  single worker task drains, and a request for a key that's already queued
//  or running joins it instead of adding work.
//
//  Lifecycle:
//  - A caller whose task is cancelled (a cell scrolled away) leaves the
//    queue; if nobody else wants that key, the request is dropped. A render
//    that has already started runs to completion and is cached, since most
//    of its cost is spent by then.
//  - `setPaused(true)` (the Viewer is open) cancels the in-flight read, puts
//    that request back at the front, and stops the queue. Resuming continues.
//  - The renderer is kept alive while there's work and released after
//    `idleRelease`, on pause, and on memory warnings.
//

import Foundation
import os
import SplatIO

actor ThumbnailGenerator {

    enum Outcome: Equatable, Sendable {
        case image(URL)
        /// Couldn't be thumbnailed. A marker is written when the cause is the
        /// file itself, so it isn't retried until the file changes.
        case failed
    }

    typealias PointLoader = @Sendable (URL) async throws -> [SplatPoint]
    typealias RendererFactory = @Sendable () throws -> any ThumbnailRendering

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Lustre",
                                    category: "ThumbnailGenerator")

    private struct Request {
        let key: ThumbnailKey
        let fileURL: URL
        var waiters: [UUID: CheckedContinuation<Outcome?, Never>] = [:]
    }

    let cache: ThumbnailCache
    private let loadPoints: PointLoader
    private let makeRenderer: RendererFactory
    private let idleRelease: Duration

    private var pending: [Request] = []
    private var running: Request?
    private var worker: Task<Void, Never>?
    private var isPaused = false

    private var renderer: (any ThumbnailRendering)?
    private var idleTask: Task<Void, Never>?

    init(cache: ThumbnailCache = ThumbnailCache(directory: ThumbnailCache.defaultDirectory),
         loadPoints: @escaping PointLoader = { try await SplatFileIO.loadThumbnailPoints(from: $0) },
         makeRenderer: @escaping RendererFactory = { try ThumbnailRenderer() },
         idleRelease: Duration = .seconds(10)) {
        self.cache = cache
        self.loadPoints = loadPoints
        self.makeRenderer = makeRenderer
        self.idleRelease = idleRelease
    }

    // MARK: - Requests

    /// What's on disk for `key`, without queueing anything.
    func cachedEntry(for key: ThumbnailKey) -> ThumbnailCache.Entry {
        cache.lookup(key)
    }

    /// The thumbnail for `fileURL`, generating it if needed. Nil if the
    /// calling task was cancelled before a result was ready.
    func thumbnail(for key: ThumbnailKey, fileURL: URL) async -> Outcome? {
        switch cache.lookup(key) {
        case .image(let url): return .image(url)
        case .failed: return .failed
        case .missing: break
        }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Runs synchronously on the actor, so a cancellation that
                // happened before this point is caught here and one after it
                // finds the waiter registered.
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                enqueue(key: key, fileURL: fileURL, id: id, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id, key: key) }
        }
    }

    private func enqueue(key: ThumbnailKey, fileURL: URL, id: UUID,
                         continuation: CheckedContinuation<Outcome?, Never>) {
        if running?.key == key {
            running?.waiters[id] = continuation
        } else if let index = pending.firstIndex(where: { $0.key == key }) {
            pending[index].waiters[id] = continuation
        } else {
            var request = Request(key: key, fileURL: fileURL)
            request.waiters[id] = continuation
            pending.append(request)
        }
        startWorkerIfNeeded()
    }

    private func cancelWaiter(_ id: UUID, key: ThumbnailKey) {
        if running?.key == key, let continuation = running?.waiters.removeValue(forKey: id) {
            // The render keeps going; its result is still cached.
            continuation.resume(returning: nil)
            return
        }
        guard let index = pending.firstIndex(where: { $0.key == key }),
              let continuation = pending[index].waiters.removeValue(forKey: id) else { return }
        continuation.resume(returning: nil)
        if pending[index].waiters.isEmpty {
            pending.remove(at: index)
        }
    }

    // MARK: - Pause and memory

    /// Pausing cancels the in-flight read and holds the queue; waiters keep
    /// waiting. Resuming picks up where it left off.
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            worker?.cancel()
            releaseRenderer()
        } else {
            startWorkerIfNeeded()
        }
    }

    /// Drops the renderer now if nothing is using it. A render in progress
    /// keeps its own reference and frees it when it finishes.
    func releaseRenderer() {
        idleTask?.cancel()
        idleTask = nil
        renderer = nil
    }

    // MARK: - Test hooks

    var isRendererAlive: Bool { renderer != nil }
    var queuedCount: Int { pending.count }

    // MARK: - Worker

    private func startWorkerIfNeeded() {
        // A cancelled worker that hasn't exited yet still counts: starting a
        // second one would run two files at once. It restarts itself on exit.
        guard worker == nil, !isPaused, !pending.isEmpty else { return }
        idleTask?.cancel()
        idleTask = nil
        worker = Task(priority: .utility) { await self.drain() }
    }

    private func drain() async {
        while !Task.isCancelled, !isPaused, !pending.isEmpty {
            running = pending.removeFirst()
            guard let request = running else { break }

            let outcome = await process(request)

            if outcome == nil {
                // Interrupted by a pause: back to the front, waiters intact.
                // Checked on the outcome rather than `isPaused`, which a quick
                // resume may already have cleared.
                if let interrupted = running, !interrupted.waiters.isEmpty {
                    pending.insert(interrupted, at: 0)
                }
                running = nil
                break
            }
            let waiters = running?.waiters ?? [:]
            running = nil
            for continuation in waiters.values { continuation.resume(returning: outcome) }
        }

        worker = nil
        if !isPaused && !pending.isEmpty {
            startWorkerIfNeeded()
        } else {
            scheduleIdleRelease()
        }
    }

    /// Nil only when cancelled; everything else resolves to an outcome.
    private func process(_ request: Request) async -> Outcome? {
        // Another path (a previous launch, a racing request) may have
        // produced it since it was queued.
        switch cache.lookup(request.key) {
        case .image(let url): return .image(url)
        case .failed: return .failed
        case .missing: break
        }

        do {
            let points = try await loadPoints(request.fileURL)
            try Task.checkCancellation()
            let renderer = try currentRenderer()
            let jpeg = try await renderer.renderJPEG(points: points)
            try cache.write(jpegData: jpeg, for: request.key)
            return .image(cache.imageURL(for: request.key))
        } catch {
            // A pause cancels the read, which can surface as any error the
            // interrupted reader happened to throw. Never mark a file failed
            // for that.
            if Task.isCancelled || error is CancellationError { return nil }
            if Self.isPermanent(error) {
                Self.log.info("No thumbnail for \(request.fileURL.lastPathComponent): \(error.localizedDescription)")
                try? cache.markFailed(request.key)
            } else {
                Self.log.error("Thumbnail failed, will retry later: \(String(describing: error))")
            }
            return .failed
        }
    }

    /// Failures that come from the file itself, and so will recur until it
    /// changes (which changes its key). GPU trouble and cache write errors
    /// are transient and get another try next time the tile appears.
    static func isPermanent(_ error: Error) -> Bool {
        if error is SplatFileIO.LoadError { return true }
        if let renderError = error as? ThumbnailRenderer.RenderError {
            return renderError == .noFinitePoints
        }
        return false
    }

    private func currentRenderer() throws -> any ThumbnailRendering {
        if let renderer { return renderer }
        let made = try makeRenderer()
        renderer = made
        return made
    }

    private func scheduleIdleRelease() {
        idleTask?.cancel()
        guard renderer != nil else { return }
        let delay = idleRelease
        idleTask = Task(priority: .utility) {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self.releaseIfIdle()
        }
    }

    private func releaseIfIdle() {
        guard worker == nil else { return }
        renderer = nil
        idleTask = nil
    }
}
