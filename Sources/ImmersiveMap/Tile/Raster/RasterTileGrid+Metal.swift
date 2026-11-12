// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapMetal
import Metal

extension RasterTileGrid.Mesh {
    /// The mesh as Metal's, for the raster tiles and the relief's shadow
    /// casters, still on Metal. They go when those draws move.
    var vertices: MTLBuffer { gpuVertices.metalBuffer }
    var indices: MTLBuffer { gpuIndices.metalBuffer }
    var indexType: MTLIndexType { gpuIndexType.metal }
}
