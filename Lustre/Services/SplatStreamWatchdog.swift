//
//  SplatStreamWatchdog.swift
//  Lustre
//
//  Drains a `SplatSceneReader` like `readAll()`, but gives up if the stream
//  stops producing batches.
//
//  Backstop for `PLYPreflight`. MetalSplatter 1.0.1's PLY reader drops any
//  error PLYIO throws mid-body and leaves its stream open forever (see
//  PLYPreflight.swift). The preflight catches the cases a file size reveals;
//  this catches the rest — a malformed ASCII row, a truncated list-bearing
//  binary — which would otherwise leave the Viewer on "Loading…" for good.
//

import Foundation
import os
import SplatIO

nonisolated enum SplatStreamWatchdog {

    /// Consecutive one-second ticks without a batch before the read is
    /// declared stuck. Readers yield every few thousand points, so a healthy
    /// read never comes close.
    ///
    /// Counted in ticks rather than elapsed time on purpose: if the app is
    /// suspended mid-load, both tasks freeze together and a resumed tick
    /// counts once, where a clock would see the whole suspension as idle.
    static let stallTickLimit = 20

    struct Stalled: Error {}

    static func readAll(_ reader: SplatSceneReader) async throws -> [SplatPoint] {
        let stream = try await reader.read()
        let idleTicks = OSAllocatedUnfairLock(initialState: 0)

        return try await withThrowingTaskGroup(of: [SplatPoint].self) { group in
            group.addTask {
                var points: [SplatPoint] = []
                for try await batch in stream {
                    points.append(contentsOf: batch)
                    idleTicks.withLock { $0 = 0 }
                }
                // A cancelled stream ends like a finished one; don't pass off
                // a partial read as complete.
                try Task.checkCancellation()
                return points
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: .seconds(1))
                    let ticks = idleTicks.withLock { ticks in
                        ticks += 1
                        return ticks
                    }
                    if ticks >= stallTickLimit { throw Stalled() }
                }
            }

            // Whichever finishes first decides: the points, or a stall. Either
            // way the other task is no longer wanted. Cancelling the reader
            // task also terminates the stalled stream, releasing it.
            defer { group.cancelAll() }
            guard let points = try await group.next() else {
                throw CancellationError()
            }
            return points
        }
    }
}
