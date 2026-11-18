// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import os
import PortableFoundation

/// Tiles parsed away from the thread the frames run on, for a host whose
/// tile loading shares that thread: a web page, where the engine's tasks
/// run on the page's one thread between its frames, and a tile's parse of a
/// hundred milliseconds and more stalls them. The page runs workers, each a
/// `PortableTilePreparer`, and sets `prepare` before it makes the map (the
/// load pipeline reads it once, when it is made): the
/// loader then hands a downloaded tile's bytes to it and materializes the
/// prepared-tile entry it gets back, as it does a disk-cache hit, parsing on
/// its own thread only when the entry does not come or does not read
/// (`ImmersiveMapNeedsTile.processDownloadResult`). Nil, the default, parses
/// in the loader's tasks as on Apple's platforms, whose loading runs on
/// threads of its own.
package enum OffThreadTilePreparation {
    /// The tile at column `x`, row `y` and zoom `z`, from its downloaded
    /// bytes, as a prepared-tile entry (`PortableTilePreparer.prepare`), or
    /// nil when the host could not prepare it.
    package typealias Prepare = @Sendable (_ x: Int, _ y: Int, _ z: Int, _ data: Data) async -> Data?

    nonisolated(unsafe) package static var prepare: Prepare?

    /// What became of the tiles handed to `prepare`: `accepted`, an entry
    /// the loader materialized, `refused`, an entry it could not read under
    /// the map's identity (another settings' parse, a damaged entry) or
    /// could not materialize, and `failed`, no entry at all. A refused or
    /// failed tile is parsed by the loader itself, so nothing is lost but
    /// the thread: the counts are what shows a pool that does nothing.
    package struct Counts: Equatable, Sendable {
        package var accepted = 0
        package var refused = 0
        package var failed = 0
    }

    private static let countsLock = OSAllocatedUnfairLock(initialState: Counts())

    package static var counts: Counts {
        countsLock.withLock { $0 }
    }

    enum Outcome {
        case accepted, refused, failed
    }

    /// An entry framed with the identity it was prepared under: the
    /// identity's namespace key (`PreparedTileCacheIdentity.namespaceComponent`)
    /// as its UTF-8 length in 4 bytes, little endian, and its bytes, then the
    /// entry. The disk cache keeps that key in its folder's name, and an entry
    /// records only part of the identity (the format, the style, the source,
    /// the text, the language), so an entry with no folder carries the key
    /// itself: a worker of other settings (labels off, another flattening)
    /// is refused, not drawn.
    static func framed(_ entry: Data, identity: PreparedTileCacheIdentity) -> Data {
        let key = Array(identity.namespaceComponent.utf8)
        var framed = Data(capacity: 4 + key.count + entry.count)
        withUnsafeBytes(of: UInt32(key.count).littleEndian) { framed.append(contentsOf: $0) }
        framed.append(contentsOf: key)
        framed.append(entry)
        return framed
    }

    /// The entry of a framed one, nil when its key is not the identity's.
    static func entry(of framed: Data, identity: PreparedTileCacheIdentity) -> Data? {
        let bytes = [UInt8](framed)
        guard bytes.count >= 4 else { return nil }
        let length = Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
        guard bytes.count >= 4 + length,
              bytes[4 ..< 4 + length].elementsEqual(identity.namespaceComponent.utf8) else {
            return nil
        }
        return Data(bytes[(4 + length)...])
    }

    static func note(_ outcome: Outcome) {
        countsLock.withLock { counts in
            switch outcome {
            case .accepted: counts.accepted += 1
            case .refused: counts.refused += 1
            case .failed: counts.failed += 1
            }
        }
    }
}

/// The tile parse a worker runs: what the tile store's builder does with a
/// tile's downloaded bytes, from the same settings, and the result encoded
/// as the prepared-tile disk cache encodes it, inline and uncompressed,
/// stamped with the identity the loader decodes it under
/// (`PreparedTileCacheIdentity.init(settings:styleRuntime:textLayout:)`).
/// It needs no GPU: the text is measured with the font metrics alone
/// (`TextLayout`), read from the resources folder.
///
/// `@unchecked Sendable`: its state is set once at init and only read, and
/// the builder is the one the tile store shares between its concurrent
/// loads on Apple's platforms.
package final class PortableTilePreparer: @unchecked Sendable {
    private let builder: TilePreparedDataBuilder
    private let identity: PreparedTileCacheIdentity

    /// `settings` must be the map's own, or the loader refuses every entry
    /// for another identity and parses the tiles itself.
    package init(settings: ImmersiveMapSettings) {
        let location = try? ImmersiveMapResourceBundle.location()
        let textLayout = TextLayout(resource: { location?.url(forResource: $0, withExtension: $1) })
        let styleRuntime = MapStyleRuntime(settings: settings)
        builder = TilePreparedDataBuilder(settings: settings, styleRuntime: styleRuntime, textLayout: textLayout)
        identity = PreparedTileCacheIdentity(settings: settings, styleRuntime: styleRuntime, textLayout: textLayout)
    }

    /// The tile parsed from its bytes and encoded as a prepared-tile entry,
    /// framed with the identity's key (`OffThreadTilePreparation.framed`),
    /// nil when the bytes do not parse or the result does not encode.
    package func prepare(x: Int, y: Int, z: Int, data: Data) -> Data? {
        let tile = Tile(x: x, y: y, z: z)
        guard let result = try? builder.build(tile: tile, data: data),
              let encoded = try? PreparedTileDiskCodec.encode(preparedTile: result.preparedTile,
                                                              cacheIdentity: identity,
                                                              compressionEnabled: false,
                                                              blobTransport: .inline) else {
            return nil
        }
        return OffThreadTilePreparation.framed(encoded.metadata, identity: identity)
    }
}
