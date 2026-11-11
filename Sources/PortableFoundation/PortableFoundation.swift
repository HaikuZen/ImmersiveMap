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
/// The one use the portable targets make of a dispatch queue, on a platform
/// that has no Dispatch (WebAssembly): a serial queue as a lock around a
/// state, `sync` alone. It is a real lock, the standard library's, so it
/// holds if such a platform is ever built with threads, and costs next to
/// nothing on one thread. A queue used to run work elsewhere (`async`) has no
/// meaning without Dispatch and is not offered: that code needs the
/// platform's own way.
public final class DispatchQueue: Sendable {
    private let mutex = Mutex<Void>(())

    public init(label: String) {}

    public func sync<T>(execute work: () throws -> T) rethrows -> T {
        nonisolated(unsafe) let work = work
        nonisolated(unsafe) var result: Result<T, any Error>?
        mutex.withLock { _ in
            result = Result { try work() }
        }
        switch result! {
        case .success(let value):
            return value
        case .failure(let error):
            // `work` is the only thing here that throws.
            return try { throw error }()
        }
    }
}
#endif
#endif
