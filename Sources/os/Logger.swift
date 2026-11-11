// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// A stand-in for Apple's `os` module on the platforms that have none, as
// `Sources/simd` is for `simd`: Package.swift declares it only there, under
// the same name, so the sources that write `import os` compile unchanged.
//
// It holds what the engine uses: the logger, the signposter and the unfair
// lock. The logger writes to the standard error stream, which is the terminal
// of a program and the console of a browser. The signposter does nothing:
// signposts are read in Instruments, and there is none here.

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#elseif canImport(Android)
import Android
#elseif canImport(ucrt)
import ucrt
#endif

/// Whether a value may be read in a log. Apple's logger hides what is not
/// public from a log read off the device. This one writes to the program's
/// own error stream and writes every value.
public struct OSLogPrivacy: Sendable {
    public static let `public` = OSLogPrivacy()
    public static let `private` = OSLogPrivacy()
    public static let sensitive = OSLogPrivacy()
    public static let auto = OSLogPrivacy()
}

/// The text of one log line, written as a string literal with values
/// interpolated: `"tile \(z, privacy: .public) failed"`.
public struct OSLogMessage: ExpressibleByStringInterpolation, Sendable {
    public struct StringInterpolation: StringInterpolationProtocol, Sendable {
        @usableFromInline var text = ""

        public init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity + interpolationCount * 8)
        }

        public mutating func appendLiteral(_ literal: String) {
            text += literal
        }

        public mutating func appendInterpolation<T>(_ value: T, privacy: OSLogPrivacy = .auto) {
            text += String(describing: value)
        }
    }

    @usableFromInline let text: String

    public init(stringLiteral value: String) {
        text = value
    }

    public init(stringInterpolation: StringInterpolation) {
        text = stringInterpolation.text
    }
}

public struct OSLogType: Equatable, Sendable {
    @usableFromInline let rank: UInt8

    public static let debug = OSLogType(rank: 0)
    public static let info = OSLogType(rank: 1)
    public static let `default` = OSLogType(rank: 2)
    public static let error = OSLogType(rank: 3)
    public static let fault = OSLogType(rank: 4)
}

/// Writes log lines to the standard error stream, each with the subsystem
/// and category it was made for. The debug and info levels are not written:
/// Apple's logger keeps them in memory only, for a debugger that asks.
public struct Logger: Sendable {
    @usableFromInline let prefix: String

    public init() {
        prefix = ""
    }

    public init(subsystem: String, category: String) {
        prefix = "[\(subsystem):\(category)] "
    }

    public func log(level: OSLogType = .default, _ message: OSLogMessage) {
        guard level.rank >= OSLogType.default.rank else {
            return
        }
        // By its descriptor and not through `stderr`, a C global the
        // compiler cannot see as safe to share. One write per line, so lines
        // from two threads do not run into each other.
        var line = prefix + message.text + "\n"
        line.withUTF8 { bytes in
            _ = write(2, bytes.baseAddress, bytes.count)
        }
    }

    public func trace(_ message: OSLogMessage) { log(level: .debug, message) }
    public func debug(_ message: OSLogMessage) { log(level: .debug, message) }
    public func info(_ message: OSLogMessage) { log(level: .info, message) }
    public func notice(_ message: OSLogMessage) { log(level: .default, message) }
    public func warning(_ message: OSLogMessage) { log(level: .error, message) }
    public func error(_ message: OSLogMessage) { log(level: .error, message) }
    public func critical(_ message: OSLogMessage) { log(level: .fault, message) }
    public func fault(_ message: OSLogMessage) { log(level: .fault, message) }
}

public struct OSSignpostID: Equatable, Sendable {
    public static let exclusive = OSSignpostID()
    public static let invalid = OSSignpostID()
}

/// What `beginInterval` hands back for `endInterval`. Nothing is kept in it.
public final class OSSignpostIntervalState: Sendable {
    @usableFromInline static let shared = OSSignpostIntervalState()
}

/// Marks intervals for Instruments on Apple's platforms. Here every call
/// returns at once and records nothing.
public struct OSSignposter: Sendable {
    public init() {}

    public init(subsystem: String, category: String) {}

    @inlinable
    public func makeSignpostID() -> OSSignpostID { .exclusive }

    @inlinable
    public func beginInterval(_ name: StaticString, id: OSSignpostID = .exclusive) -> OSSignpostIntervalState {
        .shared
    }

    /// The message is an autoclosure so that nothing is formatted for a
    /// signpost nobody reads.
    @inlinable
    public func beginInterval(_ name: StaticString,
                              id: OSSignpostID = .exclusive,
                              _ message: @autoclosure () -> OSLogMessage) -> OSSignpostIntervalState {
        .shared
    }

    @inlinable
    public func endInterval(_ name: StaticString, _ state: OSSignpostIntervalState) {}

    @inlinable
    public func endInterval(_ name: StaticString,
                            _ state: OSSignpostIntervalState,
                            _ message: @autoclosure () -> OSLogMessage) {}

    @inlinable
    public func emitEvent(_ name: StaticString, id: OSSignpostID = .exclusive) {}

    @inlinable
    public func emitEvent(_ name: StaticString,
                          id: OSSignpostID = .exclusive,
                          _ message: @autoclosure () -> OSLogMessage) {}
}
