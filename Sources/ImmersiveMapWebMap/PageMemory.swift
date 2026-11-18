// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// Memory of the module's that the exports hand the page to read, in a file
// of its own: main.swift is top-level code, whose globals take their
// initial values only when that code runs, and a reactor never runs it, so
// there a global stays zero. Zero is nil for an optional object reference
// (`map`, `device`), but not for most values: an optional buffer of zeroes
// reads as an empty buffer, not as nil. A static property here is made on
// its first use, as anywhere but in top-level code.

#if arch(wasm32)
import ImmersiveMap
import PortableFoundation

/// One thread: plain state.
enum PageMemory {
    /// `immersivemap_map_markers`' doubles, grown as needed.
    nonisolated(unsafe) static var markers = UnsafeMutableBufferPointer<Double>.allocate(capacity: 64)

    /// `immersivemap_map_camera`'s five doubles.
    nonisolated(unsafe) static let camera = UnsafeMutableBufferPointer<Double>.allocate(capacity: 5)

    /// `immersivemap_poi_atlas_layout`'s length and JSON, made once.
    nonisolated(unsafe) static let poiAtlasLayout: UnsafeMutableRawBufferPointer = {
        let json = Array(MainActor.assumeIsolated { PortableMapRenderer.poiAtlasLayoutDescription }.utf8)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 4 + json.count, alignment: 4)
        buffer.storeBytes(of: UInt32(json.count).littleEndian, as: UInt32.self)
        buffer.baseAddress!.advanced(by: 4).copyMemory(from: json, byteCount: json.count)
        return buffer
    }()

    /// `immersivemap_map_attribution`'s length and JSON, grown as needed.
    nonisolated(unsafe) static var attribution = UnsafeMutableRawBufferPointer.allocate(byteCount: 256, alignment: 4)

    /// The text as its length (4 bytes, little endian) and its UTF-8, in
    /// the attribution's buffer.
    static func attribution(_ text: String) -> UnsafeMutableRawBufferPointer {
        let bytes = Array(text.utf8)
        if attribution.count < 4 + bytes.count {
            attribution.deallocate()
            attribution = .allocate(byteCount: max(4 + bytes.count, attribution.count * 2), alignment: 4)
        }
        attribution.storeBytes(of: UInt32(bytes.count).littleEndian, as: UInt32.self)
        attribution.baseAddress!.advanced(by: 4).copyMemory(from: bytes, byteCount: bytes.count)
        return attribution
    }

    /// `immersivemap_tiles_counts`' three doubles.
    nonisolated(unsafe) static let tileCounts = UnsafeMutableBufferPointer<Double>.allocate(capacity: 3)

    /// A tile worker's parser, made by `immersivemap_worker_start`.
    nonisolated(unsafe) static var preparer: PortableTilePreparer?

    /// `immersivemap_worker_prepare`'s length and entry, grown as needed.
    nonisolated(unsafe) static var workerEntryBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 16, alignment: 4)

    /// The entry as its length (4 bytes, little endian) and its bytes, in
    /// the worker's buffer.
    static func workerEntry(_ entry: Data) -> UnsafeMutableRawBufferPointer {
        if workerEntryBuffer.count < 4 + entry.count {
            workerEntryBuffer.deallocate()
            workerEntryBuffer = .allocate(byteCount: max(4 + entry.count, workerEntryBuffer.count * 2), alignment: 4)
        }
        workerEntryBuffer.storeBytes(of: UInt32(entry.count).littleEndian, as: UInt32.self)
        entry.withUnsafeBytes { bytes in
            workerEntryBuffer.baseAddress!.advanced(by: 4).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        return workerEntryBuffer
    }

    /// The markers' buffer, with room for `count` doubles at least.
    static func markers(count: Int) -> UnsafeMutableBufferPointer<Double> {
        if markers.count < count {
            markers.deallocate()
            markers = .allocate(capacity: max(count, markers.count * 2))
        }
        return markers
    }
}
#endif
