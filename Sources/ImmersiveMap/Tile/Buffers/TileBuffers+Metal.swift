// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapMetal
import Metal

// The tile's buffers as Metal's, for the tile drawers still on Metal. They
// go when those drawers move onto the GPU interface.

extension TileBuffers {
    var backingBuffer: MTLBuffer? { gpuBackingBuffer?.metalBuffer }
}

extension TileBuffers.GeometryLayer {
    var indexType: MTLIndexType { gpuIndexType.metal }
}

extension TileBuffers.Extruded {
    var indexType: MTLIndexType { gpuIndexType.metal }
}
