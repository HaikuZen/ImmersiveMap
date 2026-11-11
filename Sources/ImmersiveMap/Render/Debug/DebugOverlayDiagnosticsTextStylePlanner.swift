// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PortableFoundation

package enum DebugOverlayDiagnosticsTextStyle: Equatable {
    case section(String)
    case key
    case warningValue
}

/// A run of the diagnostics text and its style. The run is counted in
/// UTF-16 code units, as `NSString` and `NSAttributedString` count, so a
/// panel lays the style over its attributed text by `range`.
package struct DebugOverlayDiagnosticsTextStyleRun: Equatable {
    package let location: Int
    package let length: Int
    package let style: DebugOverlayDiagnosticsTextStyle
}

#if canImport(Darwin)
extension DebugOverlayDiagnosticsTextStyleRun {
    package init(range: NSRange, style: DebugOverlayDiagnosticsTextStyle) {
        self.init(location: range.location, length: range.length, style: style)
    }

    package var range: NSRange {
        NSRange(location: location, length: length)
    }
}
#endif

package enum DebugOverlayDiagnosticsTextStylePlanner {
    package static func makeRuns(for text: String) -> [DebugOverlayDiagnosticsTextStyleRun] {
        let lines = text.components(separatedBy: "\n")
        var runs: [DebugOverlayDiagnosticsTextStyleRun] = []
        var activeSection: String?
        var location = 0

        for line in lines {
            let lineLength = line.utf16.count
            defer {
                location += lineLength + 1
            }

            guard line.isEmpty == false else {
                activeSection = nil
                continue
            }

            if let section = sectionTitle(from: line) {
                activeSection = section
                runs.append(DebugOverlayDiagnosticsTextStyleRun(
                    location: location,
                    length: lineLength,
                    style: .section(section)
                ))
                continue
            }

            if activeSection == "Skip", line != "none" {
                runs.append(DebugOverlayDiagnosticsTextStyleRun(
                    location: location,
                    length: lineLength,
                    style: .warningValue
                ))
            }

            appendKeyRuns(line: line, lineLocation: location, into: &runs)
        }

        return runs
    }

    private static func sectionTitle(from line: String) -> String? {
        guard line.first == "[", line.last == "]", line.count > 2 else {
            return nil
        }
        return String(line.dropFirst().dropLast())
    }

    /// A key is an ASCII letter, then letters and digits, then a colon,
    /// standing at the start of the line or after a space: what the pattern
    /// `(^| )([A-Za-z][A-Za-z0-9]*:)` finds, the run being the key and its
    /// colon.
    private static func appendKeyRuns(line: String,
                                      lineLocation: Int,
                                      into runs: inout [DebugOverlayDiagnosticsTextStyleRun]) {
        let units = Array(line.utf16)
        func isLetter(_ unit: UInt16) -> Bool {
            (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
        }
        func isDigit(_ unit: UInt16) -> Bool {
            (0x30...0x39).contains(unit)
        }
        var start = 0
        while start < units.count {
            guard start == 0 || units[start - 1] == 0x20, isLetter(units[start]) else {
                start += 1
                continue
            }
            var end = start + 1
            while end < units.count, isLetter(units[end]) || isDigit(units[end]) {
                end += 1
            }
            guard end < units.count, units[end] == 0x3A else {
                start = end
                continue
            }
            runs.append(DebugOverlayDiagnosticsTextStyleRun(
                location: lineLocation + start,
                length: end + 1 - start,
                style: .key
            ))
            start = end + 1
        }
    }
}
