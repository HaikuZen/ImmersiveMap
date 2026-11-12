// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import PortableFoundation

/// The fullscreen pass that writes the ground shadow mask: one 8-bit shadow
/// factor per screen pixel, read by every flat ground layer in the world
/// pass (see GroundShadowMask.metal). Single-sample: the mask is a smooth
/// function of the pixel, not geometry with edges, and the MSAA world pass
/// reads it once per pixel.
final class GroundShadowMaskPipeline {
    static let format: GPUPixelFormat = .r8Unorm
    /// Mask pixels per drawable pixel. Half resolution: the shadow edge is
    /// already a two-texel ramp of a cascade whose texel spans several
    /// screen pixels at street zoom, so a bilinear upsample of a half-size
    /// mask is indistinguishable from a full-size one and the pass costs a
    /// quarter of the fragments. Mirrored by `kGroundShadowMaskScale` in
    /// Tile.metal, where the ground turns its pixel position into mask UV.
    static let resolutionScale: CGFloat = 0.4

    /// The mask size for a drawable, rounded up so the mask always covers it.
    static func maskSize(for drawSize: CGSize) -> CGSize {
        CGSize(width: (drawSize.width * resolutionScale).rounded(.up),
               height: (drawSize.height * resolutionScale).rounded(.up))
    }

    let pipelineState: any GPURenderPipeline

    init(device: any GPUDevice) {
        // A fullscreen triangle made in the vertex shader: no vertices, no
        // depth, no blending.
        var descriptor = GPURenderPipelineDescriptor(vertexFunction: GPUShaderFunction(name: "groundShadowMaskVertexShader"),
                                                     fragmentFunction: GPUShaderFunction(name: "groundShadowMaskFragmentShader"),
                                                     colorTargets: [GPUColorTarget(format: Self.format)])
        descriptor.label = "GroundShadowMask"
        descriptor.sampleCount = 1
        do {
            pipelineState = try device.makeRenderPipeline(descriptor)
        } catch {
            fatalError("Failed to create the ground shadow mask pipeline: \(error)")
        }
    }

    func select(renderEncoder: any GPURenderEncoder) {
        renderEncoder.setPipeline(pipelineState)
    }
}
