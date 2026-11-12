// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

/// GPU buffers of the map surface grid: vertices, indices, the index count and
/// the index type for an indexed draw.
struct MapSurfaceGridBuffers {
    let verticesBuffer: any GPUBuffer
    let indicesBuffer: any GPUBuffer
    let indicesCount: Int
    let indexType: GPUIndexType

    /// Builds the GPU buffers for a static grid, narrowing the indices to 16
    /// bits when the vertex count allows it.
    static func make<Vertex>(device: any GPUDevice,
                             vertices: [Vertex],
                             indices: [UInt32]) -> MapSurfaceGridBuffers {
        func buffer<Element>(_ values: [Element]) -> any GPUBuffer {
            let buffer = values.withUnsafeBytes { bytes in
                device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, storage: .shared)
            }
            guard let buffer else {
                fatalError("Failed to allocate a map surface grid buffer")
            }
            return buffer
        }
        let verticesBuffer = buffer(vertices)
        if let narrowedIndices = IndexStorageMath.narrowedIndices(indices, vertexCount: vertices.count) {
            return MapSurfaceGridBuffers(verticesBuffer: verticesBuffer,
                                         indicesBuffer: buffer(narrowedIndices),
                                         indicesCount: narrowedIndices.count,
                                         indexType: .uint16)
        }
        return MapSurfaceGridBuffers(verticesBuffer: verticesBuffer,
                                     indicesBuffer: buffer(indices),
                                     indicesCount: indices.count,
                                     indexType: .uint32)
    }
}
