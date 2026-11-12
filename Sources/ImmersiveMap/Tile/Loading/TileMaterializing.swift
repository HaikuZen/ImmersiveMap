// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PortableFoundation

/// What the load pipeline asks of the store that turns tiles into GPU
/// content (`TileRenderStore`): parse the bytes, and make the tile's
/// buffers from a parse or from a disk-cached arena image. The pipeline
/// names this and not the store, so it builds where the store's backend
/// does not.
protocol TileMaterializing: AnyObject, Sendable {
    func prepareTile(tile: Tile, data: Data) async -> PreparedTileLoadResult?
    func materializePreparedTile(_ preparedTile: PreparedTileCPU, plan: TileArenaImagePlan?) async -> Bool
    func materializeArenaImage(_ image: PreparedTileArenaImage) async -> PreparedTileMaterializeOutcome
}
