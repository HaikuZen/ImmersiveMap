// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PortableFoundation

/// Where the engine's resources are read from (`ImmersiveMapResourceBundle`):
/// its bundle on Apple's platforms, a folder of the same files elsewhere.
/// Either one answers a resource's file by its name and extension.
enum ImmersiveMapResourceLocation: Sendable {
    #if canImport(Darwin)
    case bundle(Bundle)
    #endif
    case directory(ResourceDirectory)

    /// The resource's file, nil when the location has none.
    func url(forResource name: String, withExtension ext: String?) -> URL? {
        switch self {
        #if canImport(Darwin)
        case let .bundle(bundle):
            return bundle.url(forResource: name, withExtension: ext)
        #endif
        case let .directory(directory):
            return directory.url(forResource: name, withExtension: ext)
        }
    }
}
