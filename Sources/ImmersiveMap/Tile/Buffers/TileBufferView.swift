// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

/// A sub-range of a tile's single backing allocation: everything a draw call
/// needs to bind it, so consumers never reach back to the arena. The layout
/// of the backing allocation is the canonical `TileArenaImageMath` plan.
/// The tile drawers still on Metal read the allocation as Metal's
/// (`TileBufferView+Metal.swift`).
struct TileBufferView {
    let gpuBuffer: any GPUBuffer
    let offset: Int
    /// Element count of the typed content (vertices, indices, styles...).
    let count: Int
}
