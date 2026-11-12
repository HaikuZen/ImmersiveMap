// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// A folder of resources, for the platforms without Foundation's `Bundle`
// (FoundationEssentials has none): the engine's resources are files in one
// folder, looked up by name and extension as a bundle looks them up.

#if canImport(Darwin)
import Foundation
#else
import FoundationEssentials
#endif

/// A folder that holds resources side by side, as SwiftPM lays out a
/// target's resources outside Apple's platforms (`<Package>_<Target>.resources`,
/// beside the program).
public struct ResourceDirectory: Equatable, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The resource's file (`atlas.json` for `"atlas"`, `"json"`), nil when
    /// the folder has none. A folder of that name counts, as a bundle counts
    /// one.
    public func url(forResource name: String, withExtension ext: String?) -> URL? {
        let fileName = ext.map { $0.isEmpty ? name : "\(name).\($0)" } ?? name
        let candidate = url.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// The folder the environment variable names, when it names one, and
    /// otherwise the folder of the given name beside the program. Nil when
    /// neither is there.
    public static func locate(environmentVariable: String,
                              folderName: String,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              programPath: String? = CommandLine.arguments.first) -> ResourceDirectory? {
        if let named = environment[environmentVariable], named.isEmpty == false {
            let directory = URL(fileURLWithPath: named, isDirectory: true)
            return isDirectory(directory) ? ResourceDirectory(url: directory) : nil
        }
        guard let programPath, programPath.isEmpty == false else {
            return nil
        }
        let besideProgram = URL(fileURLWithPath: programPath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent(folderName, isDirectory: true)
        return isDirectory(besideProgram) ? ResourceDirectory(url: besideProgram) : nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
    }
}
