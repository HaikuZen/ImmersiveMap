// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// Foundation's `NSLock` for a slim build (see PortableFoundation.swift),
// which has FoundationEssentials alone, and FoundationEssentials has no lock.
// Every other build takes the platform's Foundation's.
//
// Only what the engine uses: `lock`, `unlock` and `withLock`. Not
// recursive, as Foundation's is not: a thread that takes it twice waits for
// itself.

#if !canImport(Darwin) && PORTABLE_FOUNDATION_OWN_GEOMETRY

// Asked of the runtime and not of the platform: a WebAssembly build with
// threads is not one thread, and takes the real lock below.
#if !_runtime(_multithreaded)

/// A runtime with one thread (WebAssembly as this package builds it): nothing
/// can be inside the lock when it is taken, and there is nothing to do. The
/// platform's Foundation does the same there.
public final class NSLock: Sendable {
    public init() {}

    public func lock() {}

    public func unlock() {}
}

#else

public final class NSLock: @unchecked Sendable {
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>

    public init() {
        mutex = .allocate(capacity: 1)
        mutex.initialize(to: pthread_mutex_t())
        let status = pthread_mutex_init(mutex, nil)
        precondition(status == 0, "pthread_mutex_init failed")
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deinitialize(count: 1)
        mutex.deallocate()
    }

    public func lock() {
        pthread_mutex_lock(mutex)
    }

    public func unlock() {
        pthread_mutex_unlock(mutex)
    }
}

#endif

extension NSLock {
    /// Runs `body` with the lock held, and lets it go however `body` ends.
    public func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}

#endif
