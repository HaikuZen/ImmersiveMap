// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

/// The pipelines of the raster tiles (TileRaster.metal): the bake, which
/// draws a tile's fills into its window of the frame's atlas when its
/// texture must be drawn again, and the draws of the texture on the plane,
/// on the resting sphere and through the unroll.
final class RasterTilePipeline {
    /// The samples per texel the bake draws with, resolved into the
    /// texture's first level: the edges of the fills are smooth before the
    /// mip chain is made from them.
    static let bakeSampleCount = 4

    let bakePipelineState: any GPURenderPipeline
    let flatPipelineState: any GPURenderPipeline
    /// The plane's draw on the ground relief (TileRaster.metal,
    /// kTileRasterRelief): the grid raised by the terrain bound at vertex
    /// texture 0 and buffer 9.
    let flatReliefPipelineState: any GPURenderPipeline
    let spherePurePipelineState: any GPURenderPipeline
    let sphereMorphPipelineState: any GPURenderPipeline
    /// The ground relief as a shadow caster (`GroundReliefShadowCasterDrawing`):
    /// the grid raised by the terrain, from the light, depth only into the
    /// shadow map, as the buildings' caster pass draws.
    let reliefShadowPipelineState: any GPURenderPipeline

    init(device: any GPUDevice,
         pixelFormat: GPUPixelFormat,
         sampleCount: Int = 1) {
        var bake = GPURenderPipelineDescriptor(vertexFunction: GPUShaderFunction(name: "tileRasterBakeVertexShader"),
                                               fragmentFunction: GPUShaderFunction(name: "tileRasterBakeFragmentShader"),
                                               colorTargets: [])
        bake.label = "RasterTileBake"
        bake.vertexLayout = TileVertexIn.gpuVertexLayout
        bake.sampleCount = Self.bakeSampleCount
        // The fills in buffer order, each over what is under it, the way
        // the vector ground layers them.
        var bakeTarget = GPUColorTarget(format: RasterTileTexture.format)
        bakeTarget.blend = (color: GPUBlendComponent(source: .sourceAlpha, destination: .oneMinusSourceAlpha),
                            alpha: GPUBlendComponent(source: .one, destination: .oneMinusSourceAlpha))
        bake.colorTargets = [bakeTarget]

        // The draws: opaque, in the world pass, through the ground's depth
        // and stencil.
        func draw(label: String, vertex: String, fragment: String, relief: Bool = false) -> GPURenderPipelineDescriptor {
            // The fragment takes the constant too: the relief's samples the
            // shadow cascades at its raised point (TileRaster.metal).
            var descriptor = GPURenderPipelineDescriptor(vertexFunction: GPUShaderFunction(name: vertex, constants: [0: .bool(relief)]),
                                                         fragmentFunction: GPUShaderFunction(name: fragment, constants: [0: .bool(relief)]),
                                                         colorTargets: [GPUColorTarget(format: pixelFormat)])
            descriptor.label = label
            descriptor.depthStencilFormat = .depth32FloatStencil8
            descriptor.sampleCount = sampleCount
            return descriptor
        }

        // A plain 2D depth attachment, as the buildings' caster pass.
        var shadow = GPURenderPipelineDescriptor(vertexFunction: GPUShaderFunction(name: "tileRasterReliefShadowVertexShader"),
                                                 fragmentFunction: nil,
                                                 colorTargets: [])
        shadow.label = "RasterTileReliefShadow"
        shadow.depthStencilFormat = ShadowCascadeAtlas.depthFormat
        shadow.sampleCount = 1

        do {
            bakePipelineState = try device.makeRenderPipeline(bake)
            flatPipelineState = try device.makeRenderPipeline(draw(label: "RasterTileFlat",
                                                                   vertex: "tileRasterFlatVertexShader",
                                                                   fragment: "tileRasterFlatFragmentShader"))
            flatReliefPipelineState = try device.makeRenderPipeline(draw(label: "RasterTileFlatRelief",
                                                                         vertex: "tileRasterFlatVertexShader",
                                                                         fragment: "tileRasterFlatFragmentShader",
                                                                         relief: true))
            spherePurePipelineState = try device.makeRenderPipeline(draw(label: "RasterTileSpherePure",
                                                                         vertex: "tileRasterSpherePureVertexShader",
                                                                         fragment: "tileRasterSphereFragmentShader"))
            sphereMorphPipelineState = try device.makeRenderPipeline(draw(label: "RasterTileSphereMorph",
                                                                          vertex: "tileRasterSphereMorphVertexShader",
                                                                          fragment: "tileRasterSphereFragmentShader"))
            reliefShadowPipelineState = try device.makeRenderPipeline(shadow)
        } catch {
            fatalError("Failed to create the raster tile pipelines: \(error)")
        }
    }
}
