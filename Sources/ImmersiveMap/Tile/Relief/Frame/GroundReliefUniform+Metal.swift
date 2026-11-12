// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapMetal
import Metal

extension GroundReliefUniform {
    /// `bind` for the draws still on the render core's Metal encoder: the
    /// same textures and bytes, straight to Metal, with no wrapper made per
    /// tile. Goes when the last of them moves onto the GPU interface.
    static func bind(_ relief: GroundRelief,
                     shading: GroundRelief? = nil,
                     over tile: Tile,
                     frame: GroundReliefFrame,
                     renderMapSize: Double,
                     encoder: MTLRenderCommandEncoder) {
        let shading = shading ?? relief
        let uniform = make(relief, shading: shading, over: tile, frame: frame, renderMapSize: renderMapSize)
        encoder.setVertexTexture(relief.texture, index: 0)
        encoder.setFragmentTexture(shading.texture, index: 3)
        encoder.setFragmentTexture(shading.occlusion ?? frame.occlusionFallbackTexture, index: 4)
        withGPUConstantBytes(of: uniform) { bytes, length in
            encoder.setVertexBytes(bytes, length: length, index: 9)
            encoder.setFragmentBytes(bytes, length: length, index: 9)
        }
    }
}
