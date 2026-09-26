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
    /// declared stuck, unless the caller passes its own limit. Readers yield
    /// every few thousand points, so a healthy read never comes close. The
    /// Viewer uses this; the thumbnail path passes a much shorter limit
    /// because its queue is serial and a stall there holds up every tile.
    ///
    /// Counted in ticks rather than elapsed time on purpose: if the app is
    /// suspended mid-load, both tasks freeze together and a resumed tick
    /// counts once, where a clock would see the whole suspension as idle.
    ///
    /// Granularity: ticks run on their own one-second clock and a batch only
    /// zeroes the count, so a limit of N fires after N seconds with no first
    /// batch, or after between N-1 and N idle seconds mid-stream.
    static let defaultStallTickLimit = 20

    struct Stalled: Error {}

    static func readAll(_ reader: SplatSceneReader,
                        stallTickLimit: Int = defaultStallTickLimit) async throws -> [SplatPoint] {
        try await drain(reader, into: [SplatPoint](), stallTickLimit: stallTickLimit) { points, batch in
            points.append(contentsOf: batch)
        }
    }

    /// Feeds every batch to `consume` as it arrives instead of collecting
    /// them, so a caller that keeps only some points (thumbnail decimation)
    /// never holds the whole file. Same stall protection as `readAll`.
    static func drain<State: Sendable>(
        _ reader: SplatSceneReader,
        into initialState: State,
        stallTickLimit: Int = defaultStallTickLimit,
        _ consume: @escaping @Sendable (inout State, [SplatPoint]) -> Void
    ) async throws -> State {
        precondition(stallTickLimit >= 1, "A zero limit would fail every read after one second")
        let stream = try await reader.read()
        let idleTicks = OSAllocatedUnfairLock(initialState: 0)

        return try await withThrowingTaskGroup(of: State.self) { group in
            group.addTask {
                var state = initialState
                for try await batch in stream {
                    consume(&state, batch)
                    idleTicks.withLock { $0 = 0 }
                }
                // A cancelled stream ends like a finished one; don't pass off
                // a partial read as complete.
                try Task.checkCancellation()
                return state
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

            // Whichever finishes first decides: the result, or a stall. Either
            // way the other task is no longer wanted. Cancelling the reader
            // task also terminates the stalled stream, releasing it.
            defer { group.cancelAll() }
            guard let state = try await group.next() else {
                throw CancellationError()
            }
            return state
        }
    }
}
