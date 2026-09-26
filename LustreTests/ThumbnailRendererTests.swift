//
//  ThumbnailRendererTests.swift
//  LustreTests
//
//  Sequencing and retry policy against a stub backend (no GPU), the timeout
//  signal it relies on, and one real render through MetalSplatter, which
//  runs in the simulator on Apple Silicon.
//

import CoreGraphics
import Foundation
import os
import simd
import SplatIO
import Testing
@testable import Lustre

// MARK: - Stub backend

private final class StubBackend: ThumbnailRenderBackend, @unchecked Sendable {
    enum Step: Equatable { case load, prime, render, unload }

    private let lock = OSAllocatedUnfairLock(initialState: [Step]())
    /// Frames to skip (return nil) before returning an image.
    private let skips: Int
    private let renderError: Error?
    private(set) var cameras: [ThumbnailCamera] = []

    init(skips: Int = 0, renderError: Error? = nil) {
        self.skips = skips
        self.renderError = renderError
    }

    var steps: [Step] { lock.withLock { $0 } }
    private func record(_ step: Step) { lock.withLock { $0.append(step) } }

    func load(_ points: [SplatPoint]) async throws { record(.load) }
    func unload() async { record(.unload) }

    func primeSort(camera: ThumbnailCamera) async throws -> Bool {
        record(.prime)
        return false // A sort timeout must not abort the render.
    }

    func renderFrame(camera: ThumbnailCamera) async throws -> CGImage? {
        record(.render)
        cameras.append(camera)
        if let renderError { throw renderError }
        let rendersSoFar = steps.filter { $0 == .render }.count
        return rendersSoFar > skips ? Self.image : nil
    }

    static let image: CGImage = {
        let context = CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        return context.makeImage()!
    }()
}

private struct Boom: Error {}

private func points(_ positions: [SIMD3<Float>]) -> [SplatPoint] {
    positions.map {
        SplatPoint(position: $0,
                   color: .sphericalHarmonicFloat([SIMD3<Float>(0.5, 0.5, 0.5)]),
                   opacity: .linearFloat(1),
                   scale: .linearFloat(SIMD3<Float>(repeating: 0.05)),
                   rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
    }
}

private let cube = points([SIMD3(-1, -1, -1), SIMD3(1, 1, 1), SIMD3(0, 0, 0), SIMD3(1, -1, 0)])

struct ThumbnailRendererSequencingTests {

    @Test func primesTwiceThenKeepsOneFrame() async throws {
        let backend = StubBackend()
        let data = try await ThumbnailRenderer(backend: backend).renderJPEG(points: cube)
        #expect(backend.steps == [.load, .prime, .prime, .render, .unload])
        // JPEG SOI marker.
        #expect(data.prefix(2) == Data([0xFF, 0xD8]))
    }

    @Test func retriesSkippedFramesWithAPrimeBetween() async throws {
        let backend = StubBackend(skips: 2)
        _ = try await ThumbnailRenderer(backend: backend).renderImage(points: cube)
        #expect(backend.steps == [.load, .prime, .prime,
                                  .render, .prime, .render, .prime, .render,
                                  .unload])
    }

    @Test func givesUpAfterBoundedSkipsAndStillUnloads() async throws {
        let backend = StubBackend(skips: .max)
        await #expect(throws: ThumbnailRenderer.RenderError.renderSkipped) {
            _ = try await ThumbnailRenderer(backend: backend).renderImage(points: cube)
        }
        #expect(backend.steps.filter { $0 == .render }.count == ThumbnailRenderer.maxFrameAttempts)
        #expect(backend.steps.last == .unload)
    }

    @Test func backendErrorPropagatesAndUnloads() async throws {
        let backend = StubBackend(renderError: Boom())
        await #expect(throws: Boom.self) {
            _ = try await ThumbnailRenderer(backend: backend).renderImage(points: cube)
        }
        #expect(backend.steps.last == .unload)
    }

    @Test func noFinitePointsFailsBeforeTouchingTheGPU() async throws {
        let backend = StubBackend()
        let bad = points([SIMD3(.nan, 0, 0), SIMD3(.infinity, 1, 1)])
        await #expect(throws: ThumbnailRenderer.RenderError.noFinitePoints) {
            _ = try await ThumbnailRenderer(backend: backend).renderImage(points: bad)
        }
        #expect(backend.steps.isEmpty)
    }

    @Test func cancellationStopsAndUnloads() async throws {
        let backend = StubBackend(skips: .max)
        let renderer = ThumbnailRenderer(backend: backend)
        let task = Task {
            // Cancelled before the first step runs, so the check after load throws.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await renderer.renderImage(points: cube)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(backend.steps.isEmpty)
    }

    /// The camera handed to the GPU is the framing camera composed with the
    /// library model transform, so the thumbnail matches the Viewer.
    @Test func cameraIncludesTheLibraryTransform() throws {
        let camera = try #require(ThumbnailRenderer.camera(for: cube))
        let bounds = try #require(SplatBounds.robust(of: cube.lazy.map(\.position)))
        let model = ThumbnailFraming.libraryModelMatrix(for: bounds)
        let framing = ThumbnailFraming.camera(for: ThumbnailFraming.transformed(bounds, by: model),
                                              aspect: 4.0 / 3.0)
        #expect(camera.view == framing.view * model)
        #expect(camera.projection == framing.projection)
    }
}

struct OneShotSignalTests {

    @Test func fireBeforeWaitReturnsImmediately() async {
        let signal = OneShotSignal()
        signal.fire()
        #expect(await signal.wait(timeout: .seconds(10)))
    }

    @Test func fireDuringWaitWakesIt() async {
        let signal = OneShotSignal()
        Task {
            try? await Task.sleep(for: .milliseconds(20))
            signal.fire()
        }
        let start = ContinuousClock.now
        #expect(await signal.wait(timeout: .seconds(10)))
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func timesOutWhenNeverFired() async {
        let start = ContinuousClock.now
        #expect(await OneShotSignal().wait(timeout: .milliseconds(50)) == false)
        #expect(ContinuousClock.now - start >= .milliseconds(50))
    }

    @Test func cancellationEndsTheWait() async {
        let task = Task { await OneShotSignal().wait(timeout: .seconds(30)) }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        #expect(await task.value == false)
    }
}

// MARK: - GPU

struct ThumbnailRendererIntegrationTests {

    /// A 3DGS-style (Y-down) PLY: a 12³ grid over [-1, 1]³, red where the
    /// file's y < 0 and blue elsewhere. After the Viewer's up flip, file y < 0
    /// is world up, so red must land in the top of the image.
    private static func twoToneGridPLY() -> Data {
        let properties = ["x", "y", "z", "f_dc_0", "f_dc_1", "f_dc_2",
                          "opacity", "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"]
        let side = 12
        var header = "ply\nformat binary_little_endian 1.0\nelement vertex \(side * side * side)\n"
        header += properties.map { "property float \($0)\n" }.joined()
        header += "end_header\n"
        var data = Data(header.utf8)
        for i in 0..<side { for j in 0..<side { for k in 0..<side {
            let position = SIMD3<Float>(Float(i), Float(j), Float(k)) / Float(side - 1) * 2 - 1
            // SH0 of ±1.7 is ~0.98 / ~0.02 after the 0.5 + 0.282·c conversion.
            let color: SIMD3<Float> = position.y < 0 ? SIMD3(1.7, -1.7, -1.7) : SIMD3(-1.7, -1.7, 1.7)
            let row: [Float] = [position.x, position.y, position.z, color.x, color.y, color.z,
                                3, -2.5, -2.5, -2.5, 1, 0, 0, 0]
            row.withUnsafeBytes { data.append(contentsOf: $0) }
        }}}
        return data
    }

    /// RGBA8 pixels of `image`, row 0 at the top.
    private static func pixels(of image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    @Test(.timeLimit(.minutes(1)))
    func rendersAFramedUprightImage() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.url.appending(path: "grid.ply")
        try Self.twoToneGridPLY().write(to: url)

        let points = try await SplatFileIO.loadThumbnailPoints(from: url)
        let renderer = try ThumbnailRenderer()
        let image = try await renderer.renderImage(points: points)
        #expect(image.width == ThumbnailRenderer.width && image.height == ThumbnailRenderer.height)

        let bytes = Self.pixels(of: image)
        let width = image.width, height = image.height
        func mean(rows: Range<Int>, channel: Int) -> Double {
            var total = 0
            for y in rows { for x in 0..<width { total += Int(bytes[(y * width + x) * 4 + channel]) } }
            return Double(total) / Double(rows.count * width)
        }

        // Not a flat fill: something was drawn over the black clear.
        var distinct = Set<UInt32>()
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let red = UInt32(bytes[offset]) << 16
            let green = UInt32(bytes[offset + 1]) << 8
            distinct.insert(red | green | UInt32(bytes[offset + 2]))
        }
        #expect(distinct.count > 50)

        // Framed: the corners stay background, the center has the splat.
        let corner = Int(bytes[0]) + Int(bytes[1]) + Int(bytes[2])
        let center = ((height / 2) * width + width / 2) * 4
        #expect(corner < 30)
        #expect(Int(bytes[center]) + Int(bytes[center + 1]) + Int(bytes[center + 2]) > 60)

        // Upright: red on top, blue at the bottom, as the Viewer shows it.
        let top = (height / 5)..<(height * 2 / 5)
        let bottom = (height * 3 / 5)..<(height * 4 / 5)
        #expect(mean(rows: top, channel: 0) > mean(rows: bottom, channel: 0) + 10)
        #expect(mean(rows: bottom, channel: 2) > mean(rows: top, channel: 2) + 10)

        let jpeg = try #require(ThumbnailRenderer.jpegData(from: image, quality: ThumbnailRenderer.jpegQuality))
        #expect(jpeg.count > 1_000)
    }
}
