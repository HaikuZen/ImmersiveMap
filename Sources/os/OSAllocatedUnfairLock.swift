// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Synchronization

/// The lock of the stand-in (see Logger.swift): a state that is only ever
/// reached inside `withLock`, as Apple's `OSAllocatedUnfairLock`. Over the
/// standard library's `Mutex`, which every platform of the toolchain has.
public struct OSAllocatedUnfairLock<State>: @unchecked Sendable {
    /// The state beside the mutex and not inside it: `Mutex` hands its value
    /// out under rules for values that change threads, which a state that
    /// stays where it is has no use for. Only `withLock` reaches it.
    @usableFromInline
    final class Storage: @unchecked Sendable {
        @usableFromInline let mutex = Mutex<Void>(())
        @usableFromInline var state: State

        @usableFromInline
        init(_ state: State) {
            self.state = state
        }
    }

    @usableFromInline let storage: Storage

    public init(initialState: State) {
        storage = Storage(initialState)
    }

    public init(uncheckedState initialState: State) {
        storage = Storage(initialState)
    }

    /// Runs `body` with the state, alone: no other `withLock` of this lock
    /// runs until it returns.
    public func withLock<R: Sendable>(_ body: @Sendable (inout State) throws -> R) rethrows -> R {
        try withLockUnchecked(body)
    }

    /// The same without the compiler's check that the closure and its result
    /// may cross threads.
    public func withLockUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R {
        let storage = storage
        nonisolated(unsafe) let body = body
        nonisolated(unsafe) var result: Result<R, any Error>?
        storage.mutex.withLock { _ in
            result = Result { try body(&storage.state) }
        }
        switch result! {
        case .success(let value):
            return value
        case .failure(let error):
            // `body` is the only thing here that throws.
            return try { throw error }()
        }
    }
}

extension OSAllocatedUnfairLock where State == Void {
    public init() {
        storage = Storage(())
    }

    public func withLock<R: Sendable>(_ body: @Sendable () throws -> R) rethrows -> R {
        try withLockUnchecked { _ in try body() }
    }
}
