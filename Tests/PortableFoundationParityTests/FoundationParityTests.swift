// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import PortableFoundation
import XCTest

/// `PortableFoundation`'s stand-ins for what the engine took from Foundation
/// held to Foundation's own answers, wherever there is a Foundation with
/// them: Apple's platforms and Linux. A slim build has none and leaves this
/// target out.
final class FoundationParityTests: XCTestCase {
    func testTheWhiteSpaceSetsAreFoundations() {
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            XCTAssertEqual(scalar.isFoundationWhitespace, CharacterSet.whitespaces.contains(scalar),
                           "U+\(String(value, radix: 16))")
            XCTAssertEqual(scalar.isFoundationNewline, CharacterSet.newlines.contains(scalar),
                           "U+\(String(value, radix: 16))")
            XCTAssertEqual(scalar.isFoundationWhitespaceOrNewline, CharacterSet.whitespacesAndNewlines.contains(scalar),
                           "U+\(String(value, radix: 16))")
        }
    }

    func testTrimmingIsFoundations() {
        let samples = ["", " ", "a", " a ", "\t a b \n", "\n\n", " \u{301}", "\u{200B}x\u{3000}", "\r\na\u{2029}",
                       "\u{A0}\u{85}é\u{85}", "  multi  word  "]
        for sample in samples {
            XCTAssertEqual(sample.trimmingWhitespace(), sample.trimmingCharacters(in: .whitespaces), sample.debugDescription)
            XCTAssertEqual(sample.trimmingWhitespaceAndNewlines(),
                           sample.trimmingCharacters(in: .whitespacesAndNewlines), sample.debugDescription)
        }
    }

    func testFixedDecimalsAreStringFormat() {
        var generator = SystemRandomNumberGenerator()
        var values: [Double] = [0, -0.0, 0.5, 1.5, 2.5, 0.125, 0.375, -0.004, 1e15, 123.456, 1048575.95, 1e-7]
        for _ in 0..<2000 {
            values.append(Double.random(in: -1e6...1e6, using: &generator))
        }
        for value in values {
            for digits in 0...3 {
                XCTAssertEqual(String(fixed: value, fractionDigits: digits),
                               String(format: "%.\(digits)f", value), "\(value) to \(digits)")
            }
        }
    }

    func testTheTimestampIsTheDateFormatters() {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        var generator = SystemRandomNumberGenerator()
        var instants: [TimeInterval] = [0, 1_731_322_800.987_654, 1_731_322_800.999_9, 951_782_400.000_4]
        for _ in 0..<2000 {
            instants.append(TimeInterval.random(in: 0...4_000_000_000, using: &generator))
        }
        for instant in instants {
            let date = Date(timeIntervalSince1970: instant)
            XCTAssertEqual(date.compactUTCTimestamp, formatter.string(from: date), "\(instant)")
        }
    }

    func testJSONIsReadAsJSONSerializationReadsIt() throws {
        let documents = [
            ##"{"type": "Feature", "geometry": null, "properties": {"fill": "#f00", "fill-opacity": 0.5}}"##,
            #"[1, -2.5, 1e3, true, false, null, "x", {"k": []}]"#,
            #"{"message": "slow down", "retry": 30}"#,
            "12", #""text""#, "null",
        ]
        for document in documents {
            let data = Data(document.utf8)
            let foundation = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            XCTAssertEqual(try JSONValue(parsing: data), Self.value(of: foundation), document)
        }
        // Bytes one refuses the other refuses too. Both take a trailing comma.
        for doubtful in ["{", "[1,]", "{\"a\": 1,}", "nope", "", "{\"a\" 1}", "[01]", "\"\\x\""] {
            let data = Data(doubtful.utf8)
            let portable = try? JSONValue(parsing: data)
            let foundation = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            XCTAssertEqual(portable, foundation.map(Self.value(of:)), doubtful)
        }
    }

    func testJSONIsWrittenAsJSONSerializationWritesIt() throws {
        let object: [String: Any] = ["t": 1_731_322_800.987_654, "event": "tile_ready", "frame": 2, "pitch": 75.0,
                                     "zoom": 11.5, "on": true, "url": "https://x.dev/a/b?k=v", "text": "é \"q\" \\ \n"]
        let foundation = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let portable = try Self.value(of: object).serialized(sortedKeys: true)
        XCTAssertEqual(String(decoding: portable, as: UTF8.self), String(decoding: foundation, as: UTF8.self))
    }

    func testEveryLikelyScriptIsLocales() {
        let scripts: Set<String> = ["Latn", "Cyrl", "Grek", "Armn", "Geor"]
        let letters = "abcdefghijklmnopqrstuvwxyz".map(String.init)
        var codes: [String] = []
        for a in letters { for b in letters { codes.append(a + b) } }
        for a in letters { for b in letters { for c in letters { codes.append(a + b + c) } } }
        for code in codes {
            let locale = Locale.Language(identifier: code).script?.identifier
            let expected = locale.flatMap { scripts.contains($0) ? $0 : nil }
            let portable = LikelyScript.of(languageIdentifier: code)
            if Self.newerDataCodes[code] == portable, expected == nil {
                // Known to the newer data the table follows, not to this
                // platform's.
                continue
            }
            if code.count == 3, expected == "Latn" {
                // Three letter codes written in Latin are left out of the table.
                XCTAssertNil(portable, code)
            } else {
                XCTAssertEqual(portable, expected, code)
            }
        }
        for identifier in ["sr-ME", "sr-Latn", "sr-Cyrl-ME", "az-IR", "az-RU", "uz-AF", "pa-PK", "mn-CN", "ky-TR",
                           "kk-CN", "pt-BR", "en-US", "zh-Hant-TW", "ha-CM", "ku-LB"] {
            let locale = Locale.Language(identifier: identifier).script?.identifier
            let expected = locale.flatMap { scripts.contains($0) ? $0 : nil }
            XCTAssertEqual(LikelyScript.of(languageIdentifier: identifier), expected, identifier)
        }
    }

    /// The codes the table has from Apple's language data, newer than the
    /// ICU data of Swift 6.4.2 on Linux, which knows no script for them.
    private static let newerDataCodes: [String: String] = ["pi": "Latn", "grc": "Grek", "abq": "Cyrl"]

    /// What `JSONSerialization` read, as a `JSONValue`.
    private static func value(of object: Any) -> JSONValue {
        switch object {
        case is NSNull:
            return .null
        case let number as NSNumber:
            // A boolean comes back as a number object too, told apart by the C
            // type it holds.
            let kind = String(cString: number.objCType)
            if kind == "c" || kind == "B" {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(array.map(value(of:)))
        case let dictionary as [String: Any]:
            return .object(dictionary.mapValues(value(of:)))
        default:
            XCTFail("unexpected \(type(of: object))")
            return .null
        }
    }
}
