// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapMetal
import Metal

extension TileBufferView {
    /// The allocation as Metal's, for the tile drawers still on Metal. Goes
    /// when they move onto the GPU interface.
    var buffer: MTLBuffer { gpuBuffer.metalBuffer }
}
