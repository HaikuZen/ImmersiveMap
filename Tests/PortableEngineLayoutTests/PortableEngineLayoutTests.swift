// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Testing

/// PortableEngineExclusions.txt, the engine's files the portable package
/// leaves out, against the sources' own imports: a file that imports an
/// Apple framework outside a `canImport` guard is listed, and a listed file
/// does. A shared file that gains such an import fails here, so the list
/// changes in the same change, where a review sees the portable engine
/// shrink, rather than the file leaving the portable build without a word.
struct PortableEngineLayoutTests {
    /// The frameworks only Apple's platforms have, and the Metal backend.
    static let appleOnlyModules: Set<String> = [
        "Accelerate", "AppKit", "AVFoundation", "Compression", "CoreGraphics", "CoreVideo",
        "ImageIO", "ImmersiveMapMetal", "Metal", "MetalKit", "ModelIO", "QuartzCore", "SwiftUI", "UIKit"
    ]

    static let packageDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let engineDirectory = packageDirectory.appendingPathComponent("Sources/ImmersiveMap")

    /// Whether the file imports an Apple-only module outside an `#if`.
    static func importsAppleOnlyModule(_ source: String) -> Bool {
        var conditionDepth = 0
        for line in source.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if") {
                conditionDepth += 1
            } else if trimmed.hasPrefix("#endif") {
                conditionDepth -= 1
            } else if conditionDepth == 0 {
                let words = trimmed.split(separator: " ").drop { $0.hasPrefix("@") }
                if words.first == "import", let module = words.dropFirst().first, appleOnlyModules.contains(String(module)) {
                    return true
                }
            }
        }
        return false
    }

    /// The folders left out whole, whatever their files import: `UI`, the
    /// host of each Apple platform, and `Avatars`, whose public API takes
    /// Core Graphics images and draws its badges with Core Graphics, until
    /// the avatars have an image type of the engine's own.
    static let appleOnlyFolders: Set<String> = ["UI", "Avatars"]
    /// The files of those folders that build everywhere all the same, plain
    /// values the portable engine carries.
    static let portableInAppleOnlyFolders: Set<String> = ["Avatars/Selection/AvatarSelectionSnapshot.swift"]

    /// What the rule in PortableEngineExclusions.txt names today.
    static func expectedExclusions() throws -> Set<String> {
        var paths = appleOnlyFolders.subtracting(["Avatars"])
        let base = engineDirectory.path + "/"
        let enumerator = try #require(FileManager.default.enumerator(atPath: engineDirectory.path))
        while let relative = enumerator.nextObject() as? String {
            if relative == "UI" || relative.hasPrefix("UI/") {
                continue
            }
            if relative.hasPrefix("Avatars/") {
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: base + relative, isDirectory: &isDirectory)
                if isDirectory.boolValue == false, Self.portableInAppleOnlyFolders.contains(relative) == false {
                    paths.insert(relative)
                }
                continue
            }
            let name = (relative as NSString).lastPathComponent
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: base + relative, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                let holdsSwift = (FileManager.default.subpaths(atPath: base + relative) ?? []).contains { $0.hasSuffix(".swift") }
                if name == "Shaders" || (name == "Resources" && holdsSwift == false) {
                    paths.insert(relative)
                    enumerator.skipDescendants()
                }
                continue
            }
            if relative.hasSuffix(".swift"),
               let source = try? String(contentsOfFile: base + relative, encoding: .utf8),
               importsAppleOnlyModule(source) {
                paths.insert(relative)
            }
        }
        return paths
    }

    static func listedExclusions() throws -> Set<String> {
        let text = try String(contentsOf: packageDirectory.appendingPathComponent("PortableEngineExclusions.txt"),
                              encoding: .utf8)
        return Set(text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false && $0.hasPrefix("#") == false })
    }

    @Test func theListIsWhatTheSourcesImport() throws {
        let expected = try Self.expectedExclusions()
        let listed = try Self.listedExclusions()
        #expect(expected.subtracting(listed).sorted() == [],
                "Apple-only now, so left out of the portable engine: list them, or drop the import")
        #expect(listed.subtracting(expected).sorted() == [],
                "Listed but portable now: take them off the list, so the portable engine builds them")
    }

    @Test func theRuleSeesGuardedAndAttributedImports() {
        #expect(Self.importsAppleOnlyModule("import Metal\n"))
        #expect(Self.importsAppleOnlyModule("@preconcurrency import QuartzCore\n"))
        #expect(Self.importsAppleOnlyModule("#if canImport(UIKit)\nimport UIKit\n#endif\n") == false)
        #expect(Self.importsAppleOnlyModule("import PortableFoundation\nimport simd\n") == false)
    }
}
