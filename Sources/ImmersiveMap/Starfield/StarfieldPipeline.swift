// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import simd

/// One star as the shaders read it: a vertex of the point draw, an entry of
/// the quads' storage buffer (StarfieldStars.metal, StarfieldStars.wgsl).
/// The last three floats are the stride's tail, named so a buffer carries
/// zeros there and not whatever the stack held.
struct StarfieldStarVertex {
    let position: SIMD3<Float>
    let size: Float
    let brightness: Float
    let temperature: Float
    let twinklePhase: Float
    let halo: Float
    let _gap0: Float = 0, _gap1: Float = 0, _gap2: Float = 0
}

/// The stars' frame values (`StarfieldParams` in the shaders): the pan
/// rotation and the sky's radius over the globe's. The gap before
/// `padding`, which a `SIMD3` aligns to 16, is named.
struct StarfieldParamsUniform {
    let rotation: matrix_float4x4
    let radiusScale: Float
    let _gap0: Float = 0, _gap1: Float = 0, _gap2: Float = 0
    let padding: SIMD3<Float>
}

/// The quads' own value (StarfieldStars.wgsl): the drawable's size in
/// pixels, which a point's size in pixels is turned into clip space by.
struct StarfieldQuadUniform {
    let viewportSizePx: SIMD2<Float>
}

/// The stars' pipeline. Metal draws each star as a sized point sprite. A
/// device without point sprites (WebGPU, `GPUDeviceFeatures.pointSprites`)
/// draws each as a quad of six vertices, instanced, the star read from a
/// storage buffer by the instance index and the sprite's coordinate made
/// from the corner, which draws the same pixels.
final class StarfieldPipeline {
    let starsPipelineState: any GPURenderPipeline
    /// Whether the stars draw as instanced quads, the device having no point
    /// sprites.
    let drawsQuads: Bool

    init(device: any GPUDevice,
         pixelFormat: GPUPixelFormat,
         sampleCount: Int = 1) {
        drawsQuads = device.features.contains(.pointSprites) == false

        var color = GPUColorTarget(format: pixelFormat)
        // Additive stars, with .one for the alpha channel: coverage accumulates
        // like the color instead of being squared by the source alpha.
        color.blend = (color: GPUBlendComponent(source: .sourceAlpha, destination: .one),
                       alpha: GPUBlendComponent(source: .one, destination: .one))

        var descriptor: GPURenderPipelineDescriptor
        if drawsQuads {
            descriptor = GPURenderPipelineDescriptor(vertexFunction: GPUShaderFunction(name: "starfieldQuadVertexShader"),
                                                     fragmentFunction: GPUShaderFunction(name: "starfieldQuadFragmentShader"),
                                                     colorTargets: [color])
            descriptor.label = "StarfieldQuads"
        } else {
            let floatSize = MemoryLayout<Float>.stride
            let positionSize = MemoryLayout<SIMD3<Float>>.stride
            var layout = GPUVertexLayout()
            layout.attributes[0] = GPUVertexAttribute(format: .float3, offset: 0, bufferIndex: 0)
            for attribute in 1 ... 5 {
                layout.attributes[attribute] = GPUVertexAttribute(format: .float,
                                                                  offset: positionSize + floatSize * (attribute - 1),
                                                                  bufferIndex: 0)
            }
            layout.strides[0] = MemoryLayout<StarfieldStarVertex>.stride
            descriptor = GPURenderPipelineDescriptor(vertexFunction: GPUShaderFunction(name: "starfieldVertexShader"),
                                                     fragmentFunction: GPUShaderFunction(name: "starfieldFragmentShader"),
                                                     colorTargets: [color])
            descriptor.label = "Starfield"
            descriptor.vertexLayout = layout
            descriptor.topology = .point
        }
        descriptor.depthStencilFormat = .depth32FloatStencil8
        descriptor.sampleCount = sampleCount

        do {
            starsPipelineState = try device.makeRenderPipeline(descriptor)
        } catch {
            fatalError("Failed to create starfield pipeline: \(error)")
        }
    }

    func selectStarsPipeline(renderEncoder: any GPURenderEncoder) {
        renderEncoder.setPipeline(starsPipelineState)
    }
}
