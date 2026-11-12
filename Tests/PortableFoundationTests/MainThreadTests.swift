// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PortableFoundation
import Testing

/// The main thread is told apart from the others on every platform.
struct MainThreadTests {
    @MainActor
    @Test func theMainActorRunsOnTheMainThread() {
        #expect(isOnMainThread)
    }

    #if canImport(Dispatch)
    @Test func aBackgroundQueueIsNotTheMainThread() async {
        let onMain = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: isOnMainThread) }
        }
        #expect(onMain == false)
    }
    #endif
}
