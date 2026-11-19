// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import os
import PortableFoundation
import simd

enum PinDrawPass: Equatable {
    case pinBody
    case countBadge
}

private enum PinInstanceFlags {
    static let selected: UInt32 = 1 << 0
}

final class PinsRenderer {
    private static let logger = Logger(subsystem: "ImmersiveMap", category: "Pins")

    private let config: ImmersiveMapSettings.PinSettings
    private let pinPipeline: PinPipeline
    private let beamPipeline: PinBeamPipeline
    private let countBadgePipeline: PinCountBadgePipeline
    private let pinAtlasResource: LazyPinRenderResource<PinTextureAtlas>
    private let countBadgeAtlasResource: LazyPinRenderResource<PinCountBadgeAtlas>
    private let shapeTextureResource: LazyPinRenderResource<(any GPUTexture)?>
    private let pinStyle: PinStyle
    private let countBadgeStyle: PinCountBadgeStyle
    private let beamStyle: PinBeamStyleGPU
    private let collisionGeometry: PinCollisionGeometry
    private let selectionProjector = PinSelectionProjector()
    private let collisionLayoutSolver = PinCollisionLayoutSolver()
    private let visibilityFadeStateStore = PinVisibilityFadeStateStore()

    private let instanceBufferStore: GPUFrameSlottedBuffer<PinInstanceGPU>
    private let screenPointBufferStore: GPUFrameSlottedBuffer<ScreenPointOutput>
    private let countBadgeInstanceBufferStore: GPUFrameSlottedBuffer<PinCountBadgeInstanceGPU>
    private let beamAnchorBufferStore: GPUFrameSlottedBuffer<ScreenPointOutput>
    private let beamOffsetBufferStore: GPUFrameSlottedBuffer<PinOffset>
    private let presentationStateStore: PinPresentationStateStore
    private var instances: [PinInstanceGPU] = []
    private var countBadgeInstances: [PinCountBadgeInstanceGPU] = []
    private var screenPoints: [ScreenPointOutput] = []
    private var beamAnchors: [ScreenPointOutput] = []
    private var beamOffsets: [PinOffset] = []
    private var pinCount: Int = 0
    private var hasVisibleCountBadges: Bool = false
    private var hasVisibleBeams: Bool = false
    private var hasAppliedPins: Bool = false
    private var frameCounter: UInt64 = 0
    /// Images not fully uploaded due to the per-frame budget: another frame is needed.
    private var hasPendingAtlasUploads: Bool = false
    /// Per-frame limit on atlas rasterizations: the remaining pins appear in
    /// subsequent frames, but the frame doesn't stall on a batch of new images.
    private static let atlasUploadsPerFrameLimit = 24
    private(set) var hasActiveAnimations: Bool = false
    private(set) var selectionSnapshot: PinSelectionSnapshot = .empty
    var hasRenderablePins: Bool { pinCount > 0 }
    private var fadeInSeconds: TimeInterval { ImmersiveMapSettings.default.labels.base.fadeInSeconds }
    private var fadeOutSeconds: TimeInterval { ImmersiveMapSettings.default.labels.base.fadeOutSeconds }

    /// The device-only pin drawing resources: the pipeline states and the
    /// built-in bubble's distance field. One set serves every map view in
    /// the process. Everything mutable, and the distance field baked for a
    /// map's own pin shape, stays in the per-view renderer.
    struct SharedResources {
        let pinPipeline: PinPipeline
        let beamPipeline: PinBeamPipeline
        let countBadgePipeline: PinCountBadgePipeline
        let pinSDF: PinSDFResource

        /// The pipelines on `device`, with the bubble's distance field
        /// already loaded (`PinSDFResource`, by Metal's texture loader on
        /// Apple's platforms, by the engine's PNG decoder elsewhere).
        static func make(device: any GPUDevice,
                         pixelFormat: GPUPixelFormat,
                         pinSDF: PinSDFResource,
                         sampleCount: Int = 1) -> SharedResources {
            SharedResources(
                pinPipeline: PinPipeline(device: device,
                                         pixelFormat: pixelFormat,
                                         sampleCount: sampleCount),
                beamPipeline: PinBeamPipeline(device: device,
                                              pixelFormat: pixelFormat,
                                              sampleCount: sampleCount),
                countBadgePipeline: PinCountBadgePipeline(device: device,
                                                          pixelFormat: pixelFormat,
                                                          sampleCount: sampleCount),
                pinSDF: pinSDF
            )
        }
    }

    init(device: any GPUDevice,
         sharedResources: SharedResources,
         config: ImmersiveMapSettings.PinSettings) {
        self.config = config
        self.pinPipeline = sharedResources.pinPipeline
        self.beamPipeline = sharedResources.beamPipeline
        self.countBadgePipeline = sharedResources.countBadgePipeline
        self.instanceBufferStore = GPUFrameSlottedBuffer(device: device,
                                                     slotsCount: InFlightFramePool.inFlightFramesCount)
        self.screenPointBufferStore = GPUFrameSlottedBuffer(device: device,
                                                     slotsCount: InFlightFramePool.inFlightFramesCount)
        self.countBadgeInstanceBufferStore = GPUFrameSlottedBuffer(device: device,
                                                     slotsCount: InFlightFramePool.inFlightFramesCount)
        self.beamAnchorBufferStore = GPUFrameSlottedBuffer(device: device,
                                                     slotsCount: InFlightFramePool.inFlightFramesCount)
        self.beamOffsetBufferStore = GPUFrameSlottedBuffer(device: device,
                                                     slotsCount: InFlightFramePool.inFlightFramesCount)
        self.presentationStateStore = PinPresentationStateStore()
        self.pinAtlasResource = LazyPinRenderResource {
            PinTextureAtlas(device: device,
                               atlasSize: config.atlasSizePx,
                               cellSize: config.size.rawValue,
                               pagesMax: config.atlasPagesMax)
        }
        // The built-in bubble has its distance field in the resources. Any
        // other shape's is baked when the first pin is drawn, so a map
        // without pins never pays for it. A shape whose field cannot be
        // baked here (a path where the host has no drawer) is drawn as the
        // bubble, and one whose bake fails as a plain square.
        var shape = config.shape
        if PinShapeDistanceField.canBake(shape) == false {
            Self.logger.warning("ImmersiveMap: the pins' shape cannot be drawn without the host's drawer (PinPictureHost). The pins are drawn as the bubble.")
            shape = .bubble
        }
        let pinSDF = sharedResources.pinSDF
        let isBuiltInBubble = shape.outline == .bubble
        self.shapeTextureResource = LazyPinRenderResource {
            if isBuiltInBubble {
                return pinSDF.texture
            }
            if let texture = PinShapeDistanceField.makeTexture(device: device, shape: shape) {
                return texture
            }
            Self.logger.warning("ImmersiveMap: the pins' shape gave no distance field. The pins are drawn as squares.")
            return PinShapeDistanceField.makeTexture(device: device, shape: .picture())
        }
        let pinSizePx = Float(config.size.rawValue) * config.sizeScale
        let pinStyle = PinStyle(sizePx: pinSizePx,
                                outlineWidthPx: config.borderWidthPx,
                                contentInset: config.contentInset,
                                fillColor: config.fillColor,
                                metrics: PinShapeMetrics(shape: shape,
                                                         bubbleTailHeight: pinSDF.shapeMetrics.pointerHeightRatio),
                                distanceRangeTexels: isBuiltInBubble
                                    ? pinSDF.params.distanceRangeTexels
                                    : PinShapeDistanceField.distanceRangeTexels,
                                distanceInAlpha: isBuiltInBubble)
        self.pinStyle = pinStyle
        let countBadgeStyle = PinCountBadgeStyle(sizePx: pinSizePx,
                                                    pinStyle: pinStyle)
        self.countBadgeStyle = countBadgeStyle
        self.beamStyle = PinBeamStyleGPU(pinCenterOffsetPx: pinStyle.bodyCenterOffsetPx,
                                         pinBodyHalfMinPx: pinStyle.circleRadiusPx)
        self.collisionGeometry = PinCollisionGeometry(pinSizePx: pinSizePx,
                                                         bodyRadiusPx: pinStyle.bodyRadiusPx,
                                                         circleBodyRadiusPx: pinStyle.circleRadiusPx,
                                                         bodyCenterOffsetPx: pinStyle.bodyCenterOffsetPx)
        self.countBadgeAtlasResource = LazyPinRenderResource {
            PinCountBadgeAtlas(
                device: device,
                badgePixelSize: max(1, Int(countBadgeStyle.sizePx.x.rounded()))
            )
        }
    }

    func update(controller: ImmersiveMapPinsController?, time: TimeInterval) {
        if let snapshot = controller?.consumeSnapshot() {
            apply(snapshot: snapshot, time: time)
        }
        if controller == nil {
            clear(time: time)
        }

        hasActiveAnimations = presentationStateStore.hasActiveAnimations
            || visibilityFadeStateStore.hasActiveAnimations
    }

    private func apply(snapshot: PinsSnapshot, time: TimeInterval) {
        // Images are uploaded to the atlas lazily by visibility (rebuildFrameBuffers):
        // the atlas is keyed by image identity and evicts LRU slots on its own.
        presentationStateStore.apply(snapshot: snapshot, time: time)
        hasAppliedPins = snapshot.pins.isEmpty == false
    }

    private func clear(time: TimeInterval) {
        guard hasAppliedPins else {
            return
        }

        let snapshot = PinsSnapshot(pins: [],
                                       removedIds: [],
                                       imageUpdateIds: [],
                                       version: 0)
        apply(snapshot: snapshot, time: time)
    }

    private func makeInstance(pin: ImmersiveMapPin,
                              slot: PinAtlasSlot,
                              squashScale: SIMD2<Float>,
                              displayScale: Float,
                              morph: Float) -> PinInstanceGPU {
        let border = pin.borderColor ?? config.borderColor
        let flags: UInt32 = pin.isSelected ? PinInstanceFlags.selected : 0
        let scaledSquashScale = squashScale * pin.screenSizeScale * displayScale
        return PinInstanceGPU(uvRect: slot.uvRect,
                                 borderColor: border,
                                 squashScale: scaledSquashScale,
                                 atlasIndex: UInt32(slot.pageIndex),
                                 flags: flags,
                                 morph: morph)
    }

    static func drawPassSequence(hasVisibleCountBadges: Bool) -> [PinDrawPass] {
        var passes: [PinDrawPass] = [.pinBody]
        if hasVisibleCountBadges {
            passes.append(.countBadge)
        }
        return passes
    }



    private func makeCountBadgeInstance(pin: ImmersiveMapPin,
                                        contentAlpha: Float) -> PinCountBadgeInstanceGPU {
        guard contentAlpha > 0.0,
              let badge = pin.countBadge,
              let slot = countBadgeAtlasResource.value.slot(for: badge) else {
            return PinCountBadgeInstanceGPU(uvRect: .zero,
                                               flags: 0,
                                               screenSizeScale: pin.screenSizeScale,
                                               contentAlpha: 0.0)
        }
        return PinCountBadgeInstanceGPU(uvRect: slot.uvRect,
                                           flags: 1,
                                           screenSizeScale: pin.screenSizeScale,
                                           contentAlpha: contentAlpha)
    }

    private func rebuildFrameBuffers(layout: PinCollisionLayout,
                                     frameSlotIndex: Int) {
        instances.removeAll(keepingCapacity: true)
        countBadgeInstances.removeAll(keepingCapacity: true)
        screenPoints.removeAll(keepingCapacity: true)
        beamAnchors.removeAll(keepingCapacity: true)
        beamOffsets.removeAll(keepingCapacity: true)

        let estimatedCount = layout.pinItems.count
        instances.reserveCapacity(estimatedCount)
        countBadgeInstances.reserveCapacity(estimatedCount)
        screenPoints.reserveCapacity(estimatedCount)
        beamAnchors.reserveCapacity(estimatedCount)
        beamOffsets.reserveCapacity(estimatedCount)

        hasVisibleCountBadges = false
        hasVisibleBeams = false
        hasPendingAtlasUploads = false

        // An empty scene does not initialize the lazy atlases.
        guard layout.pinItems.isEmpty == false else {
            pinCount = 0
            ensureFrameBufferCapacity(instanceCount: 0, frameSlotIndex: frameSlotIndex)
            return
        }

        frameCounter &+= 1
        let pinAtlas = pinAtlasResource.value
        pinAtlas.beginFrame(frameCounter)
        var uploadBudget = Self.atlasUploadsPerFrameLimit

        for item in layout.pinItems {
            var slot = pinAtlas.slot(for: item.pin.image)
            if slot == nil {
                if uploadBudget > 0 {
                    // uploadImage returns nil only when the atlas is entirely
                    // occupied by this frame's images, so more frames won't help.
                    slot = pinAtlas.uploadImage(item.pin.image)
                    if slot != nil {
                        uploadBudget -= 1
                    }
                } else {
                    // The per-frame rasterization budget is exhausted: the pin
                    // will finish uploading in subsequent frames, one more pass is needed.
                    hasPendingAtlasUploads = true
                }
            }
            guard let slot else {
                continue
            }
            instances.append(makeInstance(pin: item.pin,
                                          slot: slot,
                                          squashScale: item.squashScale,
                                          displayScale: item.displayScale,
                                          morph: item.morph))
            // Only the pin standing on its geo point has badges: on a displaced
            // circle they fade out together with the morph.
            let badgeContentAlpha = PinCollisionMath.badgeContentAlpha(displayScale: item.displayScale)
                * (1.0 - item.morph)
            let countBadgeInstance = makeCountBadgeInstance(pin: item.pin,
                                                            contentAlpha: badgeContentAlpha)
            countBadgeInstances.append(countBadgeInstance)
            hasVisibleCountBadges = hasVisibleCountBadges || (countBadgeInstance.flags & 1) != 0
            screenPoints.append(item.screenPoint)

            // The cone is drawn from the true geo point to the displaced circle;
            // the anchor alpha uses the pin's final visibility so the beam
            // fades out together with it.
            var beamAnchor = item.anchorScreenPoint
            beamAnchor.visibilityAlpha = item.screenPoint.visibilityAlpha
            beamAnchors.append(beamAnchor)
            let displacement = item.screenPoint.position - item.anchorScreenPoint.position
            let beamScale = item.displayScale * item.pin.screenSizeScale
            beamOffsets.append(PinOffset(value: displacement,
                                            scale: beamScale))
            hasVisibleBeams = hasVisibleBeams
                || simd_length(displacement) > PinCollisionMath.displacedMorphStartPx
        }

        pinCount = instances.count
        ensureFrameBufferCapacity(instanceCount: pinCount,
                                  frameSlotIndex: frameSlotIndex)
        uploadFrameBuffers(frameSlotIndex: frameSlotIndex)
    }

    private func ensureFrameBufferCapacity(instanceCount: Int,
                                           frameSlotIndex: Int) {
        _ = instanceBufferStore.ensureCapacity(slot: frameSlotIndex, count: max(1, instanceCount))
        _ = countBadgeInstanceBufferStore.ensureCapacity(slot: frameSlotIndex, count: max(1, instanceCount))
        _ = screenPointBufferStore.ensureCapacity(slot: frameSlotIndex, count: max(1, instanceCount))
        _ = beamAnchorBufferStore.ensureCapacity(slot: frameSlotIndex, count: max(1, instanceCount))
        _ = beamOffsetBufferStore.ensureCapacity(slot: frameSlotIndex, count: max(1, instanceCount))
    }

    private func uploadFrameBuffers(frameSlotIndex: Int) {
        upload(values: instances, to: instanceBufferStore.buffer(for: frameSlotIndex))
        upload(values: countBadgeInstances, to: countBadgeInstanceBufferStore.buffer(for: frameSlotIndex))
        upload(values: screenPoints, to: screenPointBufferStore.buffer(for: frameSlotIndex))
        upload(values: beamAnchors, to: beamAnchorBufferStore.buffer(for: frameSlotIndex))
        upload(values: beamOffsets, to: beamOffsetBufferStore.buffer(for: frameSlotIndex))
    }

    private func upload<T>(values: [T], to buffer: any GPUBuffer) {
        guard values.isEmpty == false else { return }
        let bytesCount = values.count * MemoryLayout<T>.stride
        values.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            buffer.contents().copyMemory(from: baseAddress, byteCount: bytesCount)
        }
    }

    func compute(drawSize: CGSize,
                 cameraUniform: CameraUniform,
                 resolvedPresentation: ResolvedPresentationState,
                 time: TimeInterval,
                 frameSlotIndex: Int) {
        // The presented list is taken straight from the store and not retained
        // between frames: the store updates its cache in place, and retaining it
        // would trigger a COW copy of all pins every animated frame.
        let presentedPins = presentationStateStore.presentedEntries(at: time)
        // Cull margin: the maximum collision displacement plus twice the pin
        // size (body, flower ring, cone to the geo point).
        let cullMarginPx = config.maxOffsetPx + collisionGeometry.pinSizePx * 2.0
        let rawProjectedPins = selectionProjector.project(pins: presentedPins,
                                                             drawSize: drawSize,
                                                             cameraUniform: cameraUniform,
                                                             resolvedPresentation: resolvedPresentation,
                                                             cullMarginPx: cullMarginPx)
        let fadeResolution = visibilityFadeStateStore.resolve(projectedPins: rawProjectedPins,
                                                              time: time,
                                                              fadeInSeconds: fadeInSeconds,
                                                              fadeOutSeconds: fadeOutSeconds)
        let layout = config.spreadsApart
            ? collisionLayoutSolver.solve(projectedPins: fadeResolution.projectedPins,
                                          geometry: collisionGeometry,
                                          config: config,
                                          time: time)
            : PinCollisionLayout.anchored(fadeResolution.projectedPins)
        rebuildFrameBuffers(layout: layout,
                            frameSlotIndex: frameSlotIndex)
        hasActiveAnimations = presentationStateStore.hasActiveAnimations
            || fadeResolution.hasActiveAnimations
            || layout.hasActiveAnimations
            || hasPendingAtlasUploads
        selectionSnapshot = selectionProjector.makeSnapshot(pinItems: layout.pinItems,
                                                            drawSize: drawSize,
                                                            pinStyle: pinStyle)
    }

    func drawPins(renderEncoder: any GPURenderEncoder,
                  screenMatrix: matrix_float4x4,
                  time: Float,
                  frameSlotIndex: Int) {
        guard pinCount > 0 else { return }
        let pinAtlas = pinAtlasResource.value.textureArray
        let shapeField = shapeTextureResource.value
        let frame = PinDrawing.Frame(screenPoints: screenPointBufferStore.buffer(for: frameSlotIndex),
                                     instances: instanceBufferStore.buffer(for: frameSlotIndex),
                                     countBadgeInstances: countBadgeInstanceBufferStore.buffer(for: frameSlotIndex),
                                     beamAnchors: beamAnchorBufferStore.buffer(for: frameSlotIndex),
                                     beamOffsets: beamOffsetBufferStore.buffer(for: frameSlotIndex),
                                     pinCount: pinCount,
                                     drawsBeams: hasVisibleBeams,
                                     drawsCountBadges: hasVisibleCountBadges)
        PinDrawing.draw(encoder: renderEncoder,
                        pipelines: PinDrawing.Pipelines(pin: pinPipeline, countBadge: countBadgePipeline, beam: beamPipeline),
                        frame: frame,
                        styles: PinDrawing.Styles(pin: pinStyle.gpu,
                                                  countBadge: countBadgeStyle.gpu,
                                                  beam: beamStyle,
                                                  beamColor: config.beamColor),
                        screenMatrix: screenMatrix,
                        pinAtlas: pinAtlas,
                        shapeField: shapeField,
                        countBadgeAtlas: { self.countBadgeAtlasResource.value.texture })
    }
}
