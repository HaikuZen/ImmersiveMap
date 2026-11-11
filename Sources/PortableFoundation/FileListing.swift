// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// The regular files of a directory with their sizes and dates, in place of
// Foundation's URL resource values and directory enumerator, which
// FoundationEssentials does not have. One way on every platform.

#if canImport(Darwin)
import Foundation
#else
import FoundationEssentials
#endif

public struct RegularFile: Equatable, Sendable {
    public let url: URL
    public let byteCount: Int64
    /// Nil when the system gives none.
    public let modificationDate: Date?
}

extension FileManager {
    /// The regular files in `directory`, with those of every directory under
    /// it when `recursive`, in no particular order. A symbolic link is not a
    /// regular file and is not followed. Hidden files are listed. A file that
    /// cannot be read is left out, and a directory that cannot be read lists
    /// nothing.
    public func regularFiles(in directory: URL, recursive: Bool) -> [RegularFile] {
        let paths: [String]
        do {
            paths = recursive
                ? try subpathsOfDirectory(atPath: directory.path)
                : try contentsOfDirectory(atPath: directory.path)
        } catch {
            return []
        }
        return paths.compactMap { relativePath in
            let url = directory.appendingPathComponent(relativePath)
            guard let attributes = try? attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else {
                return nil
            }
            return RegularFile(url: url,
                               byteCount: Self.byteCount(fromAttributes: attributes) ?? 0,
                               modificationDate: attributes[.modificationDate] as? Date)
        }
    }

    /// The size the attributes of an item give, whichever integer type the
    /// platform's Foundation gives it as (a number object on Apple's, an
    /// unsigned integer elsewhere). Nil when there is none.
    public static func byteCount(fromAttributes attributes: [FileAttributeKey: Any]?) -> Int64? {
        guard let value = attributes?[.size] else { return nil }
        if let size = value as? Int64 { return size }
        if let size = value as? Int { return Int64(size) }
        if let size = value as? UInt64 { return Int64(clamping: size) }
        if let size = value as? UInt { return Int64(clamping: size) }
        return nil
    }
}
