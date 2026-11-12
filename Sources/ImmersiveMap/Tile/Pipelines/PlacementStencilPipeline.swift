// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

/// The placement prepass pipelines (`PlacementStencilRenderSubsystem`):
/// the raster tile's grid through the raster tile's vertex functions
/// (TileRaster.metal), on the plane and on the relief, on the resting
/// sphere and in the morph, with no fragment function and every color
/// attachment's write mask empty, so the draws touch nothing but the
/// stencil, where they write the planner's marks before the ground draws.
final class PlacementStencilPipeline {
    let flatPipelineState: any GPURenderPipeline
    /// The grid raised by the terrain bound at vertex texture 0 and buffer
    /// 9, as the raster tile's relief draw binds it.
    let flatReliefPipelineState: any GPURenderPipeline
    let spherePurePipelineState: any GPURenderPipeline
    let sphereMorphPipelineState: any GPURenderPipeline
    /// The screen at the far plane, depth only: puts the depth the
    /// relief's marks were tested against back to the cleared far plane
    /// before the ground draws (`placementDepthResetVertexShader`).
    let depthResetPipelineState: any GPURenderPipeline

    init(device: any GPUDevice,
         pixelFormat: GPUPixelFormat,
         sampleCount: Int = 1) {
        func state(label: String, vertex: String, relief: Bool = false) -> any GPURenderPipeline {
            // Function constant 0 raises the grid by the relief.
            var color = GPUColorTarget(format: pixelFormat)
            color.writesColor = false
            var descriptor = GPURenderPipelineDescriptor(vertexFunction: GPUShaderFunction(name: vertex, constants: [0: .bool(relief)]),
                                                         fragmentFunction: nil,
                                                         colorTargets: [color])
            descriptor.label = label
            descriptor.depthStencilFormat = .depth32FloatStencil8
            descriptor.sampleCount = sampleCount
            do {
                return try device.makeRenderPipeline(descriptor)
            } catch {
                fatalError("Failed to create the placement stencil pipeline: \(error)")
            }
        }
        flatPipelineState = state(label: "PlacementStencilFlat", vertex: "tileRasterFlatVertexShader")
        flatReliefPipelineState = state(label: "PlacementStencilFlatRelief", vertex: "tileRasterFlatVertexShader", relief: true)
        spherePurePipelineState = state(label: "PlacementStencilSpherePure", vertex: "tileRasterSpherePureVertexShader")
        sphereMorphPipelineState = state(label: "PlacementStencilSphereMorph", vertex: "tileRasterSphereMorphVertexShader")
        depthResetPipelineState = state(label: "PlacementDepthReset", vertex: "placementDepthResetVertexShader")
    }
}
