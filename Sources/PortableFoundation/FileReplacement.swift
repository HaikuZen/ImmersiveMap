// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

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
#endif
#endif

extension FileManager {
    /// Puts the file at `source` in the place of the file at `destination`,
    /// or where none is yet, whole: a reader sees the old file or the new
    /// one, and one that opened the old file keeps reading it. In place of
    /// `replaceItemAt`, which FoundationEssentials has not: Foundation's
    /// call where there is a Foundation, the C library's `rename`, which
    /// replaces a file in one step, elsewhere.
    public func replaceFile(at destination: URL, withFileAt source: URL) throws {
        #if canImport(Darwin)
        if fileExists(atPath: destination.path) {
            _ = try replaceItemAt(destination, withItemAt: source)
        } else {
            try moveItem(at: source, to: destination)
        }
        #else
        guard rename(source.path, destination.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: ["errno": errno])
        }
        #endif
    }
}
