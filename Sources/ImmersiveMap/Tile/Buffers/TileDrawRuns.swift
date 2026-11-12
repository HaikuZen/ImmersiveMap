// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// A tile's label draw runs: a style and the range of the tile's buffer its
// vertices are in. Plain values apart from `TileBuffers`, so the label
// drawing builds where there is no Metal.

struct LabelsByStyleRun {
    let style: LabelTextStyle
    let localGlyphVertices: TileBufferView?

    var localGlyphVertexCount: Int {
        localGlyphVertices?.count ?? 0
    }
}

struct PoiIconRunBuffer {
    let style: LabelTextStyle
    let localVertices: TileBufferView?

    var localVertexCount: Int {
        localVertices?.count ?? 0
    }
}

struct RouteShieldRunBuffer {
    let style: RouteShieldRunStyle
    let localVertices: TileBufferView?

    var localVertexCount: Int {
        localVertices?.count ?? 0
    }
}
