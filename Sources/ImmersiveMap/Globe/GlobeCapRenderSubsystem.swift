// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

/// The polar caps: the sphere beyond the Mercator edge, drawn after the tile
/// geometry in the constant colours the style states for them (see
/// ImmersiveMapBaseColors). Nothing is
/// baked: the caps are two fan draws with one colour each.
final class GlobeCapRenderSubsystem: RenderSubsystem {
    let name: String = "GlobeCap"

    private let globeCapDepthState: any GPUDepthStencilState
    private let depthDisabledState: any GPUDepthStencilState
    private let globeCapRenderer: GlobeCapRenderer

    init(globeCapDepthState: any GPUDepthStencilState,
         depthDisabledState: any GPUDepthStencilState,
         globeCapRenderer: GlobeCapRenderer) {
        self.globeCapDepthState = globeCapDepthState
        self.depthDisabledState = depthDisabledState
        self.globeCapRenderer = globeCapRenderer
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: any GPURenderEncoder, frameContext: FrameContext) {
        guard layer == .globeCap,
              frameContext.renderSurfaceMode == .spherical else {
            return
        }

        encoder.setDepthStencilState(globeCapDepthState)
        globeCapRenderer.draw(renderEncoder: encoder,
                              globeFrame: GlobeFrameConstantsUniform.make(globe: frameContext.globeRenderUniform,
                                                                          cameraMatrix: frameContext.cameraUniform.matrix),
                              globe: frameContext.globeRenderUniform,
                              globeLight: GlobeLightUniform.resolve(frameContext: frameContext))
        encoder.setDepthStencilState(depthDisabledState)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
