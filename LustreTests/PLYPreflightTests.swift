//
//  PLYPreflightTests.swift
//  LustreTests
//

import Foundation
import Testing
@testable import Lustre

struct PLYPreflightTests {

    /// Three floats per vertex: 12 bytes a row.
    private static func header(format: String = "binary_little_endian",
                               vertexCount: String = "10",
                               extraLines: [String] = []) -> String {
        (["ply",
          "format \(format) 1.0",
          "comment made by a test",
          "element vertex \(vertexCount)",
          "property float x",
          "property float y",
          "property float z"] + extraLines + ["end_header"])
            .joined(separator: "\n") + "\n"
    }

    private static func verdict(header: String, bodyBytes: Int64) -> PLYPreflight.Verdict {
        let data = Data(header.utf8)
        let fileSize = UInt64(Int64(data.count) + bodyBytes)
        return PLYPreflight.check(prefix: data, fileSize: fileSize)
    }

    @Test("Binary body size against the header", arguments: [
        (Int64(120), PLYPreflight.Verdict.proceed),
        (119, .truncated),
        (121, .trailingData),
        (0, .truncated),
    ])
    func binaryBodySize(bodyBytes: Int64, expected: PLYPreflight.Verdict) {
        #expect(Self.verdict(header: Self.header(), bodyBytes: bodyBytes) == expected)
    }

    @Test func bigEndianUsesTheSameSizeRule() {
        let header = Self.header(format: "binary_big_endian")
        #expect(Self.verdict(header: header, bodyBytes: 120) == .proceed)
        #expect(Self.verdict(header: header, bodyBytes: 119) == .truncated)
        #expect(Self.verdict(header: header, bodyBytes: 121) == .trailingData)
    }

    @Test func multipleElementsSumTheirRows() {
        // 10 × 12 + 4 × (1 + 8) = 156.
        let header = Self.header(extraLines: ["element extra 4",
                                              "property uchar flag",
                                              "property double weight"])
        #expect(Self.verdict(header: header, bodyBytes: 156) == .proceed)
        #expect(Self.verdict(header: header, bodyBytes: 155) == .truncated)
        #expect(Self.verdict(header: header, bodyBytes: 157) == .trailingData)
    }

    /// A list's row length depends on its per-row counts, so only a lower
    /// bound is known: short is still truncated, long is not trailing data.
    @Test func listPropertiesOnlyBoundTheSizeFromBelow() {
        // 10 × 12 + 2 × 1 (the uchar count field only) = 122 minimum.
        let header = Self.header(extraLines: ["element face 2",
                                              "property list uchar int vertex_indices"])
        #expect(Self.verdict(header: header, bodyBytes: 122) == .proceed)
        #expect(Self.verdict(header: header, bodyBytes: 146) == .proceed)
        #expect(Self.verdict(header: header, bodyBytes: 121) == .truncated)
    }

    @Test func listOnAnEmptyElementKeepsTheSizeExact() {
        let header = Self.header(extraLines: ["element face 0",
                                              "property list uchar int vertex_indices"])
        #expect(Self.verdict(header: header, bodyBytes: 121) == .trailingData)
    }

    @Test func asciiBodiesAreLeftToTheLibrary() {
        let header = Self.header(format: "ascii")
        #expect(Self.verdict(header: header, bodyBytes: 0) == .proceed)
        #expect(Self.verdict(header: header, bodyBytes: 10_000) == .proceed)
    }

    @Test("Headers this check doesn't understand proceed", arguments: [
        "plx\nformat binary_little_endian 1.0\nelement vertex 10\nproperty float x\nend_header\n",
        "ply\nformat binary_little_endian 1.0\nelement vertex 10\nproperty float x\n",
        "ply\nformat binary_little_endian 1.0\nelement vertex 10\nproperty quaternion q\nend_header\n",
        "ply\nformat binary_little_endian 1.0\nproperty float x\nend_header\n",
        "ply\nformat wavelet 1.0\nelement vertex 10\nproperty float x\nend_header\n",
        "ply\nformat binary_little_endian 1.0\nelement vertex ten\nproperty float x\nend_header\n",
        "ply\nformat binary_little_endian 1.0\nmystery keyword\nend_header\n",
    ])
    func unrecognizedHeadersProceed(header: String) {
        // Short enough that a real size check would have said truncated.
        #expect(Self.verdict(header: header, bodyBytes: 0) == .proceed)
    }

    @Test func elementCountBeyondUInt32IsMalformed() {
        let tooMany = String(UInt64(UInt32.max) + 1)
        #expect(Self.verdict(header: Self.header(vertexCount: tooMany), bodyBytes: 0) == .malformedHeader)
    }

    @Test func elementCountAtUInt32MaxIsSizeChecked() {
        let header = Self.header(vertexCount: String(UInt32.max))
        #expect(Self.verdict(header: header, bodyBytes: 120) == .truncated)
    }

    /// The largest body a bounded header can declare is far below 2^64, so
    /// what's checked here is that the arithmetic stays exact near the top of
    /// the file-size range rather than wrapping.
    @Test func hugeDeclaredBodiesDontWrap() {
        let header = Self.header(vertexCount: String(UInt32.max),
                                 extraLines: (0..<64).map { "property double d\($0)" })
        let data = Data(header.utf8)
        let body = UInt64(UInt32.max) * (12 + 64 * 8)
        let exact = UInt64(data.count) + body
        #expect(PLYPreflight.check(prefix: data, fileSize: exact) == .proceed)
        #expect(PLYPreflight.check(prefix: data, fileSize: exact - 1) == .truncated)
        #expect(PLYPreflight.check(prefix: data, fileSize: UInt64.max) == .trailingData)
    }

    @Test func checksFilesOnDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ply")
        defer { try? FileManager.default.removeItem(at: url) }

        var data = Data(Self.header().utf8)
        data.append(Data(count: 120))
        try data.write(to: url)
        #expect(try PLYPreflight.check(url) == .proceed)

        data.removeLast()
        try data.write(to: url)
        #expect(try PLYPreflight.check(url) == .truncated)
    }
}
