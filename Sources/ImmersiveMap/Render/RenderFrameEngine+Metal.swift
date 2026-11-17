// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import Metal
import QuartzCore

/// Apple's host of the engine: the view's `CAMetalLayer`, the drawable the
/// display link delivers, the marker-synced present, and the offline video
/// export's offscreen frames.
extension RenderFrameEngine {
    /// `@MainActor`: renderer creation resolves the process-wide
    /// ``SharedRenderResources``, and every production and test creation path
    /// already runs on the main actor.
    @MainActor
    convenience init(layer: CAMetalLayer,
                     avatarSource: AvatarRenderSource,
                     markerSource: MarkerRenderSource,
                     sceneModelSource: SceneModelRenderSource,
                     layerSource: LayerRenderSource = FixedLayerRenderSource(),
                     styleRuntime: MapStyleRuntime,
                     settings: ImmersiveMapSettings = .default,
                     debugOverlayControls: DebugOverlayControlState = DebugOverlayControlState(),
                     renderCamera: FrameCameraStateResolver,
                     presentationStateResolver: MapPresentationStateController,
                     eventSink: RenderFrameEventSink,
                     tileTraceRecorder: TileTraceRecorder,
                     baseLabelTraceRecorder: BaseLabelTraceRecorder,
                     clock: RenderFrameClock = RenderFrameWallClock()) throws {
        let shared = try SharedRenderResources.shared(sampleCount: settings.postProcessing.multisampleCount)
        self.init(host: .metal(layer: layer, shared: shared, avatarSource: avatarSource, config: settings),
                  markerSource: markerSource,
                  sceneModelSource: sceneModelSource,
                  layerSource: layerSource,
                  styleRuntime: styleRuntime,
                  settings: settings,
                  debugOverlayControls: debugOverlayControls,
                  renderCamera: renderCamera,
                  presentationStateResolver: presentationStateResolver,
                  eventSink: eventSink,
                  tileTraceRecorder: tileTraceRecorder,
                  baseLabelTraceRecorder: baseLabelTraceRecorder,
                  clock: clock)
    }

    /// Renders one live frame into the drawable the display link delivered
    /// with its update. The drawable arrives pre-acquired and already sized,
    /// so the frame is measured against the texture it actually renders into
    /// and never blocks in `nextDrawable()` mid-encode.
    @discardableResult
    func render(to layer: CAMetalLayer, drawable: any CAMetalDrawable) -> Bool {
        updatePresentationSyncMode(layer: layer)
        guard let target = FrameRenderTarget.drawable(drawable) else { return false }
        return render(into: target,
                      drawSize: CGSize(width: drawable.texture.width, height: drawable.texture.height),
                      pixelsPerPoint: layer.contentsScale)
    }

    /// SwiftUI markers are platform views above the Metal layer: their frames
    /// commit with the main-thread CATransaction, while a free-running drawable
    /// presents on its own once the GPU finishes, typically one vsync apart, so
    /// markers visibly detach from their geo points while the camera moves.
    /// While markers exist, the drawable must present inside the transaction
    /// (`FrameRenderTarget.drawable(_:)`) so map and markers reach the screen
    /// in the same commit; without markers the cheaper free-running present
    /// stays.
    private func updatePresentationSyncMode(layer: CAMetalLayer) {
        let needsTransactionSync = persistentContext.markerSource
            .currentMarkerProjectionInput.entries.isEmpty == false
        if layer.presentsWithTransaction != needsTransactionSync {
            layer.presentsWithTransaction = needsTransactionSync
        }
    }

    /// Renders one frame into a caller-supplied offscreen texture. Used by the
    /// offline video export; nothing is presented. `onGPUComplete` fires on the
    /// Metal completion thread only when this call returned `true`.
    @discardableResult
    func render(offscreen request: RenderFrameOffscreenRequest) -> Bool {
        guard let target = FrameRenderTarget.offscreen(request.texture) else { return false }
        return render(into: target,
                      drawSize: request.drawSize,
                      pixelsPerPoint: request.pixelsPerPoint,
                      onGPUComplete: request.onGPUComplete)
    }
}
