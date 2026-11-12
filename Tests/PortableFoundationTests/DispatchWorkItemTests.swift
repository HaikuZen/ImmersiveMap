// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PortableFoundation
import Testing

/// A work item runs when its time comes unless it was cancelled, and a queue
/// knows its own work, with Dispatch and with the stand-in alike.
struct DispatchWorkItemTests {
    @Test func anItemRunsWhenItsTimeComes() async {
        let queue = DispatchQueue(label: "test.workItem.runs")
        let ran = await withCheckedContinuation { continuation in
            let item = DispatchWorkItem { continuation.resume(returning: true) }
            queue.asyncAfter(deadline: .now() + 0.001, execute: item)
        }
        #expect(ran)
    }

    @Test func aCancelledItemDoesNothing() async {
        let queue = DispatchQueue(label: "test.workItem.cancelled")
        let flag = Flag()
        let cancelled = DispatchWorkItem { flag.set() }
        cancelled.cancel()
        #expect(cancelled.isCancelled)
        cancelled.perform()
        let ranLater = await withCheckedContinuation { continuation in
            queue.asyncAfter(deadline: .now(), execute: cancelled)
            queue.asyncAfter(deadline: .now() + 0.02) { continuation.resume(returning: flag.isSet) }
        }
        #expect(ranLater == false)
    }

    @Test func aQueueKnowsItsOwnWork() {
        let queue = DispatchQueue(label: "test.precondition")
        let other = DispatchQueue(label: "test.precondition.other")
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {
            dispatchPrecondition(condition: .onQueue(queue))
            dispatchPrecondition(condition: .notOnQueue(other))
        }
    }
}

private final class Flag: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
