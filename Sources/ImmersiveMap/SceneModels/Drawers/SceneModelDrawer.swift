// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import simd

/// One culled, anchor-resolved model ready to encode.
struct SceneModelDrawItem {
    let mesh: SceneModelMesh
    let modelMatrix: matrix_float4x4
    let groundPlane: SceneModelGroundPlane
    /// See `ImmersiveMapSceneModel.cutsIntoGround`.
    let cutsIntoGround: Bool
}

/// The depth and stencil states of the ground cut's four draws
/// (SceneModel.metal), built by SharedRenderResources around
/// `TileSourceStencilPriority.groundHoleBit`.
struct SceneModelGroundCutStates {
    /// The flattened footprint raising the hole bit: depth neither tested
    /// nor written.
    let holeWrite: any GPUDepthStencilState
    /// The flattened footprint lowering the hole bit again.
    let holeClear: any GPUDepthStencilState
    /// The model's two draws: scene depth, the surface mask bit raised
    /// where the model lands, and the hole bit tested equal to the
    /// reference's, raised for the draw inside the hole and clear for the
    /// draw outside it.
    let holeTest: any GPUDepthStencilState
}

/// The normal matrix as the shaders read a `float3x3` (WGSL's `mat3x3f`):
/// three columns of 16 bytes, the fourth lane of each zeroed, where a
/// `simd_float3x3` would send whatever its padding lanes held.
struct SceneModelNormalMatrixUniform {
    let column0: SIMD4<Float>
    let column1: SIMD4<Float>
    let column2: SIMD4<Float>

    init(_ matrix: simd_float3x3) {
        column0 = SIMD4(matrix.columns.0, 0)
        column1 = SIMD4(matrix.columns.1, 0)
        column2 = SIMD4(matrix.columns.2, 0)
    }
}

enum SceneModelDrawer {
    /// Swift mirror of `SceneModelMaterial` in SceneModel.metal.
    struct SceneModelMaterialUniform {
        var baseColor: SIMD4<Float>
    }

    /// Opaque model geometry with depth test and depth write in the world
    /// pass, raising the surface mask bit where it lands so the horizon's
    /// haze passes it by. A model that cuts into the ground takes the four
    /// draws of the ground cut instead (SceneModel.metal).
    static func draw(renderEncoder: any GPURenderEncoder,
                     cameraUniform: CameraUniform,
                     shadowUniform: ShadowUniform,
                     shadowMap: any GPUTexture,
                     items: [SceneModelDrawItem],
                     pipeline: SceneModelPipeline,
                     surfaceMaskState: any GPUDepthStencilState,
                     groundCutStates: SceneModelGroundCutStates,
                     depthDisabledState: any GPUDepthStencilState) {
        guard items.isEmpty == false else { return }

        renderEncoder.setCullMode(.back)
        // Model I/O meshes are counterclockwise-wound; Metal defaults to clockwise.
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setVertexValue(cameraUniform, index: 1)

        renderEncoder.setFragmentValue(shadowUniform, index: 4)
        renderEncoder.setFragmentTexture(shadowMap, index: 1)
        renderEncoder.setFragmentSampler(pipeline.baseColorSampler, index: 0)

        for item in items {
            renderEncoder.setVertexValue(item.groundPlane, index: 4)

            if item.cutsIntoGround {
                // The hole: the outline on the ground, raised, and the
                // stencil reference carries the bit the inside draw tests
                // for and the surface mask bit both draws raise.
                pipeline.selectGroundFootprintPipeline(renderEncoder: renderEncoder)
                renderEncoder.setCullMode(.none)
                renderEncoder.setDepthStencilState(groundCutStates.holeWrite)
                renderEncoder.setStencilReference(TileSourceStencilPriority.groundHoleBit)
                encodeMeshes(renderEncoder: renderEncoder, item: item, pipeline: pipeline, withMaterials: false)
                renderEncoder.setCullMode(.back)

                pipeline.selectPipeline(renderEncoder: renderEncoder)
                renderEncoder.setDepthStencilState(groundCutStates.holeTest)
                renderEncoder.setStencilReference(TileSourceStencilPriority.groundHoleBit
                                                  | TileSourceStencilPriority.surfaceMaskBit)
                encodeMeshes(renderEncoder: renderEncoder, item: item, pipeline: pipeline, withMaterials: true)

                pipeline.selectBelowGroundClippedPipeline(renderEncoder: renderEncoder)
                renderEncoder.setDepthStencilState(groundCutStates.holeTest)
                renderEncoder.setStencilReference(TileSourceStencilPriority.surfaceMaskBit)
                encodeMeshes(renderEncoder: renderEncoder, item: item, pipeline: pipeline, withMaterials: true)

                pipeline.selectGroundFootprintPipeline(renderEncoder: renderEncoder)
                renderEncoder.setCullMode(.none)
                renderEncoder.setDepthStencilState(groundCutStates.holeClear)
                encodeMeshes(renderEncoder: renderEncoder, item: item, pipeline: pipeline, withMaterials: false)
                renderEncoder.setCullMode(.back)
            } else {
                pipeline.selectPipeline(renderEncoder: renderEncoder)
                renderEncoder.setDepthStencilState(surfaceMaskState)
                renderEncoder.setStencilReference(TileSourceStencilPriority.surfaceMaskBit)
                encodeMeshes(renderEncoder: renderEncoder, item: item, pipeline: pipeline, withMaterials: true)
            }
        }

        renderEncoder.setCullMode(.none)
        renderEncoder.setFrontFacing(.clockwise)
        renderEncoder.setDepthStencilState(depthDisabledState)
    }

    /// Every submesh of the item under the pipeline and state already set.
    /// The materials are bound for the colour pipelines and skipped for the
    /// footprint pipeline, which has no fragment function.
    private static func encodeMeshes(renderEncoder: any GPURenderEncoder,
                                     item: SceneModelDrawItem,
                                     pipeline: SceneModelPipeline,
                                     withMaterials: Bool) {
        for (meshIndex, mesh) in item.mesh.meshes.enumerated() {
            let modelMatrix = item.modelMatrix * item.mesh.localTransforms[meshIndex]
            // Asset node transforms may carry non-uniform scale, so normals
            // use the inverse-transpose rather than the plain upper 3x3.
            let linear = simd_float3x3(modelMatrix.columns.0.xyz,
                                       modelMatrix.columns.1.xyz,
                                       modelMatrix.columns.2.xyz)
            renderEncoder.setVertexValue(modelMatrix, index: 2)
            renderEncoder.setVertexValue(SceneModelNormalMatrixUniform(linear.inverse.transpose), index: 3)
            renderEncoder.setVertexBuffer(mesh.vertexBuffer, offset: mesh.vertexBufferOffset, index: 0)

            let materials = item.mesh.materials.indices.contains(meshIndex)
                ? item.mesh.materials[meshIndex]
                : []
            for (submeshIndex, submesh) in mesh.submeshes.enumerated() {
                if withMaterials {
                    let material = materials.indices.contains(submeshIndex)
                        ? materials[submeshIndex]
                        : SceneModelMesh.SubmeshMaterial(baseColorTexture: nil,
                                                         baseColor: SIMD4<Float>(1, 1, 1, 1))
                    renderEncoder.setFragmentValue(SceneModelMaterialUniform(baseColor: material.baseColor), index: 3)
                    renderEncoder.setFragmentTexture(material.baseColorTexture ?? pipeline.whiteTexture, index: 0)
                }
                drawSubmesh(submesh, renderEncoder: renderEncoder)
            }
        }
    }

    private static func drawSubmesh(_ submesh: SceneModelMesh.Submesh, renderEncoder: any GPURenderEncoder) {
        renderEncoder.drawIndexed(submesh.topology,
                                  indexCount: submesh.indexCount,
                                  indexType: submesh.indexType,
                                  indexBuffer: submesh.indexBuffer,
                                  indexBufferOffset: submesh.indexBufferOffset,
                                  instanceCount: 1,
                                  baseVertex: 0,
                                  baseInstance: 0)
    }

    /// Depth-only replay of the meshes from the light's orthographic camera,
    /// one draw per submesh (one window, so nothing to instance over).
    /// No materials, no textures,
    /// cull `.none` (winding does not matter without color output). No encoder
    /// depth bias, the receiver-side bias computed by ShadowFrameStateResolver
    /// covers both caster kinds.
    static func drawShadowCasters(renderEncoder: any GPURenderEncoder,
                                  lightProjectionView: matrix_float4x4,
                                  items: [SceneModelDrawItem],
                                  pipeline: SceneModelPipeline,
                                  extrudedDepthState: any GPUDepthStencilState) {
        guard items.isEmpty == false else { return }

        pipeline.selectShadowPipeline(renderEncoder: renderEncoder)
        renderEncoder.setCullMode(.none)
        renderEncoder.setDepthStencilState(extrudedDepthState)
        renderEncoder.setDepthClipMode(.clamp)
        renderEncoder.setVertexValue(ShadowCasterUniform(lightProjectionView: lightProjectionView), index: 1)

        for item in items {
            for (meshIndex, mesh) in item.mesh.meshes.enumerated() {
                renderEncoder.setVertexValue(item.modelMatrix * item.mesh.localTransforms[meshIndex], index: 2)
                renderEncoder.setVertexBuffer(mesh.vertexBuffer, offset: mesh.vertexBufferOffset, index: 0)
                for submesh in mesh.submeshes {
                    drawSubmesh(submesh, renderEncoder: renderEncoder)
                }
            }
        }

        renderEncoder.setDepthClipMode(.clip)
    }
}
