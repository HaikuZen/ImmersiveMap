// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import simd

/// The canonical interleaved vertex layout of a scene model's meshes,
/// shared by the loader and `SceneModelPipeline` and pinned by
/// `SceneModelGPUStructLayoutTests`: position float3 at 0, normal float3 at
/// 12, uv float2 at 24, stride 32, buffer 0.
enum SceneModelVertexLayout {
    static let stride = 32
    static let normalOffset = 12
    static let uvOffset = 24
}

/// A loaded, GPU-ready model asset: meshes with per-submesh materials,
/// per-mesh node transforms, and the asset-local bounds used for sizing and
/// culling. Shared by every scene model referencing the same source URL.
struct SceneModelMesh {
    struct SubmeshMaterial {
        /// nil means untextured: the drawer binds the shared white texture and
        /// `baseColor` carries the constant color.
        let baseColorTexture: (any GPUTexture)?
        let baseColor: SIMD4<Float>
    }

    /// A run of indices drawn with one material.
    struct Submesh {
        let topology: GPUPrimitiveTopology
        let indexCount: Int
        let indexType: GPUIndexType
        let indexBuffer: any GPUBuffer
        let indexBufferOffset: Int
    }

    /// One mesh of the asset: its vertices in the canonical layout
    /// (`SceneModelVertexLayout`) and its submeshes.
    struct Part {
        let vertexBuffer: any GPUBuffer
        let vertexBufferOffset: Int
        let submeshes: [Submesh]
    }

    /// The asset-space box (`SceneModelBounds`).
    typealias Bounds = SceneModelBounds

    let meshes: [Part]
    /// Flattened node transform of each mesh inside the asset, parallel to `meshes`.
    let localTransforms: [matrix_float4x4]
    /// materials[meshIndex][submeshIndex], parallel to `meshes` and their submeshes.
    let materials: [[SubmeshMaterial]]
    let localBounds: Bounds
    let costInBytes: Int
}
