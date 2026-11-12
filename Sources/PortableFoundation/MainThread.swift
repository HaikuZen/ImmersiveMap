// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(Darwin)
import Foundation
#elseif canImport(Dispatch)
import Dispatch

/// Marks the main queue, so a caller can tell it runs there
/// (`isOnMainThread`). Set once, from any thread: setting a queue's
/// specific value needs no turn on the queue.
private let mainQueueKey: DispatchSpecificKey<UInt8> = {
    let key = DispatchSpecificKey<UInt8>()
    DispatchQueue.main.setSpecific(key: key, value: 1)
    return key
}()
#endif

/// Whether the caller runs where the main actor does: Foundation's
/// `Thread.isMainThread` on Apple's platforms, where the main queue is the
/// main thread's. FoundationEssentials has no `Thread`, and off Apple's
/// platforms the main queue need not run on the process's first thread
/// (`dispatchMain()` retires it and another drains the queue), so there
/// the question is whether the caller runs on the main queue. A runtime
/// with one thread and no Dispatch (WebAssembly without threads) is always
/// there. Where neither answer is to be had, the caller is told it is not,
/// so it hands its work over rather than run it in the wrong place.
public var isOnMainThread: Bool {
    #if canImport(Darwin)
    return Thread.isMainThread
    #elseif canImport(Dispatch)
    return DispatchQueue.getSpecific(key: mainQueueKey) == 1
    #elseif _runtime(_multithreaded)
    return false
    #else
    return true
    #endif
}
