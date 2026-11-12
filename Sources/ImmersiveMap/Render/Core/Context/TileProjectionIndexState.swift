// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  TileProjectionIndexState.swift
//  ImmersiveMap
//

import PortableFoundation

struct TileProjectionIndexState {
    nonisolated(unsafe) static let empty = TileProjectionIndexState(sourceProjectionTiles: [],
                                                tileIndexAllocator: VisibleTileIndexAllocator(indexedTiles: []),
                                                tileOriginData: [],
                                                sourceIndexVersion: 0)

    let sourceProjectionTiles: [VisibleTile]
    let tileIndexAllocator: VisibleTileIndexAllocator
    let tileOriginData: [FlatTileOriginData]
    let sourceIndexVersion: UInt64
}
