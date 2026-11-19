// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import PortableFoundation

/// The frame's own textures, made on the GPU interface and kept while their
/// size, format and use hold: the multisampled colour, the input of the
/// post-processing pass, the world depth and the overlay's, the world depth
/// resolved for the labels, the shadow map and the ground shadow mask.
final class FrameAttachmentStore {
    private let device: any GPUDevice
    private let renderSampleCount: Int
    private var colorTexture: (any GPUTexture)?
    private var postProcessingInputTexture: (any GPUTexture)?
    private var depthTexture: (any GPUTexture)?
    /// Whether `depthTexture` was made stored and readable for the labels
    /// (`ensureDepthTexture(keptForLabels:)`).
    private var depthTextureIsReadable = false
    /// The multisampled world depth resolved to one sample for the label
    /// pass to read, on frames that keep it.
    private var sceneDepthResolveTexture: (any GPUTexture)?
    private var overlayDepthTexture: (any GPUTexture)?
    private var shadowMapTexture: (any GPUTexture)?
    private var groundShadowMaskTexture: (any GPUTexture)?

    init(device: any GPUDevice,
         renderSampleCount: Int) {
        self.device = device
        self.renderSampleCount = max(1, renderSampleCount)
    }

    var currentShadowMapTexture: (any GPUTexture)? {
        shadowMapTexture
    }

    var currentGroundShadowMaskTexture: (any GPUTexture)? {
        groundShadowMaskTexture
    }

    var currentPostProcessingInputTexture: (any GPUTexture)? {
        postProcessingInputTexture
    }

    var sampleCount: Int {
        renderSampleCount
    }

    /// Whether the world depth can be kept for the label pass: always with
    /// one sample, and with several where the GPU resolves depth.
    var supportsSceneDepth: Bool {
        renderSampleCount == 1 || device.features.contains(.depthResolve)
    }

    // MSAA color and the depth attachments live only within their render pass
    // (load .clear, store .dontCare/.multisampleResolve), so on Apple TBDR GPUs
    // they need no memory outside tile memory (`GPUStorage.memoryless`, private
    // where the GPU has none). The one exception is the world depth on a frame
    // whose road names the buildings paint over: with one sample it is stored
    // for the label pass to read (`keptForLabels`).

    func ensureColorTexture(drawSize: CGSize,
                            pixelFormat: GPUPixelFormat) -> (any GPUTexture)? {
        guard renderSampleCount > 1 else { return nil }

        let width = Int(drawSize.width)
        let height = Int(drawSize.height)
        guard width > 0, height > 0 else { return nil }

        if let colorTexture,
           colorTexture.width == width,
           colorTexture.height == height,
           colorTexture.format == pixelFormat {
            return colorTexture
        }

        var descriptor = GPUTextureDescriptor(format: pixelFormat, width: width, height: height)
        descriptor.type = .type2DMultisample
        descriptor.sampleCount = renderSampleCount
        descriptor.usage = .renderTarget
        descriptor.storage = .memoryless
        descriptor.label = RenderResourceName.colorTexture.rawValue
        colorTexture = device.makeTexture(descriptor)
        return colorTexture
    }

    func ensurePostProcessingInputTexture(drawSize: CGSize,
                                          pixelFormat: GPUPixelFormat) -> (any GPUTexture)? {
        let width = Int(drawSize.width)
        let height = Int(drawSize.height)
        guard width > 0, height > 0 else { return nil }

        if let postProcessingInputTexture,
           postProcessingInputTexture.width == width,
           postProcessingInputTexture.height == height,
           postProcessingInputTexture.format == pixelFormat {
            return postProcessingInputTexture
        }

        var descriptor = GPUTextureDescriptor(format: pixelFormat, width: width, height: height)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.label = RenderResourceName.postProcessingInputTexture.rawValue
        postProcessingInputTexture = device.makeTexture(descriptor)
        return postProcessingInputTexture
    }

    /// The world pass's depth. `keptForLabels` on a single-sampled frame
    /// makes it a stored, shader-readable texture the label pass reads
    /// (`sceneDepthTexture`); otherwise it lives in tile memory alone. A
    /// multisampled depth stays transient either way and is resolved into
    /// `ensureSceneDepthResolveTexture` instead.
    func ensureDepthTexture(drawSize: CGSize, keptForLabels: Bool = false) -> (any GPUTexture)? {
        let width = Int(drawSize.width)
        let height = Int(drawSize.height)
        guard width > 0, height > 0 else { return nil }

        let isReadable = keptForLabels && renderSampleCount == 1
        if let depthTexture,
           depthTexture.width == width,
           depthTexture.height == height,
           depthTextureIsReadable == isReadable {
            return depthTexture
        }

        var descriptor = GPUTextureDescriptor(format: .depth32FloatStencil8, width: width, height: height)
        if renderSampleCount > 1 {
            descriptor.type = .type2DMultisample
            descriptor.sampleCount = renderSampleCount
        }
        descriptor.usage = isReadable ? [.renderTarget, .shaderRead] : .renderTarget
        descriptor.storage = isReadable ? .private : .memoryless
        descriptor.label = RenderResourceName.depthTexture.rawValue
        depthTexture = device.makeTexture(descriptor)
        depthTextureIsReadable = isReadable
        return depthTexture
    }

    /// One sample of the multisampled world depth, resolved at the end of
    /// the world pass for the label pass to read.
    func ensureSceneDepthResolveTexture(drawSize: CGSize) -> (any GPUTexture)? {
        let width = Int(drawSize.width)
        let height = Int(drawSize.height)
        guard width > 0, height > 0 else { return nil }

        if let sceneDepthResolveTexture,
           sceneDepthResolveTexture.width == width,
           sceneDepthResolveTexture.height == height {
            return sceneDepthResolveTexture
        }

        var descriptor = GPUTextureDescriptor(format: .depth32FloatStencil8, width: width, height: height)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.label = "SceneDepthResolveTexture"
        sceneDepthResolveTexture = device.makeTexture(descriptor)
        return sceneDepthResolveTexture
    }

    func ensureOverlayDepthTexture(drawSize: CGSize) -> (any GPUTexture)? {
        let width = Int(drawSize.width)
        let height = Int(drawSize.height)
        guard width > 0, height > 0 else { return nil }

        if let overlayDepthTexture,
           overlayDepthTexture.width == width,
           overlayDepthTexture.height == height {
            return overlayDepthTexture
        }

        var descriptor = GPUTextureDescriptor(format: .depth32FloatStencil8, width: width, height: height)
        descriptor.usage = .renderTarget
        descriptor.storage = .memoryless
        descriptor.label = RenderResourceName.overlayDepthTexture.rawValue
        overlayDepthTexture = device.makeTexture(descriptor)
        return overlayDepthTexture
    }

    /// Depth of the directional-light passes, a texture array with one
    /// square slice per window (`ShadowCascadeSlot`, near then far), each
    /// slice the attachment of its own plain pass, sampled later by the
    /// world pass: unlike the transient depth attachments it must survive
    /// its pass (`.store`) and be readable, so it is always private and
    /// shader-readable, never memoryless.
    func ensureShadowMapTexture(resolution: Int) -> (any GPUTexture)? {
        guard resolution > 0 else { return nil }

        if let shadowMapTexture,
           shadowMapTexture.width == resolution,
           shadowMapTexture.height == resolution,
           shadowMapTexture.arrayLength == ShadowCascadeAtlas.sliceCount {
            return shadowMapTexture
        }

        var descriptor = GPUTextureDescriptor(format: ShadowCascadeAtlas.depthFormat, width: resolution, height: resolution)
        descriptor.type = .type2DArray
        descriptor.arrayLength = ShadowCascadeAtlas.sliceCount
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.label = RenderResourceName.shadowMapTexture.rawValue
        shadowMapTexture = device.makeTexture(descriptor)
        return shadowMapTexture
    }

    /// The ground shadow mask: one 8-bit factor per mask pixel (half the
    /// drawable's resolution, see `GroundShadowMaskPipeline.resolutionScale`),
    /// written by the mask pass and sampled by the flat ground layers of the
    /// world pass. Single-sample and readable, so private (never
    /// memoryless).
    func ensureGroundShadowMaskTexture(drawSize: CGSize) -> (any GPUTexture)? {
        let maskSize = GroundShadowMaskPipeline.maskSize(for: drawSize)
        let width = Int(maskSize.width)
        let height = Int(maskSize.height)
        guard width > 0, height > 0 else { return nil }

        if let groundShadowMaskTexture,
           groundShadowMaskTexture.width == width,
           groundShadowMaskTexture.height == height {
            return groundShadowMaskTexture
        }

        var descriptor = GPUTextureDescriptor(format: GroundShadowMaskPipeline.format, width: width, height: height)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.label = RenderResourceName.groundShadowMaskTexture.rawValue
        groundShadowMaskTexture = device.makeTexture(descriptor)
        return groundShadowMaskTexture
    }

    func reset() {
        colorTexture = nil
        postProcessingInputTexture = nil
        depthTexture = nil
        overlayDepthTexture = nil
        shadowMapTexture = nil
        groundShadowMaskTexture = nil
    }
}
