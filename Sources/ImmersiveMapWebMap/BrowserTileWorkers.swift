// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// The tiles parsed by the page's workers (`OffThreadTilePreparation`): the
// map's module hands a downloaded tile's bytes to the page with one import,
// the page posts them to a worker (another instance of this module, started
// with `immersivemap_worker_start`), and answers with the prepared-tile entry
// the worker made, copied into a buffer the module gives it, as the archives'
// requests are answered (BrowserFetch.swift).

#if arch(wasm32)
import ImmersiveMap
import PortableFoundation

/// Hands the tile's bytes to the page for a worker. The page answers with
/// `immersivemap_tiles_buffer` and `immersivemap_tiles_finish`, never
/// within this call.
@_extern(wasm, module: "immersivemap_tiles", name: "prepare")
private func hostPrepareTile(_ id: UInt32, _ x: Int32, _ y: Int32, _ z: Int32,
                             _ data: UnsafePointer<UInt8>?, _ length: Int32)

/// The tiles the workers have not answered yet. One thread: plain state.
enum BrowserTileWorkers {
    private struct Pending {
        let continuation: CheckedContinuation<Data?, Never>
        /// The page writes the entry here, memory of its own, never a
        /// `Data`'s, whose bytes may move.
        var entry: UnsafeMutableRawBufferPointer?
    }

    nonisolated(unsafe) private static var pending: [UInt32: Pending] = [:]
    nonisolated(unsafe) private static var nextID: UInt32 = 1

    /// `OffThreadTilePreparation.prepare` for a page with workers.
    static let prepare: OffThreadTilePreparation.Prepare = { x, y, z, data in
        await withCheckedContinuation { continuation in
            let id = nextID
            nextID &+= 1
            pending[id] = Pending(continuation: continuation)
            data.withUnsafeBytes { bytes in
                hostPrepareTile(id, Int32(x), Int32(y), Int32(z),
                                bytes.bindMemory(to: UInt8.self).baseAddress, Int32(bytes.count))
            }
        }
    }

    /// Room for the entry's `length` bytes, nil for a tile that is not
    /// pending.
    static func buffer(id: UInt32, length: Int) -> UnsafeMutableRawPointer? {
        guard var request = pending[id], length >= 0 else { return nil }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(length, 1), alignment: 1)
        request.entry?.deallocate()
        request.entry = UnsafeMutableRawBufferPointer(rebasing: buffer[0 ..< length])
        pending[id] = request
        return buffer.baseAddress
    }

    /// The worker answered: with the entry in the buffer when `prepared`,
    /// with nothing when it could not prepare the tile.
    static func finish(id: UInt32, prepared: Bool) {
        guard let request = pending.removeValue(forKey: id) else { return }
        guard let entry = request.entry else {
            request.continuation.resume(returning: nil)
            return
        }
        defer { entry.deallocate() }
        request.continuation.resume(returning: prepared ? Data(entry) : nil)
    }
}
#endif
