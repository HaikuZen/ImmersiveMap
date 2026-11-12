// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(Darwin)
import Foundation
#else
import FoundationEssentials
#endif

extension Data {
    /// Writes the bytes to the file, whole: written beside it and moved over
    /// it, so a reader sees the old file or the new one, never half of one.
    /// WASI has no temporary files to write beside, and there the file is
    /// written in place: a crash in the middle leaves a short file, which
    /// the engine's caches read as a miss and write again.
    public func writeReplacing(to url: URL) throws {
        #if os(WASI)
        try write(to: url)
        #else
        try write(to: url, options: .atomic)
        #endif
    }
}
