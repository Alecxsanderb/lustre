//
//  OneShotSignal.swift
//  Lustre
//
//  A flag that can be awaited with a timeout. Bridges MetalSplatter's
//  callback-style `afterNextSort` into async code without risking a hang:
//  that handler only fires after a sort that *succeeds*, so a sort that's
//  invalidated or never scheduled would otherwise leave the waiter parked
//  forever.
//
//  `fire()` before `wait` counts: the waiter returns immediately. That
//  ordering matters because the thumbnail renderer registers the handler
//  before handing the sorter a pose, and the sort can finish before the
//  renderer gets around to waiting.
//

import Foundation
import os

nonisolated final class OneShotSignal: Sendable {

    private struct State {
        var fired = false
        var continuation: CheckedContinuation<Bool, Never>?
        var timeout: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func fire() {
        resume(fired: true)
    }

    /// True if `fire()` was called before `timeout` elapsed (or before the
    /// wait began); false on timeout or cancellation. One waiter only.
    func wait(timeout: Duration) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let alreadyFired = state.withLock { state in
                    if state.fired { return true }
                    state.continuation = continuation
                    return false
                }
                if alreadyFired {
                    continuation.resume(returning: true)
                    return
                }
                // Checked after registering, so a cancellation that landed
                // before the handler was installed isn't missed.
                if Task.isCancelled {
                    resume(fired: false)
                    return
                }
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.resume(fired: false)
                }
                state.withLock { $0.timeout = timeoutTask }
            }
        } onCancel: {
            resume(fired: false)
        }
    }

    /// Resumes the waiter, if any, exactly once.
    private func resume(fired: Bool) {
        let (continuation, timeout) = state.withLock { state in
            if fired { state.fired = true }
            let pending = (state.continuation, state.timeout)
            state.continuation = nil
            state.timeout = nil
            return pending
        }
        timeout?.cancel()
        continuation?.resume(returning: fired)
    }
}
