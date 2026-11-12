// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// The one place that decides which Foundation a portable target is built on.
//
// On Apple's platforms that is Foundation, as before. Everywhere else it is
// FoundationEssentials, the part of Foundation without the locale data and
// the networking: the full library makes a WebAssembly binary of 60 MB, and
// a target that only needs `Data` must not carry it. FoundationEssentials
// does not bring the C math functions (`sin`, `atan2` and the rest) the way
// Foundation does, so the platform's C library is exported next to it.
//
// Foundation also brings Dispatch, the Core Graphics geometry types and
// `CFTimeInterval`, and the engine's sources count on them, as they do on
// QuartzCore's `CACurrentMediaTime`, which is given here too. Dispatch is
// exported where the platform has it. The geometry types, and `NSLock` with
// them, are taken from the platform's Foundation, those types alone, which
// is what a test needs:
// XCTest shows a test file the whole of Foundation, so a second `CGPoint`
// would be ambiguous there. Naming Foundation at all links all of it, though,
// 46 MB of a WebAssembly binary measured, so a build that ships to a browser
// is made with IMMERSIVE_MAP_SLIM=1 (see Package.swift), which defines
// PORTABLE_FOUNDATION_OWN_GEOMETRY: then the types are the ones in
// CoreGraphicsTypes.swift and Lock.swift and Foundation is not named anywhere.
//
// A portable target writes `import PortableFoundation` where it used to write
// `import Foundation`. A file that needs something FoundationEssentials does
// not have (`URLSession`, say) imports Foundation itself and is left out of
// the builds that cannot have it.

#if canImport(Darwin)
@_exported import Foundation
#else
@_exported import FoundationEssentials
#if !canImport(Dispatch)
import Synchronization
#endif
#if canImport(Dispatch)
@_exported import Dispatch
#endif
#if canImport(Glibc)
@_exported import Glibc
#elseif canImport(Musl)
@_exported import Musl
#elseif canImport(WASILibc)
@_exported import WASILibc
#elseif canImport(Android)
@_exported import Android
#elseif canImport(ucrt)
@_exported import ucrt
#endif
#if !PORTABLE_FOUNDATION_OWN_GEOMETRY
@_exported import struct Foundation.CGFloat
@_exported import struct Foundation.CGPoint
@_exported import struct Foundation.CGRect
@_exported import struct Foundation.CGSize
@_exported import class Foundation.NSLock
#endif

/// A Core Foundation time interval: seconds, as a `Double`. The platform's
/// Foundation does not have the name outside Apple's platforms.
public typealias CFTimeInterval = Double

/// The time on the clock the engine times its frames and animations by, in
/// seconds: QuartzCore's function, for the platforms without QuartzCore. It
/// only ever goes forward and stands still while the machine sleeps, as
/// Apple's does. It counts from the first call, where Apple's counts from
/// the boot, and starts at one second so that a zero still reads as "never".
/// The engine only compares two readings, so the origin does not matter.
public func CACurrentMediaTime() -> CFTimeInterval {
    let elapsed = mediaTimeOrigin.duration(to: SuspendingClock.now)
    return 1 + Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
}

private let mediaTimeOrigin = SuspendingClock.now

#if !canImport(Dispatch)
/// Dispatch's queue, for a platform that has none (WebAssembly without
/// threads), with what the engine uses of it. `sync` runs the work at once
/// under a lock, the standard library's, so it holds if such a platform is
/// ever built with threads. `async` and `asyncAfter` run the work later, as
/// a task on the runtime's executor, which on a web page is the page's
/// event loop: in order of submission, one at a time, never inside the
/// call that submitted it. Every queue is the one thread's, `main` and
/// `global` included, so work is deferred and never runs side by side.
public final class DispatchQueue: Sendable {
    private let mutex = Mutex<Void>(())
    nonisolated(unsafe) private var specifics: [ObjectIdentifier: Any] = [:]

    public static let main = DispatchQueue(label: "main")
    private static let globalQueue = DispatchQueue(label: "global")

    public init(label: String, qos: DispatchQoS = .unspecified) {}

    public static func global(qos: DispatchQoS.QoSClass = .default) -> DispatchQueue {
        globalQueue
    }

    public func sync<T>(execute work: () throws -> T) rethrows -> T {
        nonisolated(unsafe) let work = work
        nonisolated(unsafe) var result: Result<T, any Error>?
        mutex.withLock { _ in
            result = Result { try Self.running(self) { try work() } }
        }
        switch result! {
        case .success(let value):
            return value
        case .failure(let error):
            // `work` is the only thing here that throws.
            return try { throw error }()
        }
    }

    public func async(execute work: @escaping @Sendable () -> Void) {
        Task { Self.running(self) { work() } }
    }

    public func asyncAfter(deadline: DispatchTime, execute work: @escaping @Sendable () -> Void) {
        let delay = deadline.uptimeNanoseconds &- DispatchTime.now().uptimeNanoseconds
        Task {
            if deadline.uptimeNanoseconds > DispatchTime.now().uptimeNanoseconds {
                try? await Task.sleep(nanoseconds: delay)
            }
            Self.running(self) { work() }
        }
    }

    public func setSpecific<T>(key: DispatchSpecificKey<T>, value: T?) {
        specifics[ObjectIdentifier(key)] = value
    }

    /// The value the queue the caller runs on holds for the key, nil off
    /// every queue.
    public static func getSpecific<T>(key: DispatchSpecificKey<T>) -> T? {
        current?.specifics[ObjectIdentifier(key)] as? T
    }

    /// The queue whose work runs now. One thread, so a plain variable.
    nonisolated(unsafe) private static var current: DispatchQueue?

    private static func running<T>(_ queue: DispatchQueue, _ work: () throws -> T) rethrows -> T {
        let outer = current
        current = queue
        defer { current = outer }
        return try work()
    }
}

/// Dispatch's quality of service: accepted and ignored, there being one
/// thread to run on.
public struct DispatchQoS: Sendable {
    public enum QoSClass: Sendable {
        case background, utility, `default`, userInitiated, userInteractive, unspecified
    }

    public let qosClass: QoSClass

    public static let background = DispatchQoS(qosClass: .background)
    public static let utility = DispatchQoS(qosClass: .utility)
    public static let `default` = DispatchQoS(qosClass: .default)
    public static let userInitiated = DispatchQoS(qosClass: .userInitiated)
    public static let userInteractive = DispatchQoS(qosClass: .userInteractive)
    public static let unspecified = DispatchQoS(qosClass: .unspecified)
}

/// A key for a value a queue holds (`DispatchQueue.setSpecific`).
public final class DispatchSpecificKey<T>: Sendable {
    public init() {}
}

/// A point on the clock that does not stand still while the machine sleeps
/// on Dispatch's platforms, here the runtime's monotonic clock, in
/// nanoseconds from an origin of its own.
public struct DispatchTime: Sendable, Comparable {
    public let uptimeNanoseconds: UInt64

    public init(uptimeNanoseconds: UInt64) {
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    public static func now() -> DispatchTime {
        let elapsed = dispatchTimeOrigin.duration(to: ContinuousClock.now).components
        return DispatchTime(uptimeNanoseconds: UInt64(elapsed.seconds) * 1_000_000_000
            + UInt64(elapsed.attoseconds / 1_000_000_000) + 1)
    }

    public static func + (time: DispatchTime, seconds: Double) -> DispatchTime {
        DispatchTime(uptimeNanoseconds: time.uptimeNanoseconds + UInt64(max(0, seconds) * 1e9))
    }

    public static func < (lhs: DispatchTime, rhs: DispatchTime) -> Bool {
        lhs.uptimeNanoseconds < rhs.uptimeNanoseconds
    }
}

private let dispatchTimeOrigin = ContinuousClock.now
#endif
#endif
