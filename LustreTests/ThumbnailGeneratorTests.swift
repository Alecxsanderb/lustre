//
//  ThumbnailGeneratorTests.swift
//  LustreTests
//
//  Queueing, serialization, cancellation, pause, and failure markers, with a
//  stub loader and renderer so nothing touches the GPU or a real file.
//

import Foundation
import os
import simd
import SplatIO
import Testing
@testable import Lustre

// MARK: - Stubs

/// Stands in for `SplatFileIO.loadThumbnailPoints`. Records every call,
/// tracks how many run at once, and can hold calls at a gate the way a slow
/// read would (a cancelled wait throws, like a cancelled reader).
private final class LoaderProbe: @unchecked Sendable {
    private struct State {
        var calls: [String] = []
        var active = 0
        var maxActive = 0
        var cancellations = 0
        var gated: Set<String> = []
        var gates: [String: OneShotSignal] = [:]
        var errors: [String: Error] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var delay: Duration = .zero

    var calls: [String] { state.withLock { $0.calls } }
    var maxActive: Int { state.withLock { $0.maxActive } }
    var cancellations: Int { state.withLock { $0.cancellations } }

    /// Holds loads of `name` until `open(name)`.
    func hold(_ name: String) { state.withLock { $0.gated.insert(name) } }
    func open(_ name: String) {
        let gate = state.withLock { state -> OneShotSignal? in
            state.gated.remove(name)
            return state.gates.removeValue(forKey: name)
        }
        gate?.fire()
    }
    func fail(_ name: String, with error: Error) { state.withLock { $0.errors[name] = error } }

    func load(_ url: URL) async throws -> [SplatPoint] {
        let name = url.lastPathComponent
        let (gate, error) = state.withLock { state -> (OneShotSignal?, Error?) in
            state.calls.append(name)
            state.active += 1
            state.maxActive = max(state.maxActive, state.active)
            var gate: OneShotSignal?
            if state.gated.contains(name) {
                gate = OneShotSignal()
                state.gates[name] = gate
            }
            return (gate, state.errors[name])
        }
        defer { state.withLock { $0.active -= 1 } }

        if delay > .zero { try await Task.sleep(for: delay) }
        if let gate, await gate.wait(timeout: .seconds(30)) == false {
            state.withLock { $0.cancellations += 1 }
            throw CancellationError()
        }
        if let error { throw error }
        return [SplatPoint(position: .zero,
                           color: .sphericalHarmonicFloat([SIMD3<Float>(repeating: 0)]),
                           opacity: .linearFloat(1),
                           scale: .linearFloat(SIMD3<Float>(repeating: 0.1)),
                           rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))]
    }
}

private final class StubRenderer: ThumbnailRendering, @unchecked Sendable {
    let error: Error?
    init(error: Error? = nil) { self.error = error }

    @concurrent func renderJPEG(points: [SplatPoint]) async throws -> Data {
        if let error { throw error }
        return Data([0xFF, 0xD8, 0xFF, 0xD9])
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    func increment() { lock.withLock { $0 += 1 } }
    var value: Int { lock.withLock { $0 } }
}

// MARK: - Helpers

private struct Fixture {
    let directory: TemporaryDirectory
    let cache: ThumbnailCache
    let probe = LoaderProbe()
    let renderersMade = Counter()
    let generator: ThumbnailGenerator

    init(renderError: Error? = nil, idleRelease: Duration = .seconds(10)) throws {
        directory = try TemporaryDirectory()
        cache = ThumbnailCache(directory: directory.url.appending(path: "Thumbnails"))
        let probe = self.probe
        let renderersMade = self.renderersMade
        generator = ThumbnailGenerator(cache: cache,
                                       loadPoints: { try await probe.load($0) },
                                       makeRenderer: {
                                           renderersMade.increment()
                                           return StubRenderer(error: renderError)
                                       },
                                       idleRelease: idleRelease)
    }

    func key(_ name: String) -> ThumbnailKey {
        ThumbnailKey(fileName: name, fileSize: 1, modificationDate: Date(timeIntervalSince1970: 0),
                     rendererVersion: 1)
    }

    func url(_ name: String) -> URL { URL(filePath: "/splats/\(name)") }

    func request(_ name: String) -> Task<ThumbnailGenerator.Outcome?, Never> {
        let generator = self.generator, key = key(name), url = url(name)
        return Task { await generator.thumbnail(for: key, fileURL: url) }
    }

    func isImage(_ outcome: ThumbnailGenerator.Outcome?) -> Bool {
        if case .image = outcome { return true }
        return false
    }
}

/// Polls until `condition` holds, failing the test after `timeout`.
private func eventually(timeout: Duration = .seconds(5),
                        _ condition: () async -> Bool,
                        sourceLocation: SourceLocation = #_sourceLocation) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition not met within \(timeout)", sourceLocation: sourceLocation)
}

// MARK: - Tests

struct ThumbnailGeneratorTests {

    @Test func cachedImageReturnedWithoutWork() async throws {
        let fixture = try Fixture()
        defer { fixture.directory.remove() }
        try fixture.cache.write(jpegData: Data([1]), for: fixture.key("a.ply"))

        let outcome = await fixture.request("a.ply").value
        #expect(outcome == .image(fixture.cache.imageURL(for: fixture.key("a.ply"))))
        #expect(fixture.probe.calls.isEmpty)
        #expect(fixture.renderersMade.value == 0)
    }

    @Test func cachedFailureReturnedWithoutWork() async throws {
        let fixture = try Fixture()
        defer { fixture.directory.remove() }
        try fixture.cache.markFailed(fixture.key("bad.ply"))

        #expect(await fixture.request("bad.ply").value == .failed)
        #expect(fixture.probe.calls.isEmpty)
    }

    @Test func generatesAndCaches() async throws {
        let fixture = try Fixture()
        defer { fixture.directory.remove() }

        guard case .image(let url) = await fixture.request("a.ply").value else {
            Issue.record("expected an image"); return
        }
        #expect(fixture.cache.lookup(fixture.key("a.ply")) == .image(url))
        #expect(fixture.probe.calls == ["a.ply"])
    }

    @Test func duplicateRequestsShareOneRender() async throws {
        let fixture = try Fixture()
        defer { fixture.directory.remove() }
        fixture.probe.hold("a.ply")

        let first = fixture.request("a.ply")
        await eventually { fixture.probe.calls == ["a.ply"] }
        let second = fixture.request("a.ply")   // joins the running request
        let third = fixture.request("b.ply")
        let fourth = fixture.request("b.ply")   // joins the queued request
        await eventually { await fixture.generator.queuedCount == 1 }
        fixture.probe.open("a.ply")

        for task in [first, second, third, fourth] {
            #expect(fixture.isImage(await task.value))
        }
        #expect(fixture.probe.calls == ["a.ply", "b.ply"])
    }

    @Test func neverRunsTwoFilesAtOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.directory.remove() }
        fixture.probe.delay = .milliseconds(20)

        let names = (0..<5).map { "splat\($0).ply" }
        let tasks = names.map(fixture.request)
        for task in tasks { #expect(fixture.isImage(await task.value)) }

        #expect(fixture.probe.maxActive == 1)
        #expect(Set(fixture.probe.calls) == Set(names))
        #expect(fixture.probe.calls.count == names.count)
        // One renderer serves the whole batch.
        #expect(fixture.renderersMade.value == 1)
    }

    @Test func cancellingAQueuedRequestRemovesIt() async throws {
        let fixture = try Fixture()
        defer { fixture.directory.remove() }
        fixture.probe.hold("a.ply")

        let running = fixture.request("a.ply")
        await eventually { fixture.probe.calls == ["a.ply"] }
        let queued = fixture.request("b.ply")
        await eventually { await fixture.generator.queuedCount == 1 }

        queued.cancel()
        #expect(await queued.value == nil)
        await eventually { await fixture.generator.queuedCount == 0 }

        fixture.probe.open("a.ply")
        #expect(fixture.isImage(await running.value))
        // Give a (buggy) worker the chance to pick b up anyway.
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.probe.calls == ["a.ply"])
        #expect(fixture.cache.lookup(fixture.key("b.ply")) == .missing)
    }

    @Test func cancellingARunningRequestStillCachesIt() async throws {
        let fixture = try Fixture()
        defer { fixture.directory.remove() }
        fixture.probe.hold("a.ply")

        let task = fixture.request("a.ply")
        await eventually { fixture.probe.calls == ["a.ply"] }
        task.cancel()
        #expect(await task.value == nil)

        fixture.probe.open("a.ply")
        await eventually {
            if case .image = fixture.cache.lookup(fixture.key("a.ply")) { return true }
            return false
        }
        #expect(fixture.probe.cancellations == 0)
    }

    @Test func pauseStopsTheQueueAndResumeContinues() async throws {
        let fixture = try Fixture()
        defer { fixture.directory.remove() }
        fixture.probe.hold("a.ply")

        let a = fixture.request("a.ply")
        await eventually { fixture.probe.calls == ["a.ply"] }
        let b = fixture.request("b.ply")
        await eventually { await fixture.generator.queuedCount == 1 }

        await fixture.generator.setPaused(true)
        // The in-flight read is cancelled, not failed...
        await eventually { fixture.probe.cancellations == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.cache.lookup(fixture.key("a.ply")) == .missing)
        // ...and nothing else starts while paused.
        #expect(fixture.probe.calls == ["a.ply"])
        #expect(await fixture.generator.queuedCount == 2)
        #expect(await fixture.generator.isRendererAlive == false)

        fixture.probe.open("a.ply")   // later loads of a pass straight through
        await fixture.generator.setPaused(false)
        #expect(fixture.isImage(await a.value))
        #expect(fixture.isImage(await b.value))
        #expect(fixture.probe.calls == ["a.ply", "a.ply", "b.ply"])
    }

    @Test func quickPauseAndResumeDoesNotDropWaiters() async throws {
        let fixture = try Fixture()
        defer { fixture.directory.remove() }
        fixture.probe.hold("a.ply")

        let a = fixture.request("a.ply")
        await eventually { fixture.probe.calls == ["a.ply"] }
        fixture.probe.open("a.ply")
        // Back to back: resume can land before the worker sees the cancellation.
        await fixture.generator.setPaused(true)
        await fixture.generator.setPaused(false)

        #expect(fixture.isImage(await a.value))
        #expect(fixture.probe.maxActive == 1)
    }

    @Test(arguments: [SplatFileIO.LoadError.truncated(URL(filePath: "/x")),
                      .malformed(URL(filePath: "/x")),
                      .empty(URL(filePath: "/x")),
                      .stalled(URL(filePath: "/x")),
                      .unreadableFile(URL(filePath: "/x")),
                      .tooLargeForThumbnail(URL(filePath: "/x"))])
    func fileFailuresWriteAMarker(error: SplatFileIO.LoadError) async throws {
        let fixture = try Fixture()
        defer { fixture.directory.remove() }
        fixture.probe.fail("bad.ply", with: error)

        #expect(await fixture.request("bad.ply").value == .failed)
        #expect(fixture.cache.lookup(fixture.key("bad.ply")) == .failed)

        // The marker stops it from being read again.
        #expect(await fixture.request("bad.ply").value == .failed)
        #expect(fixture.probe.calls == ["bad.ply"])
    }

    @Test func transientRenderFailureIsNotMarked() async throws {
        let fixture = try Fixture(renderError: ThumbnailRenderer.RenderError.renderSkipped)
        defer { fixture.directory.remove() }

        #expect(await fixture.request("a.ply").value == .failed)
        #expect(fixture.cache.lookup(fixture.key("a.ply")) == .missing)
    }

    @Test func rendererIsReleasedWhenIdle() async throws {
        let fixture = try Fixture(idleRelease: .milliseconds(50))
        defer { fixture.directory.remove() }

        _ = await fixture.request("a.ply").value
        await eventually { await fixture.generator.isRendererAlive == false }
        _ = await fixture.request("b.ply").value
        #expect(fixture.renderersMade.value == 2)
    }
}
