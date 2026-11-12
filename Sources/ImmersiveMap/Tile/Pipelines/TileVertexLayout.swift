// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

extension TileVertexIn {
    /// How the tile shaders read a vertex (`TilePipeline`, the raster
    /// tiles' bake): the position, the style index, the line's distance and
    /// parameter, and a deferred ribbon's direction, snorm to a unit float2.
    static let gpuVertexLayout: GPUVertexLayout = {
        var layout = GPUVertexLayout()
        layout.attributes[0] = GPUVertexAttribute(format: .float2,
                                                  offset: MemoryLayout<TileVertexIn>.offset(of: \.position)!,
                                                  bufferIndex: 0)
        layout.attributes[1] = GPUVertexAttribute(format: .uchar,
                                                  offset: MemoryLayout<TileVertexIn>.offset(of: \.styleIndex)!,
                                                  bufferIndex: 0)
        layout.attributes[2] = GPUVertexAttribute(format: .char,
                                                  offset: MemoryLayout<TileVertexIn>.offset(of: \.lineDistance)!,
                                                  bufferIndex: 0)
        layout.attributes[3] = GPUVertexAttribute(format: .short,
                                                  offset: MemoryLayout<TileVertexIn>.offset(of: \.lineParameter)!,
                                                  bufferIndex: 0)
        layout.attributes[4] = GPUVertexAttribute(format: .char2Normalized,
                                                  offset: MemoryLayout<TileVertexIn>.offset(of: \.normal)!,
                                                  bufferIndex: 0)
        layout.strides[0] = MemoryLayout<TileVertexIn>.stride
        return layout
    }()
}
