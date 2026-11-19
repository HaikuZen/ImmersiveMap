// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
@testable import ImmersiveMap

/// A file of the engine's resources for a test: through the lookup the
/// engine reads its own by (`ImmersiveMapResourceBundle.location()`), and
/// where that finds no resources folder (the portable package has none of
/// its own, off Apple's platforms) from the source tree, which the tests'
/// runner is given.
enum TestResources {
    private static let engineSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ImmersiveMap")
    /// The source folders the engine's resources are in.
    private static let resourceFolders = ["Text/Resources", "Pins/Resources"]

    static func url(_ name: String, _ fileExtension: String) -> URL? {
        if let url = (try? ImmersiveMapResourceBundle.location())?.url(forResource: name, withExtension: fileExtension) {
            return url
        }
        for folder in resourceFolders {
            let url = engineSources.appendingPathComponent(folder).appendingPathComponent("\(name).\(fileExtension)")
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}
