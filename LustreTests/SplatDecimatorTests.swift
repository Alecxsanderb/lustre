//
//  SplatDecimatorTests.swift
//  LustreTests
//

import Foundation
import Testing
import simd
import SplatIO
@testable import Lustre

struct SplatDecimatorTests {

    /// Feeds 0..<count in batches of `batchSize`, as a reader would.
    private func decimate(_ count: Int, cap: Int, batchSize: Int = 1_000) -> StrideDecimator<Int> {
        var decimator = StrideDecimator<Int>(cap: cap)
        for start in stride(from: 0, to: count, by: batchSize) {
            decimator.add(start..<min(start + batchSize, count))
        }
        return decimator
    }

    @Test func keepsEverythingUnderCap() {
        let decimator = decimate(500, cap: 1_000)
        #expect(decimator.kept == Array(0..<500))
        #expect(decimator.stride == 1)
        #expect(decimator.consumedCount == 500)
    }

    @Test func keepsEverythingExactlyAtCap() {
        #expect(decimate(1_000, cap: 1_000).kept == Array(0..<1_000))
    }

    @Test(arguments: [1_001, 2_000, 12_345, 100_000])
    func neverExceedsCap(count: Int) {
        // Check after every batch, not just at the end: the cap bounds peak memory.
        var decimator = StrideDecimator<Int>(cap: 1_000)
        for start in stride(from: 0, to: count, by: 777) {
            decimator.add(start..<min(start + 777, count))
            #expect(decimator.kept.count <= 1_000)
        }
        #expect(decimator.consumedCount == count)
        // Halving only happens on overflow, so at least half the cap survives.
        #expect(decimator.kept.count > 500)
    }

    @Test func keptIndicesAreMultiplesOfStrideAcrossWholeInput() {
        let count = 100_000
        let decimator = decimate(count, cap: 1_000)
        let step = decimator.stride
        #expect(decimator.kept == Array(stride(from: 0, to: count, by: step)))
        // Spans the file: the last kept index is within one stride of the end.
        #expect((decimator.kept.last ?? -1) >= count - step)
    }

    @Test func deterministicRegardlessOfBatching() {
        let a = decimate(54_321, cap: 2_000, batchSize: 1)
        let b = decimate(54_321, cap: 2_000, batchSize: 10_000)
        #expect(a.kept == b.kept)
        #expect(a.stride == b.stride)
    }

    @Test func transformAppliesOnlyToKeptPoints() {
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        var decimator = StrideDecimator<Int>(cap: 10) { value in
            counter.calls += 1
            return value * 10
        }
        decimator.add(0..<100)
        #expect(decimator.kept.allSatisfy { $0 % 10 == 0 })
        // Far fewer transforms than inputs: discarded points are never touched.
        #expect(counter.calls < 100)
    }

    // MARK: - Spherical harmonics

    private func point(color: SplatPoint.Color) -> SplatPoint {
        SplatPoint(position: .zero, color: color, opacity: .linearFloat(1),
                   scale: .linearFloat(SIMD3(repeating: 0.1)), rotation: simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)))
    }

    @Test func stripsHigherOrderSHToFirstCoefficient() {
        let coefficients = (0..<16).map { SIMD3<Float>(repeating: Float($0) + 0.5) }
        let stripped = SplatDecimator.strippingHigherOrderSH(point(color: .sphericalHarmonicFloat(coefficients)))
        guard case .sphericalHarmonicFloat(let kept) = stripped.color else {
            Issue.record("color representation changed"); return
        }
        #expect(kept == [coefficients[0]])
        #expect(stripped.color.shDegree == .sh0)
    }

    @Test func leavesDegreeZeroAndSRGBAlone() {
        let sh0 = SplatDecimator.strippingHigherOrderSH(point(color: .sphericalHarmonicFloat([SIMD3(1, 2, 3)])))
        #expect(sh0.color.sh0 == SIMD3(1, 2, 3))

        let srgb = SplatDecimator.strippingHigherOrderSH(point(color: .sRGBUInt8(SIMD3(10, 20, 30))))
        guard case .sRGBUInt8(let value) = srgb.color else {
            Issue.record("sRGB should pass through"); return
        }
        #expect(value == SIMD3(10, 20, 30))
    }

    @Test func emptyCoefficientsDoNotTrap() {
        let empty = SplatDecimator.strippingHigherOrderSH(point(color: .sphericalHarmonicFloat([])))
        guard case .sphericalHarmonicFloat(let kept) = empty.color else {
            Issue.record("color representation changed"); return
        }
        #expect(kept.isEmpty)
    }

    @Test func splatDecimatorStripsWhileKeeping() {
        let coefficients = (0..<4).map { SIMD3<Float>(repeating: Float($0)) }
        var decimator = SplatDecimator.make(cap: 8)
        decimator.add((0..<50).map { _ in point(color: .sphericalHarmonicFloat(coefficients)) })
        #expect(decimator.kept.count <= 8)
        #expect(decimator.kept.allSatisfy { $0.color.shDegree == .sh0 })
    }

    // MARK: - Watchdog drain

    @Test func drainFeedsEveryBatchThroughTheConsumer() async throws {
        let batches = (0..<25).map { batch in
            (0..<1_000).map { i in
                SplatPoint(position: SIMD3(Float(batch * 1_000 + i), 0, 0),
                           color: .sRGBUInt8(.zero), opacity: .linearFloat(1),
                           scale: .linearFloat(.one), rotation: simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)))
            }
        }
        let result = try await SplatStreamWatchdog.drain(FakeReader(batches: batches),
                                                         into: SplatDecimator.make(cap: 1_000)) { decimator, batch in
            decimator.add(batch)
        }
        #expect(result.consumedCount == 25_000)
        #expect(result.kept.count <= 1_000)
        #expect(result.kept.map { Int($0.position.x) } == Array(stride(from: 0, to: 25_000, by: result.stride)))
    }

    @Test func readAllStillCollectsEverything() async throws {
        let batches = [[point(color: .sRGBUInt8(.zero))], [point(color: .sRGBUInt8(.one))]]
        let points = try await SplatStreamWatchdog.readAll(FakeReader(batches: batches))
        #expect(points.count == 2)
    }
}

private struct FakeReader: SplatSceneReader {
    let batches: [[SplatPoint]]

    func read() async throws -> AsyncThrowingStream<[SplatPoint], Error> {
        AsyncThrowingStream { continuation in
            for batch in batches { continuation.yield(batch) }
            continuation.finish()
        }
    }
}
