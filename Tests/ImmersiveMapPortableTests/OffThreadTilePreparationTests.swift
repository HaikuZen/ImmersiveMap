// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
@testable import ImmersiveMap
import MvtTestSupport
import Testing

/// A tile parsed off the loader's thread (a page's worker,
/// `PortableTilePreparer`) comes back as an entry the loader reads like a
/// disk hit, under the map's identity, and an entry of other settings is
/// refused, so the loader parses the tile itself rather than draw it
/// wrong. Offline: the tile is a synthetic city tile, no network. One test
/// at a time: they read the counts, which are the process's.
@Suite(.serialized)
struct OffThreadTilePreparationTests {
    private static let tile = Tile(x: 9, y: 5, z: 4)
    private static let bytes = MvtFixtureTileMessages.denseCity().serializedData()

    private static func settings() -> ImmersiveMapSettings {
        var settings = ImmersiveMapSettings.default.tileArchive(URL(string: "http://127.0.0.1:1/planet.pmtiles")!)
        settings.tiles.cache.preparedTileCacheEnabled = false
        settings.modelArchive.archiveURL = nil
        return settings
    }

    /// The identity the map's tile store stamps its tiles with.
    private static func identity(_ settings: ImmersiveMapSettings) -> PreparedTileCacheIdentity {
        let location = try? ImmersiveMapResourceBundle.location()
        return PreparedTileCacheIdentity(settings: settings,
                                         styleRuntime: MapStyleRuntime(settings: settings),
                                         textLayout: TextLayout(resource: { location?.url(forResource: $0, withExtension: $1) }))
    }

    private static func pipeline(preparedWith preparer: PortableTilePreparer,
                                 identity: PreparedTileCacheIdentity) -> DefaultTileLoadPipeline {
        DefaultTileLoadPipeline(tileRenderStore: nil,
                                preparedTileDiskCaching: nil,
                                tileDownloader: TileDownloader(config: settings()),
                                offThread: ({ x, y, z, data in preparer.prepare(x: x, y: y, z: z, data: data) }, identity))
    }

    @Test func aTilePreparedOffThreadReadsBackUnderTheMapsIdentity() async throws {
        let settings = Self.settings()
        let preparer = PortableTilePreparer(settings: settings)
        let framed = try #require(preparer.prepare(x: Self.tile.x, y: Self.tile.y, z: Self.tile.z, data: Self.bytes))
        let entry = try #require(OffThreadTilePreparation.entry(of: framed, identity: Self.identity(settings)))
        let hit = try PreparedTileDiskCodec.decode(data: entry,
                                                   expectedTile: Self.tile,
                                                   cacheIdentity: Self.identity(settings),
                                                   blobFileURL: URL(fileURLWithPath: "/"))
        #expect(hit.image.tile == Self.tile)

        let before = OffThreadTilePreparation.counts
        let pipeline = Self.pipeline(preparedWith: preparer, identity: Self.identity(settings))
        let prepared = await pipeline.prepareOffThread(tile: Self.tile, data: Self.bytes)
        #expect(prepared?.image.tile == Self.tile)
        #expect(OffThreadTilePreparation.counts.refused == before.refused)
    }

    /// A worker of other settings (here, labels off, which the entry itself
    /// does not record) bakes another tile: the map refuses its entry by
    /// the identity's key and counts it.
    @Test func anEntryOfOtherSettingsIsRefused() async throws {
        var other = Self.settings()
        other.labels.isEnabled = false
        let pipeline = Self.pipeline(preparedWith: PortableTilePreparer(settings: other),
                                     identity: Self.identity(Self.settings()))
        let before = OffThreadTilePreparation.counts
        #expect(await pipeline.prepareOffThread(tile: Self.tile, data: Self.bytes) == nil)
        #expect(OffThreadTilePreparation.counts.refused > before.refused)
    }

    /// Bytes that do not parse give no entry, and the loader parses them
    /// itself (and fails as it does today).
    @Test func bytesThatDoNotParseGiveNoEntry() {
        let preparer = PortableTilePreparer(settings: Self.settings())
        #expect(preparer.prepare(x: 0, y: 0, z: 0, data: Data([0xFF, 0xFF, 0xFF])) == nil)
    }
}
