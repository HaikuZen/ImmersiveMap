// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import simd

/// One model tile, placed for the frame and ready to encode.
struct ModelTileDrawItem {
    let mesh: ModelTileMesh
    /// The tile's stored positions into the frame's flat world: the mesh's
    /// own matrix into tile space (`ModelTileMesh.positionMatrix`), then
    /// the matrix the map's own buildings of the same tile take, lowered
    /// while the tile comes up out of the ground (`ExtrusionRise`).
    let modelMatrix: matrix_float4x4
    /// Whether the tile is still partly under the ground, coming up: what
    /// is below the ground is not drawn.
    var isRising = false
}

enum ModelTileDrawer {
    /// The models in the world pass: opaque, depth tested and written,
    /// raising the surface mask bit where they land so the horizon's haze
    /// passes them by. They are drawn nearer in depth than they stand by
    /// `depthBias`, a share of their distance from the eye
    /// (`ModelArchiveSettings.depthBias`). A tile binds its buffer and its
    /// texture array once and draws every model it holds in one call.
    static func draw(renderEncoder: any GPURenderEncoder,
                     cameraUniform: CameraUniform,
                     shadowUniform: ShadowUniform,
                     shadowMap: any GPUTexture,
                     items: [ModelTileDrawItem],
                     depthBias: Float,
                     pipeline: ModelTilePipeline,
                     surfaceMaskState: any GPUDepthStencilState,
                     depthDisabledState: any GPUDepthStencilState) {
        guard items.isEmpty == false else { return }

        renderEncoder.setCullMode(.back)
        // The models are counterclockwise-wound; Metal defaults to clockwise.
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setVertexValue(cameraUniform, index: 1)
        renderEncoder.setVertexValue(depthBias, index: 3)

        renderEncoder.setFragmentValue(shadowUniform, index: 4)
        renderEncoder.setFragmentTexture(shadowMap, index: 1)
        renderEncoder.setFragmentSampler(pipeline.baseColorSampler, index: 0)

        // Every standing tile under one pipeline and one state: one draw
        // a tile.
        renderEncoder.setPipeline(pipeline.pipelineState)
        renderEncoder.setDepthStencilState(surfaceMaskState)
        renderEncoder.setStencilReference(TileSourceStencilPriority.surfaceMaskBit)
        for item in items where item.mesh.indexCount > 0 && item.isRising == false {
            bind(item, renderEncoder: renderEncoder, withTextures: true)
            drawTile(item, renderEncoder: renderEncoder)
        }

        // A tile coming up out of the ground, with what is still below the
        // ground dropped.
        if items.contains(where: \.isRising) {
            renderEncoder.setPipeline(pipeline.belowGroundClippedPipelineState)
            for item in items where item.isRising && item.mesh.indexCount > 0 {
                bind(item, renderEncoder: renderEncoder, withTextures: true)
                drawTile(item, renderEncoder: renderEncoder)
            }
        }

        renderEncoder.setCullMode(.none)
        renderEncoder.setFrontFacing(.clockwise)
        renderEncoder.setDepthStencilState(depthDisabledState)
    }

    /// Depth-only replay of the tiles from the light's orthographic camera,
    /// cull `.none`, like the scene models' casters: one draw a tile.
    static func drawShadowCasters(renderEncoder: any GPURenderEncoder,
                                  lightProjectionView: matrix_float4x4,
                                  items: [ModelTileDrawItem],
                                  pipeline: ModelTilePipeline,
                                  extrudedDepthState: any GPUDepthStencilState) {
        guard items.isEmpty == false else { return }

        renderEncoder.setPipeline(pipeline.shadowPipelineState)
        renderEncoder.setCullMode(.none)
        renderEncoder.setDepthStencilState(extrudedDepthState)
        renderEncoder.setDepthClipMode(.clamp)
        renderEncoder.setVertexValue(ShadowCasterUniform(lightProjectionView: lightProjectionView), index: 1)

        for item in items {
            bind(item, renderEncoder: renderEncoder, withTextures: false)
            drawTile(item, renderEncoder: renderEncoder)
        }

        renderEncoder.setDepthClipMode(.clip)
    }

    /// A tile's vertex buffer and matrix, and its texture array for a
    /// colour pass.
    private static func bind(_ item: ModelTileDrawItem,
                             renderEncoder: any GPURenderEncoder,
                             withTextures: Bool) {
        renderEncoder.setVertexBuffer(item.mesh.vertexBuffer, offset: 0, index: 0)
        renderEncoder.setVertexValue(item.modelMatrix, index: 2)
        if withTextures {
            renderEncoder.setFragmentTexture(item.mesh.texture, index: 0)
        }
    }

    /// Every index of the tile, in one call.
    private static func drawTile(_ item: ModelTileDrawItem, renderEncoder: any GPURenderEncoder) {
        renderEncoder.drawIndexed(.triangle,
                                  indexCount: item.mesh.indexCount,
                                  indexType: .uint32,
                                  indexBuffer: item.mesh.indexBuffer,
                                  indexBufferOffset: 0,
                                  instanceCount: 1,
                                  baseVertex: 0,
                                  baseInstance: 0)
    }
}
