// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import PortableFoundation

final class RenderPassGraph {
    static func isWorldLayer(_ layer: RenderLayer) -> Bool {
        switch layer {
        case .starfield, .globeVectorSurface, .globeCap,
             .placementStencil, .flatMapSurface, .flatMapRoads, .surfaceLabels, .buildingExtrusion, .sceneModels,
             .horizon:
            return true
        case .shadowCasters, .farShadowCasters, .groundShadowMask, .postProcessing,
             .labels, .avatars, .debugOverlay:
            return false
        }
    }

    static func isOverlayLayer(_ layer: RenderLayer) -> Bool {
        switch layer {
        case .labels, .avatars, .debugOverlay:
            return true
        case .shadowCasters, .farShadowCasters, .groundShadowMask, .starfield,
             .globeVectorSurface, .globeCap, .placementStencil, .flatMapSurface, .flatMapRoads, .surfaceLabels,
             .buildingExtrusion, .sceneModels, .horizon, .postProcessing:
            return false
        }
    }

    /// The overlay always keeps its own pass over its own cleared depth:
    /// the labels draw fill and halo in one pass and use that depth to keep
    /// a later glyph's halo off an earlier glyph's fill (TextShader.metal),
    /// which the world pass's depth, full of the ground's layer ranks and
    /// the buildings, cannot host. The merge that folded the overlay into
    /// the world pass on model-free single-sample frames saved a drawable
    /// load/store round trip; the single text pass saves far more.
    static func mergesOverlayIntoWorld(overlayLayers: [RenderLayer], renderSampleCount: Int) -> Bool {
        false
    }

    /// The world pass draw order for the frame. The planner lists the flat
    /// layers ground first; the order flips so the opaque buildings write
    /// depth before the ground is drawn and every ground fragment under a
    /// building fails its depth test unshaded (the ground writes only its
    /// rank band, farther than any building, so the flip changes nothing
    /// else).
    static func worldLayerOrder(_ layers: [RenderLayer]) -> [RenderLayer] {
        guard let surfaceIndex = layers.firstIndex(of: .flatMapSurface),
              let buildingIndex = layers.firstIndex(of: .buildingExtrusion),
              surfaceIndex < buildingIndex else {
            return layers
        }
        var ordered = layers
        ordered.remove(at: buildingIndex)
        ordered.insert(.buildingExtrusion, at: surfaceIndex)
        return ordered
    }

    /// Depth-only pass of the directional light into one window's slice of
    /// the shadow map. Ignores the drawable target: the map is a
    /// fixed-resolution offscreen depth texture that must be stored for
    /// sampling by the world pass. A plain pass into one slice, never a
    /// layered one.
    private final class ShadowMapDescriptorProvider: RenderPassDescriptorProvider {
        private let slot: ShadowCascadeSlot

        init(slot: ShadowCascadeSlot) {
            self.slot = slot
        }

        func makeRenderPassDescriptor(frameContext: FrameContext,
                                      attachments: FrameAttachmentStore,
                                      target _: FrameRenderTarget?) -> GPURenderPassDescriptor? {
            guard let shadowState = ShadowPassGateResolver.resolve(frameContext: frameContext),
                  shadowState.slots.contains(slot),
                  let shadowMapTexture = attachments.ensureShadowMapTexture(resolution: shadowState.mapResolution) else {
                return nil
            }

            var depth = GPUDepthStencilAttachment(texture: shadowMapTexture)
            depth.slice = slot.rawValue
            depth.load = .clear
            depth.store = .store
            depth.clearDepth = 1.0
            return GPURenderPassDescriptor(colorAttachments: [], depthStencilAttachment: depth)
        }
    }

    /// The ground shadow mask: a single-sample 8-bit target the size of the
    /// drawable, fully overwritten by one fullscreen triangle (so nothing to
    /// load) and stored for the world pass to read.
    private final class GroundShadowMaskDescriptorProvider: RenderPassDescriptorProvider {
        func makeRenderPassDescriptor(frameContext: FrameContext,
                                      attachments: FrameAttachmentStore,
                                      target _: FrameRenderTarget?) -> GPURenderPassDescriptor? {
            guard frameContext.renderSurfaceMode == .flat,
                  ShadowPassGateResolver.resolve(frameContext: frameContext) != nil,
                  let maskTexture = attachments.ensureGroundShadowMaskTexture(drawSize: frameContext.drawSize) else {
                return nil
            }

            var color = GPUColorAttachment(texture: maskTexture)
            color.load = .dontCare
            color.store = .store
            return GPURenderPassDescriptor(colorAttachments: [color])
        }
    }

    private final class WorldDescriptorProvider: RenderPassDescriptorProvider {
        private let clearColor: GPUClearColor
        private let depthTexture: (any GPUTexture)?
        /// Where the world's depth is kept for the label pass: the depth
        /// texture itself (stored) with one sample, a resolve target with
        /// several; nil drops it when the pass ends, as always.
        private let sceneDepthTexture: (any GPUTexture)?
        private let outputPlan: RenderFrameOutputPlan

        init(clearColor: GPUClearColor,
             depthTexture: (any GPUTexture)?,
             sceneDepthTexture: (any GPUTexture)? = nil,
             outputPlan: RenderFrameOutputPlan) {
            self.clearColor = clearColor
            self.depthTexture = depthTexture
            self.sceneDepthTexture = sceneDepthTexture
            self.outputPlan = outputPlan
        }

        func makeRenderPassDescriptor(frameContext: FrameContext,
                                      attachments: FrameAttachmentStore,
                                      target: FrameRenderTarget?) -> GPURenderPassDescriptor? {
            guard let targetTexture = target?.texture else {
                return nil
            }

            let outputTexture: (any GPUTexture)?
            switch outputPlan.worldColorDestination {
            case .drawable:
                outputTexture = targetTexture
            case .postProcessingInput:
                outputTexture = attachments.ensurePostProcessingInputTexture(drawSize: frameContext.drawSize,
                                                                             pixelFormat: targetTexture.format)
            }
            guard let outputTexture else { return nil }

            var color: GPUColorAttachment
            if outputPlan.usesMultisampleResolve {
                guard let colorTexture = attachments.ensureColorTexture(drawSize: frameContext.drawSize,
                                                                        pixelFormat: targetTexture.format) else {
                    return nil
                }
                color = GPUColorAttachment(texture: colorTexture)
                color.resolveTexture = outputTexture
                color.store = .multisampleResolve
            } else {
                color = GPUColorAttachment(texture: outputTexture)
                color.store = .store
            }
            color.load = .clear
            color.clearColor = clearColor
            var descriptor = GPURenderPassDescriptor(colorAttachments: [color])
            if let depthTexture {
                // The stencil half of the texture carries the sphere's
                // tile-priority marks and the flat map's surface bits
                // (TileSourceStencilPriority): cleared to 0, never stored
                // where the depth is dropped or resolved.
                var depth = GPUDepthStencilAttachment(texture: depthTexture)
                depth.load = .clear
                depth.store = .dontCare
                depth.clearDepth = 1.0
                depth.clearStencil = 0
                if let sceneDepthTexture {
                    if sceneDepthTexture === depthTexture {
                        depth.store = .store
                    } else {
                        // One sample serves: a road name is cut at a
                        // building's edge to the pixel, not the sample.
                        depth.resolveTexture = sceneDepthTexture
                        depth.store = .multisampleResolve
                    }
                }
                descriptor.depthStencilAttachment = depth
            }
            return descriptor
        }
    }

    private final class PostProcessingDescriptorProvider: RenderPassDescriptorProvider {
        func makeRenderPassDescriptor(frameContext _: FrameContext,
                                      attachments _: FrameAttachmentStore,
                                      target: FrameRenderTarget?) -> GPURenderPassDescriptor? {
            guard let targetTexture = target?.texture else {
                return nil
            }

            var color = GPUColorAttachment(texture: targetTexture)
            color.load = .dontCare
            color.store = .store
            return GPURenderPassDescriptor(colorAttachments: [color])
        }
    }

    private final class OverlayDescriptorProvider: RenderPassDescriptorProvider {
        func makeRenderPassDescriptor(frameContext: FrameContext,
                                      attachments: FrameAttachmentStore,
                                      target: FrameRenderTarget?) -> GPURenderPassDescriptor? {
            guard let targetTexture = target?.texture,
                  let depthTexture = attachments.ensureOverlayDepthTexture(drawSize: frameContext.drawSize) else {
                return nil
            }

            var color = GPUColorAttachment(texture: targetTexture)
            color.load = .load
            color.store = .store
            // The pipelines of the overlay layers are shared with the world
            // pass (where the overlay merges on model-free frames), so the
            // two passes must agree on the depth-stencil format.
            var depth = GPUDepthStencilAttachment(texture: depthTexture)
            depth.load = .clear
            depth.store = .dontCare
            depth.clearDepth = 1.0
            depth.clearStencil = 0
            return GPURenderPassDescriptor(colorAttachments: [color], depthStencilAttachment: depth)
        }
    }

    func plan(frameContext: FrameContext,
              settings: ImmersiveMapSettings,
              attachments: FrameAttachmentStore,
              target: FrameRenderTarget,
              renderGraph: RenderGraph) -> [RenderPassNode] {
        let resourceRegistry = renderGraph.resourceRegistry
        // A label layer that reads the world's depth (the road names under
        // the buildings) keeps it past the world pass, on those frames only.
        let keepsSceneDepth = frameContext.sharedState.sceneDepthForLabelsRequested
            && attachments.supportsSceneDepth
        let depthTexture = attachments.ensureDepthTexture(drawSize: frameContext.drawSize,
                                                          keptForLabels: keepsSceneDepth)
        if let depthTexture {
            resourceRegistry.setTexture(depthTexture, named: .depthTexture)
        }
        var sceneDepthTexture: (any GPUTexture)?
        if keepsSceneDepth {
            sceneDepthTexture = attachments.sampleCount > 1
                ? attachments.ensureSceneDepthResolveTexture(drawSize: frameContext.drawSize)
                : depthTexture
        }
        frameContext.sharedState.gpuSceneDepthTexture = sceneDepthTexture

        let clearColor = RenderFrameClearColor.make(transition: frameContext.transition,
                                                    settings: settings,
                                                    mapColor: frameContext.services.baseColors.map)
        let layerAvailability = renderGraph.passAvailability(settings: settings,
                                                             renderSurfaceMode: frameContext.renderSurfaceMode)
        let layerPlan = RenderLayerPlanner.plan(availability: layerAvailability)
            .filter(\.enabled)
            .map(\.layer)

        var nodes: [RenderPassNode] = []
        // The shadow map goes first: the world pass samples it. The gate skips the pass entirely when shadows are off
        // or the frame has no casters, and the receivers then bind the fallback
        // texture with a disabled uniform (same resolver on both sides).
        if let shadowState = ShadowPassGateResolver.resolve(frameContext: frameContext),
           let shadowMapTexture = attachments.ensureShadowMapTexture(resolution: shadowState.mapResolution) {
            resourceRegistry.setTexture(shadowMapTexture, named: .shadowMapTexture)
            // The sun is static and the buildings do not move: a window's
            // caster pass runs only when its rendered slice went stale
            // (fresh fit, new caster tile, new texture, or animating model
            // casters); otherwise the receivers keep sampling the slice
            // rendered some frames ago through matrices re-materialized for
            // this frame. The near window follows the camera and refits
            // often, the far one seldom, and each runs on its own.
            for slot in shadowState.slots
            where frameContext.shadowMapReuse.planShadowRender(frameContext: frameContext,
                                                               texture: shadowMapTexture,
                                                               slot: slot) {
                nodes.append(RenderPassNode(name: slot.passName,
                                            descriptorProvider: ShadowMapDescriptorProvider(slot: slot),
                                            layers: [slot.casterLayer]))
            }
            // The ground shadow mask follows the map it samples: one lookup
            // per pixel on the ground plane (two in the band between the
            // windows), read by every blended ground layer of the world
            // pass instead of a lookup per layer.
            if frameContext.renderSurfaceMode == .flat,
               let maskTexture = attachments.ensureGroundShadowMaskTexture(drawSize: frameContext.drawSize) {
                resourceRegistry.setTexture(maskTexture, named: .groundShadowMaskTexture)
                nodes.append(RenderPassNode(name: .groundShadowMask,
                                            descriptorProvider: GroundShadowMaskDescriptorProvider(),
                                            layers: [.groundShadowMask]))
            }
        }
        let worldLayers = Self.worldLayerOrder(layerPlan.filter(Self.isWorldLayer))
        let overlayLayers = layerPlan.filter(Self.isOverlayLayer)
        let outputPlan = RenderFrameOutputPlanner.plan(
            fxaaEnabled: settings.postProcessing.fxaaEnabled,
            renderSampleCount: attachments.sampleCount
        )

        let mergesOverlayIntoWorld = Self.mergesOverlayIntoWorld(overlayLayers: overlayLayers,
                                                                 renderSampleCount: attachments.sampleCount)
        nodes.append(RenderPassNode(name: .world,
                                    descriptorProvider: WorldDescriptorProvider(clearColor: clearColor,
                                                                                depthTexture: depthTexture,
                                                                                sceneDepthTexture: sceneDepthTexture,
                                                                                outputPlan: outputPlan),
                                    layers: mergesOverlayIntoWorld ? worldLayers + overlayLayers : worldLayers))
        if outputPlan.includesPostProcessingPass {
            nodes.append(RenderPassNode(name: .postProcessing,
                                        descriptorProvider: PostProcessingDescriptorProvider(),
                                        layers: [.postProcessing]))
        }
        if mergesOverlayIntoWorld == false, overlayLayers.isEmpty == false {
            nodes.append(RenderPassNode(name: .overlay,
                                        descriptorProvider: OverlayDescriptorProvider(),
                                        layers: overlayLayers))
        }
        return nodes
    }
}
