// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The engine's WGSL sources as the tests read them, by the rules
/// `Tools/WGSLCheck/wgsl.mjs` writes them by: a `// ported-from: <path>
/// fnv1a64=<hex>` line names the Metal source a file is the twin of, and
/// the structs are laid out by WGSL's rules for the uniform address space.
enum WGSLSources {
    static let engineSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ImmersiveMap")

    /// Every .wgsl file under the engine's sources, by path.
    static func files() throws -> [URL] {
        let fileManager = FileManager.default
        var found: [URL] = []
        func walk(_ directory: URL) throws {
            for name in try fileManager.contentsOfDirectory(atPath: directory.path).sorted() {
                let url = directory.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    try walk(url)
                } else if name.hasSuffix(".wgsl") {
                    found.append(url)
                }
            }
        }
        try walk(engineSources)
        return found
    }

    struct Stamp: Equatable {
        /// The Metal source, relative to the WGSL file.
        let path: String
        let hash: String
    }

    static func stamps(in text: String) -> [Stamp] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let prefix = "// ported-from: "
            guard line.hasPrefix(prefix) else { return nil }
            let parts = line.dropFirst(prefix.count).split(separator: " ")
            guard parts.count == 2, parts[1].hasPrefix("fnv1a64=") else { return nil }
            return Stamp(path: String(parts[0]), hash: String(parts[1].dropFirst("fnv1a64=".count)))
        }
    }

    /// FNV-1a, 64 bits, as 16 hex digits: `wgsl.mjs`'s `fnv1a64`.
    static func fnv1a64(_ bytes: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    // MARK: - Struct layout

    struct Member: Equatable {
        let name: String
        let offset: Int
        let size: Int
    }

    struct Layout: Equatable {
        let members: [Member]
        let alignment: Int
        let size: Int
    }

    /// The structs of `text`, laid out by WGSL's rules for a uniform
    /// buffer: each member at the next multiple of its alignment, sized by
    /// its type or its `@size`, the struct's size a multiple of its widest
    /// alignment. A type the rules here do not know stops the test.
    static func layouts(in text: String) throws -> [String: Layout] {
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined(separator: "\n")
        var layouts: [String: Layout] = [:]
        var rest = Substring(code)
        while let structRange = rest.range(of: "struct ") {
            let afterKeyword = rest[structRange.upperBound...]
            guard let open = afterKeyword.firstIndex(of: "{"), let close = afterKeyword.firstIndex(of: "}") else { break }
            let name = afterKeyword[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            let body = afterKeyword[afterKeyword.index(after: open) ..< close]
            layouts[name] = try layout(of: body, known: layouts)
            rest = afterKeyword[afterKeyword.index(after: close)...]
        }
        return layouts
    }

    struct UnknownType: Error, CustomStringConvertible {
        let type: String
        var description: String { "No WGSL layout for type \(type)" }
    }

    private static func layout(of body: Substring, known: [String: Layout]) throws -> Layout {
        var members: [Member] = []
        var offset = 0
        var alignment = 1
        for declaration in body.split(separator: ",") {
            var tokens = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
            guard tokens.isEmpty == false else { continue }
            var explicitSize: Int?
            var explicitAlign: Int?
            while tokens.hasPrefix("@") {
                let end = tokens.firstIndex(of: ")").map { tokens.index(after: $0) } ?? tokens.endIndex
                let attribute = String(tokens[..<end])
                tokens = tokens[end...].trimmingCharacters(in: .whitespaces)
                if let value = argument(of: "@size", in: attribute) { explicitSize = value }
                if let value = argument(of: "@align", in: attribute) { explicitAlign = value }
            }
            let parts = tokens.split(separator: ":").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2 else { continue }
            let (typeAlign, typeSize) = try sizeAndAlignment(of: parts[1], known: known)
            let memberAlign = explicitAlign ?? typeAlign
            offset = roundUp(offset, to: memberAlign)
            let size = explicitSize ?? typeSize
            members.append(Member(name: parts[0], offset: offset, size: size))
            offset += size
            alignment = max(alignment, memberAlign)
        }
        return Layout(members: members, alignment: alignment, size: roundUp(offset, to: alignment))
    }

    private static func argument(of name: String, in attribute: String) -> Int? {
        guard attribute.hasPrefix(name + "("), attribute.hasSuffix(")") else { return nil }
        return Int(attribute.dropFirst(name.count + 1).dropLast())
    }

    private static func sizeAndAlignment(of type: String, known: [String: Layout]) throws -> (alignment: Int, size: Int) {
        switch type {
        case "f32", "i32", "u32": return (4, 4)
        case "vec2f", "vec2i", "vec2u": return (8, 8)
        case "vec3f", "vec3i", "vec3u": return (16, 12)
        case "vec4f", "vec4i", "vec4u": return (16, 16)
        case "mat4x4f": return (16, 64)
        case "mat3x3f": return (16, 48)
        default:
            guard let layout = known[type] else { throw UnknownType(type: type) }
            return (roundUp(layout.alignment, to: 16), roundUp(layout.size, to: 16))
        }
    }

    private static func roundUp(_ value: Int, to multiple: Int) -> Int {
        (value + multiple - 1) / multiple * multiple
    }
}
