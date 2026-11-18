// Copyright (c) 2025-2026 ImmersiveMap contributors.
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
