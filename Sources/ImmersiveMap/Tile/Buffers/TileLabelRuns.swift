// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PortableFoundation
import simd

// The text label inputs and glyph ranges of a tile, plain values apart from
// `TileBuffers`, which holds the GPU buffers, so the code that builds them
// builds where there is no Metal.

struct TextLabelPlacementInput {
    let pointInput: TilePointInput
    let placementMeta: LabelPlacementMeta
}

struct LabelGlyphRange {
    let start: Int
    let count: Int
}
