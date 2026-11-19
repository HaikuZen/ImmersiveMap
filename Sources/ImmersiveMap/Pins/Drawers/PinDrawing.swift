// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import simd

/// The pins' draw calls for one frame, apart from the renderer that
/// prepares them, so the probe scene draws them with values of its own
/// (`GPUProbeScene`): the beams first, then the bodies, then the counters,
/// each one instanced quad a pin.
enum PinDrawing {
    struct Pipelines {
        let pin: PinPipeline
        let countBadge: PinCountBadgePipeline
        let beam: PinBeamPipeline
    }

    /// One frame's per-pin buffers, all of `pinCount` entries.
    struct Frame {
        let screenPoints: any GPUBuffer
        let instances: any GPUBuffer
        let countBadgeInstances: any GPUBuffer
        let beamAnchors: any GPUBuffer
        let beamOffsets: any GPUBuffer
        let pinCount: Int
        let drawsBeams: Bool
        let drawsCountBadges: Bool
    }

    struct Styles {
        let pin: PinStyleGPU
        let countBadge: PinCountBadgeStyleGPU
        let beam: PinBeamStyleGPU
        let beamColor: SIMD4<Float>
    }

    /// `countBadgeAtlas` is asked only when the frame draws a counter, so a
    /// map whose pins have none never makes the counters' atlas.
    static func draw(encoder: any GPURenderEncoder,
                     pipelines: Pipelines,
                     frame: Frame,
                     styles: Styles,
                     screenMatrix: matrix_float4x4,
                     pinAtlas: any GPUTexture,
                     shapeField: (any GPUTexture)?,
                     countBadgeAtlas: () -> any GPUTexture) {
        guard frame.pinCount > 0 else { return }
        if frame.drawsBeams {
            pipelines.beam.selectBeamPipeline(renderEncoder: encoder)
            encoder.setVertexValue(screenMatrix, index: 0)
            encoder.setVertexBuffer(frame.beamAnchors, offset: 0, index: 1)
            encoder.setVertexBuffer(frame.beamOffsets, offset: 0, index: 2)
            encoder.setVertexValue(styles.beam, index: 3)
            encoder.setFragmentValue(styles.beamColor, index: 0)
            encoder.draw(.triangle, vertexStart: 0, vertexCount: 6, instanceCount: frame.pinCount, baseInstance: 0)
        }

        for pass in PinsRenderer.drawPassSequence(hasVisibleCountBadges: frame.drawsCountBadges) {
            switch pass {
            case .pinBody:
                pipelines.pin.selectPipeline(renderEncoder: encoder)
                encoder.setVertexValue(screenMatrix, index: 0)
                encoder.setVertexBuffer(frame.screenPoints, offset: 0, index: 1)
                encoder.setVertexBuffer(frame.instances, offset: 0, index: 2)
                encoder.setVertexValue(styles.pin, index: 3)
                encoder.setFragmentValue(styles.pin, index: 0)
                encoder.setFragmentTexture(pinAtlas, index: 0)
                encoder.setFragmentTexture(shapeField, index: 1)
                encoder.draw(.triangle, vertexStart: 0, vertexCount: 6, instanceCount: frame.pinCount, baseInstance: 0)
            case .countBadge:
                pipelines.countBadge.selectPipeline(renderEncoder: encoder)
                encoder.setVertexValue(screenMatrix, index: 0)
                encoder.setVertexBuffer(frame.screenPoints, offset: 0, index: 1)
                encoder.setVertexBuffer(frame.countBadgeInstances, offset: 0, index: 2)
                encoder.setVertexValue(styles.countBadge, index: 3)
                encoder.setFragmentTexture(countBadgeAtlas(), index: 0)
                encoder.draw(.triangle, vertexStart: 0, vertexCount: 6, instanceCount: frame.pinCount, baseInstance: 0)
            }
        }
    }
}
