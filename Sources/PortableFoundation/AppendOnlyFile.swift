// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// A file written from its start, line after line, in place of Foundation's
// `FileHandle`, which FoundationEssentials does not have. Over the C
// library's buffered streams, the same on every platform.

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
#elseif canImport(ucrt)
import ucrt
#endif
#endif

// The C library's stream is a pointer to a `FILE` where the struct is
// declared, and an opaque pointer where it is not (WASI's, Musl's).
#if canImport(WASILibc) || canImport(Musl)
private typealias CStream = OpaquePointer
#else
private typealias CStream = UnsafeMutablePointer<FILE>
#endif

/// A file opened empty for writing, to which every write is added at the
/// end. Not safe to share between threads: the caller keeps it on one queue.
public final class AppendOnlyFile: @unchecked Sendable {
    public struct OpenError: Error, Equatable {
        public let path: String
    }

    private var stream: CStream?

    /// Opens the file at `url` empty, creating it when it is not there.
    public init(truncating url: URL) throws {
        let path = url.path
        guard let stream = fopen(path, "w") else {
            throw OpenError(path: path)
        }
        self.stream = stream
    }

    deinit {
        close()
    }

    /// Adds the bytes at the end. Does nothing once the file is closed.
    public func write(_ data: Data) {
        guard let stream, data.isEmpty == false else { return }
        data.withUnsafeBytes { bytes in
            _ = fwrite(bytes.baseAddress, 1, bytes.count, stream)
        }
    }

    /// Hands what was written to the system, so a reader of the file sees it.
    public func synchronize() {
        guard let stream else { return }
        fflush(stream)
    }

    public func close() {
        guard let stream else { return }
        fclose(stream)
        self.stream = nil
    }
}
