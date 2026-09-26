//
//  SplatFileIOTests.swift
//  LustreTests
//
//  End-to-end through MetalSplatter's real readers, using small generated
//  files. Checks that the Viewer and thumbnail paths share validation and
//  that the thumbnail path decimates and strips SH.
//

import Foundation
import Testing
import SplatIO
@testable import Lustre

struct SplatFileIOTests {

    // MARK: - Fixtures

    /// Binary little-endian 3DGS PLY with degree-3 SH. Point i sits at x = i.
    private static func plyData(count: Int) -> Data {
        var properties = ["x", "y", "z", "f_dc_0", "f_dc_1", "f_dc_2"]
        properties += (0..<45).map { "f_rest_\($0)" }
        properties += ["opacity", "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"]
        var header = "ply\nformat binary_little_endian 1.0\nelement vertex \(count)\n"
        header += properties.map { "property float \($0)\n" }.joined()
        header += "end_header\n"

        var data = Data(header.utf8)
        var row = [Float](repeating: 0, count: properties.count)
        for i in 0..<count {
            row[0] = Float(i)
            for j in 3..<51 { row[j] = 0.1 }       // SH, all bands
            row[51] = 2                             // opacity (logit)
            row[52] = -3; row[53] = -3; row[54] = -3 // log scale
            row[55] = 1                             // rot_0 (w)
            row.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Antimatter15 `.splat`: 32 bytes per point.
    private static func dotSplatData(count: Int) -> Data {
        var data = Data()
        for i in 0..<count {
            let floats: [Float] = [Float(i), 0, 0, 0.05, 0.05, 0.05]
            floats.withUnsafeBytes { data.append(contentsOf: $0) }
            data.append(contentsOf: [200, 100, 50, 255])  // RGBA
            data.append(contentsOf: [255, 128, 128, 128]) // rotation
        }
        return data
    }

    private func write(_ data: Data, named name: String, in directory: TemporaryDirectory) throws -> URL {
        let url = directory.url.appending(path: name)
        try data.write(to: url)
        return url
    }

    private func loadError(_ body: () async throws -> Void) async -> SplatFileIO.LoadError? {
        do {
            try await body()
            return nil
        } catch let error as SplatFileIO.LoadError {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    // MARK: - Thumbnail path

    @Test func thumbnailDecimatesAndStripsPLY() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = try write(Self.plyData(count: 5_000), named: "room.ply", in: directory)

        let points = try await SplatFileIO.loadThumbnailPoints(from: url, cap: 1_000)

        #expect(points.count <= 1_000 && points.count > 500)
        #expect(points.allSatisfy { $0.color.shDegree == .sh0 })
        // Evenly spread: first and last kept points bracket the file.
        #expect(points.first?.position.x == 0)
        #expect((points.last?.position.x ?? 0) > 4_000)
    }

    @Test func thumbnailKeepsSmallFilesWhole() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = try write(Self.dotSplatData(count: 300), named: "small.splat", in: directory)
        let points = try await SplatFileIO.loadThumbnailPoints(from: url, cap: 1_000)
        #expect(points.count == 300)
    }

    @Test func viewerPathStillLoadsEverythingWithSH() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = try write(Self.plyData(count: 2_000), named: "room.ply", in: directory)
        let points = try await SplatFileIO.loadPoints(from: url)
        #expect(points.count == 2_000)
        #expect(points.first?.color.shDegree == .sh3)
    }

    @Test func largeSPZIsSkippedBeforeReading() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        // Sparse: sets the size without writing the whole file. Its contents are
        // garbage, so reaching the reader would fail differently.
        let url = directory.url.appending(path: "huge.spz")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(SplatFileIO.maximumThumbnailSPZBytes) + 1)
        try handle.close()

        let error = await loadError { _ = try await SplatFileIO.loadThumbnailPoints(from: url) }
        guard case .tooLargeForThumbnail = error else {
            Issue.record("expected tooLargeForThumbnail, got \(String(describing: error))"); return
        }
    }

    // MARK: - Shared validation

    /// Both paths reject the same files with the same error. The zero-vertex
    /// PLYs used to hang in MetalSplatter's reader until the watchdog's 20 s
    /// stall; the preflight now reports them as empty up front.
    @Test(.timeLimit(.minutes(1)),
          arguments: ["scan.sog", "notes.txt", "cut.ply", "empty.splat", "zero.ply", "zero-ascii.ply"])
    func bothPathsRejectAlike(name: String) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let data: Data
        switch name {
        case "cut.ply": data = Self.plyData(count: 10).dropLast(7)
        case "empty.splat": data = Data()
        case "zero.ply": data = Self.plyData(count: 0)
        case "zero-ascii.ply":
            data = Data("ply\nformat ascii 1.0\nelement vertex 0\nproperty float x\nproperty float y\nproperty float z\nend_header\n".utf8)
        default: data = Data([1, 2, 3])
        }
        let url = try write(data, named: name, in: directory)

        let start = ContinuousClock.now
        let viewer = await loadError { _ = try await SplatFileIO.loadPoints(from: url) }
        let thumbnail = await loadError { _ = try await SplatFileIO.loadThumbnailPoints(from: url) }
        // Rejected up front, not by the watchdog after a stall.
        #expect(ContinuousClock.now - start < .seconds(5))

        let expected: String
        switch name {
        case "scan.sog": expected = "notYetSupported"
        case "notes.txt": expected = "unsupportedFormat"
        case "cut.ply": expected = "truncated"
        default: expected = "empty"
        }
        #expect(viewer.map(Self.caseName) == expected)
        #expect(thumbnail.map(Self.caseName) == expected)
    }

    private static func caseName(_ error: SplatFileIO.LoadError) -> String {
        String(describing: error).components(separatedBy: "(").first ?? ""
    }
}
