//
//  SplatStreamWatchdogTests.swift
//  LustreTests
//
//  Stall limits: the thumbnail path gives up on a stuck reader in seconds,
//  while the Viewer keeps the full default. The one timing test waits about
//  4 s (the thumbnail limit), never the Viewer's 20.
//

import Foundation
import Testing
import simd
import SplatIO
@testable import Lustre

struct SplatStreamWatchdogTests {

    @Test func viewerKeepsTheFullDefaultAndThumbnailsAreShorter() {
        #expect(SplatStreamWatchdog.defaultStallTickLimit == 20)
        #expect(SplatFileIO.thumbnailStallTickLimit == 4)
    }

    /// Runs the thumbnail path and the Viewer's `readAll` against the same
    /// kind of stuck reader at once. The thumbnail read must fail as stalled
    /// within its short limit while the Viewer read, still on its default,
    /// hasn't given up yet.
    @Test(.timeLimit(.minutes(1)))
    func thumbnailPathFailsFastWhileViewerReadKeepsWaiting() async throws {
        let viewerRead = Task {
            try await SplatStreamWatchdog.readAll(StallingReader())
        }

        let clock = ContinuousClock()
        let start = clock.now
        let url = URL(filePath: "/stuck.ply")
        await #expect {
            _ = try await SplatFileIO.thumbnailPoints(from: StallingReader(), url: url, cap: 100)
        } throws: { error in
            guard case SplatFileIO.LoadError.stalled(let reported) = error else { return false }
            return reported == url
        }
        let elapsed = clock.now - start

        // A batch arrives first, so the limit of 4 ticks means 3-4 idle
        // seconds. Upper bound has slack for a loaded CI simulator.
        #expect(elapsed >= .seconds(2.5))
        #expect(elapsed < .seconds(8))

        // Past the thumbnail limit, the Viewer read must still be running.
        viewerRead.cancel()
        let viewerResult = await viewerRead.result
        switch viewerResult {
        case .failure(let error):
            #expect(!(error is SplatStreamWatchdog.Stalled), "Viewer read used the short limit")
        case .success(let points):
            Issue.record("Stuck reader finished with \(points.count) points")
        }
    }
}

/// Yields one batch, then never produces another or finishes, like
/// MetalSplatter's PLY reader after it swallows a mid-body error.
/// Cancelling the consuming task ends the iteration.
private struct StallingReader: SplatSceneReader {
    func read() async throws -> AsyncThrowingStream<[SplatPoint], Error> {
        AsyncThrowingStream { continuation in
            continuation.yield([SplatPoint(position: .zero,
                                           color: .sRGBUInt8(.zero),
                                           opacity: .linearFloat(1),
                                           scale: .linearFloat(.one),
                                           rotation: simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)))])
        }
    }
}
