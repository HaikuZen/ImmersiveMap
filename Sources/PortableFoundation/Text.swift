// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// The few text operations the engine took from Foundation that
// FoundationEssentials does not have: trimming white space and writing a
// number with a fixed count of decimals. They are written once here and run
// the same on every platform, Apple's included, so what the tests check on
// one platform is what every platform does. `PortableFoundationParityTests`
// holds them to Foundation's answers where Foundation is there to ask.

#if canImport(Darwin)
import Foundation
#else
import FoundationEssentials
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
#endif

extension Unicode.Scalar {
    /// Whether Foundation's `CharacterSet.whitespaces` holds the scalar (not
    /// `Character.isWhitespace`, which counts the line breaks too): the
    /// space separators, the tab, and the zero width space, which Foundation
    /// has always counted. Listed and not read from the Unicode properties,
    /// so a new Unicode version does not move it away from Foundation's.
    public var isFoundationWhitespace: Bool {
        switch value {
        case 0x09, 0x20, 0xA0, 0x1680, 0x2000...0x200B, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    /// Whether Foundation's `CharacterSet.newlines` holds the scalar.
    public var isFoundationNewline: Bool {
        switch value {
        case 0x0A...0x0D, 0x85, 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }

    /// Whether Foundation's `CharacterSet.whitespacesAndNewlines` holds the
    /// scalar.
    public var isFoundationWhitespaceOrNewline: Bool {
        isFoundationWhitespace || isFoundationNewline
    }
}

extension StringProtocol {
    /// The text without the white space at either end, as Foundation's
    /// `trimmingCharacters(in: .whitespaces)`: line breaks stay.
    public func trimmingWhitespace() -> String {
        trimmingScalars { $0.isFoundationWhitespace }
    }

    /// The text without the white space and the line breaks at either end,
    /// as Foundation's `trimmingCharacters(in: .whitespacesAndNewlines)`.
    public func trimmingWhitespaceAndNewlines() -> String {
        trimmingScalars { $0.isFoundationWhitespaceOrNewline }
    }

    /// Scalar by scalar, as Foundation trims: a combining mark left after a
    /// trimmed space stays, on its own.
    private func trimmingScalars(where isTrimmed: (Unicode.Scalar) -> Bool) -> String {
        let scalars = unicodeScalars
        guard let first = scalars.firstIndex(where: { !isTrimmed($0) }),
              let last = scalars.lastIndex(where: { !isTrimmed($0) }) else {
            return ""
        }
        return String(String.UnicodeScalarView(scalars[first...last]))
    }
}

extension String {
    /// The number with `fractionDigits` decimals, rounded as the C library's
    /// `%.Nf` rounds, which is what `String(format: "%.2f", value)` writes.
    public init(fixed value: Double, fractionDigits: Int) {
        let digits = Int32(Swift.max(0, Swift.min(fractionDigits, 30)))
        // 400 holds the integer part of the largest double and the decimals.
        var buffer = [CChar](repeating: 0, count: 400)
        let written = withVaList([digits, value]) { arguments in
            buffer.withUnsafeMutableBufferPointer { pointer in
                vsnprintf(pointer.baseAddress, pointer.count, "%.*f", arguments)
            }
        }
        precondition(written >= 0 && Int(written) < buffer.count, "a number did not fit its buffer")
        self = String(decoding: buffer[..<Int(written)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The same for any floating-point number, written as the `Double` it
    /// widens to, as `String(format:)` widens a `Float`.
    public init<Value: BinaryFloatingPoint>(fixed value: Value, fractionDigits: Int) {
        self.init(fixed: Double(value), fractionDigits: fractionDigits)
    }
}

extension Date {
    /// The moment in UTC as `20241111-110000-988`: the date, the time and
    /// the milliseconds, rounded to the nearest, which is what a
    /// `DateFormatter` with the format `yyyyMMdd-HHmmss-SSS` writes. Made
    /// for file names, which sort by it.
    public var compactUTCTimestamp: String {
        let milliseconds = (timeIntervalSince1970 * 1000).rounded()
        let rounded = Date(timeIntervalSince1970: milliseconds / 1000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: rounded)
        let millisecond = Int(milliseconds.truncatingRemainder(dividingBy: 1000) + 1000) % 1000
        func padded(_ value: Int?, _ width: Int) -> String {
            let text = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return padded(parts.year, 4) + padded(parts.month, 2) + padded(parts.day, 2)
            + "-" + padded(parts.hour, 2) + padded(parts.minute, 2) + padded(parts.second, 2)
            + "-" + padded(millisecond, 3)
    }
}
