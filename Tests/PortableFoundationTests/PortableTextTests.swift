// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PortableFoundation
import Testing

/// The text, JSON, file and script helpers of `PortableFoundation` by known
/// answers, in every build, the slim one included. Their agreement with
/// Foundation is `PortableFoundationParityTests`.
struct PortableTextTests {
    @Test func trimmingTakesTheWhiteSpaceAtEitherEndOnly() {
        #expect(" \t a b \u{3000}".trimmingWhitespace() == "a b")
        #expect("\n a \n".trimmingWhitespace() == "\n a \n")
        #expect("\n a \r\n".trimmingWhitespaceAndNewlines() == "a")
        #expect("   ".trimmingWhitespace() == "")
        #expect("".trimmingWhitespaceAndNewlines() == "")
        #expect("x".trimmingWhitespace() == "x")
        #expect("\u{200B}x\u{A0}".trimmingWhitespace() == "x")
        #expect("a\u{2028}".trimmingWhitespaceAndNewlines() == "a")
        // A combining mark after a trimmed space stays, on its own.
        #expect(" \u{301}".trimmingWhitespace().unicodeScalars.map(\.value) == [0x301])
        #expect(Substring(" sub ").trimmingWhitespace() == "sub")
    }

    @Test func fixedDecimalsRoundAsTheCLibrary() {
        #expect(String(fixed: 1.5, fractionDigits: 2) == "1.50")
        #expect(String(fixed: 2.5, fractionDigits: 0) == "2")
        #expect(String(fixed: 3.5, fractionDigits: 0) == "4")
        #expect(String(fixed: 0.125, fractionDigits: 2) == "0.12")
        #expect(String(fixed: -0.004, fractionDigits: 2) == "-0.00")
        #expect(String(fixed: 1_048_575.95, fractionDigits: 1) == "1048575.9")
        #expect(String(fixed: Float(0.25), fractionDigits: 3) == "0.250")
        #expect(String(fixed: 1e20, fractionDigits: 0) == "100000000000000000000")
        #expect(String(fixed: .infinity, fractionDigits: 2) == "inf")
    }

    @Test func theTimestampIsUTCToTheNearestMillisecond() {
        #expect(Date(timeIntervalSince1970: 1_731_322_800.987_654).compactUTCTimestamp == "20241111-110000-988")
        #expect(Date(timeIntervalSince1970: 1_731_322_800.999_9).compactUTCTimestamp == "20241111-110001-000")
        #expect(Date(timeIntervalSince1970: 0).compactUTCTimestamp == "19700101-000000-000")
    }

    @Test func jsonIsReadIntoValues() throws {
        let document = try JSONValue(parsing: Data(#"{"a": [1, 2.5, true, null, "x"], "b": {"c": -3e2}}"#.utf8))
        #expect(document["a"] == [1, 2.5, true, nil, "x"])
        #expect(document["b"]?["c"]?.doubleValue == -300)
        #expect(document["a"]?.arrayValue?[2].doubleValue == nil)
        #expect(document["missing"] == nil)
        #expect(try JSONValue(parsing: Data("42".utf8)) == 42)
        #expect(try JSONValue(parsing: Data(#""text""#.utf8)) == "text")
        #expect(throws: (any Error).self) { try JSONValue(parsing: Data("{nope".utf8)) }
        #expect(throws: (any Error).self) { try JSONValue(parsing: Data()) }
    }

    @Test func jsonIsWrittenWithIntegersAsIntegers() throws {
        let value: JSONValue = ["frame": 2, "pitch": 75.0, "zoom": 11.5, "on": true, "url": "http://x/y", "none": nil]
        let text = String(decoding: try value.serialized(sortedKeys: true), as: UTF8.self)
        #expect(text == #"{"frame":2,"none":null,"on":true,"pitch":75,"url":"http:\/\/x\/y","zoom":11.5}"#)
        #expect(try JSONValue(parsing: value.serialized()) == value)
        #expect(throws: (any Error).self) { try JSONValue.number(.nan).serialized() }
    }

    @Test func aFileIsWrittenFromItsStart() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectoryPath(), isDirectory: true)
            .appendingPathComponent("PortableTextTests-\(UInt64.random(in: 0...UInt64.max))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("log.jsonl")
        try Data("old contents".utf8).write(to: url)

        let file = try AppendOnlyFile(truncating: url)
        file.write(Data("one\n".utf8))
        file.write(Data("two\n".utf8))
        file.synchronize()
        #expect(try Data(contentsOf: url) == Data("one\ntwo\n".utf8))
        file.close()
        file.write(Data("ignored".utf8))
        #expect(try Data(contentsOf: url) == Data("one\ntwo\n".utf8))
        #expect(throws: AppendOnlyFile.OpenError.self) {
            try AppendOnlyFile(truncating: directory.appendingPathComponent("no/such/dir/file"))
        }
    }

    @Test func regularFilesAreListedWithTheirSizes() throws {
        let fileManager = FileManager.default
        let directory = URL(fileURLWithPath: NSTemporaryDirectoryPath(), isDirectory: true)
            .appendingPathComponent("PortableTextTests-\(UInt64.random(in: 0...UInt64.max))", isDirectory: true)
        try fileManager.createDirectory(at: directory.appendingPathComponent("sub/deeper"), withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        try Data(count: 3).write(to: directory.appendingPathComponent("a"))
        try Data(count: 5).write(to: directory.appendingPathComponent(".hidden"))
        try Data(count: 7).write(to: directory.appendingPathComponent("sub/deeper/b"))

        let flat = fileManager.regularFiles(in: directory, recursive: false)
        #expect(Set(flat.map(\.url.lastPathComponent)) == ["a", ".hidden"])
        let all = fileManager.regularFiles(in: directory, recursive: true)
        #expect(Dictionary(uniqueKeysWithValues: all.map { ($0.url.lastPathComponent, $0.byteCount) })
                    == ["a": 3, ".hidden": 5, "b": 7])
        #expect(all.allSatisfy { $0.modificationDate != nil })
        #expect(fileManager.regularFiles(in: directory.appendingPathComponent("absent"), recursive: true).isEmpty)
    }

    @Test func theLikelyScriptOfALanguage() {
        #expect(LikelyScript.of(languageIdentifier: "en") == "Latn")
        #expect(LikelyScript.of(languageIdentifier: "pt-BR") == "Latn")
        #expect(LikelyScript.of(languageIdentifier: "ru") == "Cyrl")
        #expect(LikelyScript.of(languageIdentifier: "el") == "Grek")
        #expect(LikelyScript.of(languageIdentifier: "hy") == "Armn")
        #expect(LikelyScript.of(languageIdentifier: "ka") == "Geor")
        #expect(LikelyScript.of(languageIdentifier: "sr") == "Cyrl")
        #expect(LikelyScript.of(languageIdentifier: "sr-ME") == "Latn")
        #expect(LikelyScript.of(languageIdentifier: "sr-Latn") == "Latn")
        #expect(LikelyScript.of(languageIdentifier: "sr_latn_rs") == "Latn")
        #expect(LikelyScript.of(languageIdentifier: "az-IR") == nil)
        #expect(LikelyScript.of(languageIdentifier: "ja") == nil)
        #expect(LikelyScript.of(languageIdentifier: "zh-Hant") == nil)
        #expect(LikelyScript.of(languageIdentifier: "") == nil)
    }
}

/// The system's directory for temporary files, as a path.
private func NSTemporaryDirectoryPath() -> String {
    FileManager.default.temporaryDirectory.path
}
