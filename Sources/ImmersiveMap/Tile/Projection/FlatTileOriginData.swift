// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PortableFoundation
import simd

struct FlatTileOriginData {
    // Origin in flat render-local space already shifted by current frame pan normalization.
    var panRelativeOrigin: SIMD2<Float>
    // Tile size in flat render-local units.
    var size: Float
    var padding: Float = 0
}
