// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapMetal
import Metal

final class PostProcessingRenderSubsystem: RenderSubsystem {
    let name: String = "PostProcessing"

    private let fxaaPipeline: FXAAPipeline
    private let inputTextureProvider: () -> MTLTexture?

    init(fxaaPipeline: FXAAPipeline,
         inputTextureProvider: @escaping () -> MTLTexture?) {
        self.fxaaPipeline = fxaaPipeline
        self.inputTextureProvider = inputTextureProvider
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .postProcessing,
              let inputTexture = inputTextureProvider(),
              // The frame's own colour, in the drawable's format.
              let format = GPUPixelFormat(metal: inputTexture.pixelFormat) else {
            return
        }

        fxaaPipeline.draw(renderEncoder: MetalRenderEncoder(encoder),
                          sourceTexture: MetalTexture(inputTexture, format: format),
                          width: Float(frameContext.drawSize.width),
                          height: Float(frameContext.drawSize.height))
    }

    func handleMemoryWarning() {}

    func evict() {}
}
