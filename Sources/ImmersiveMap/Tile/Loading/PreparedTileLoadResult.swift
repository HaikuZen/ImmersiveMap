// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PortableFoundation

package struct TileParseLayerTiming: Equatable {
    package let layerName: String
    package let duration: TimeInterval
}

struct PreparedTileLoadResult {
    let preparedTile: PreparedTileCPU
    let parseLayerTimings: [TileParseLayerTiming]
}
