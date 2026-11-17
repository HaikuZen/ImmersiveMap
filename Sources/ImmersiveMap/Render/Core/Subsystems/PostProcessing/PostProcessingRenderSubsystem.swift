// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

final class PostProcessingRenderSubsystem: RenderSubsystem {
    let name: String = "PostProcessing"

    private let fxaaPipeline: FXAAPipeline
    private let inputTextureProvider: () -> (any GPUTexture)?

    init(fxaaPipeline: FXAAPipeline,
         inputTextureProvider: @escaping () -> (any GPUTexture)?) {
        self.fxaaPipeline = fxaaPipeline
        self.inputTextureProvider = inputTextureProvider
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: any GPURenderEncoder, frameContext: FrameContext) {
        guard layer == .postProcessing,
              let inputTexture = inputTextureProvider() else {
            return
        }

        fxaaPipeline.draw(renderEncoder: encoder,
                          sourceTexture: inputTexture,
                          width: Float(frameContext.drawSize.width),
                          height: Float(frameContext.drawSize.height))
    }

    func handleMemoryWarning() {}

    func evict() {}
}
