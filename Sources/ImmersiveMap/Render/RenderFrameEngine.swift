// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import os
import PortableFoundation

/// The `Render` folder: the frame engine and nothing feature-specific. It
/// owns the frame loop, the render graph and its passes, the frame context
/// and attachments, the subsystem registry, the shared GPU resources and
/// bootstrap, the shared shader headers, post-processing, the offscreen
/// export path and the debug overlay. Every feature's own drawing (its
/// pipelines, shaders, drawers and subsystem) lives in that feature's
/// folder, next to its model and its math, and reaches the frame only
/// through `RenderSubsystem`. No networking or disk cache policy, no style
/// or label policy, no views, gestures or host-app lifecycle.
///
/// Owns the map's frame pipeline, on any GPU backend: resources, subsystem graph, frame attachments, and the render-loop workflow.
final class RenderFrameEngine {
    // MARK: - Dependencies

    let persistentContext: RenderPersistentContext

    #if DEBUG
    var persistentContextForTesting: RenderPersistentContext {
        persistentContext
    }

    /// Camera state as the next frame would collect it. Read by
    /// `RenderPresentTimingProbe` so a recorded frame carries the state it was
    /// drawn from, which is what separates "the camera moved backwards" from
    /// "the picture moved backwards".
    var debugCameraSample: (zoom: Double, centerX: Double, centerY: Double) {
        let state = renderCamera.currentCameraState()
        return (state.zoom, state.centerWorldMercator.x, state.centerWorldMercator.y)
    }

    /// Frames the engine refused to render at all, by reason, counted since
    /// launch. Distinct from the skip reasons a rendered frame's diagnostics
    /// carry, which are per-layer ("this layer had nothing to draw") and say
    /// nothing about whether the frame reached the screen.
    private(set) var debugFrameSkipCounts: [String: Int] = [:]
    /// Frames the engine scheduled: the counterpart of the above.
    private(set) var debugScheduledFrameCount = 0
    #endif
    private let renderCamera: FrameCameraStateResolver
    private let presentationStateResolver: MapPresentationStateController
    private let renderGraph: RenderGraph
    private let eventSink: RenderFrameEventSink
    private let passEncoder: RenderFramePassEncoder
    private let visibilityResolver: RenderFrameVisibilityResolver
    private let debugOverlayControls: DebugOverlayControlState

    // MARK: - Settings State

    private var settings: ImmersiveMapSettings
    /// The camera's zoom followed over time (`FrameContext.animatedZoom`),
    /// and the camera jumps it has snapped to.
    private var animatedZoom = AnimatedZoom()
    private var animatedZoomCameraJumpCount = 0
    /// The zoom the relief's collapse reads: the zoom a drag over the
    /// terrain began at while the drag lasts, so the mountains stand
    /// however the arm rides the slopes the drag crosses, then the
    /// camera's zoom, followed over a few frames as `animatedZoom` is, so
    /// the drag's end settles the relief rather than drops it. The appear
    /// fade reads the camera's zoom as it is.

    // MARK: - Frame State

    private let attachments: FrameAttachmentStore
    private let inFlightFramePool = InFlightFramePool(slotsCount: InFlightFramePool.inFlightFramesCount)
    /// Keeps the rendered shadow map alive across frames; see the type.
    private let shadowMapReuse = ShadowMapReuseController()
    /// The country around the camera read off the terrain, smoothed over
    /// the frames (`GroundReliefSurroundings`), and the last frame's
    /// reading, which the render runtime hands to the app.
    private var groundReliefSurroundings = GroundReliefSurroundings()
    private(set) var currentTerrainSurroundings: ImmersiveMapTerrainSurroundings?
    private let clock: RenderFrameClock
    /// The loader's status last written to the tile trace: the trace takes
    /// a status once per change, not once per frame.
    private var lastTracedTileLoadingStatus: TileLoadingStatusSnapshot?
    /// GPU duration of the most recently completed frame, written on the Metal
    /// completion thread and read on the main thread when the next frame's
    /// diagnostics are built.
    private let lastCompletedGPUFrameDuration = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

    private(set) var currentDiagnostics: FrameDiagnostics?

    // MARK: - Initialization

    /// `@MainActor`: renderer creation resolves the process-wide
    /// ``SharedRenderResources``, and every production and test creation path
    /// already runs on the main actor.
    /// The engine over a platform's host (`RenderHost`): Apple's builds it
    /// from the view's layer (`init(layer:...)`, `RenderFrameEngine+Metal.swift`).
    @MainActor
    init(host: RenderHost,
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
         clock: RenderFrameClock = RenderFrameWallClock()) {
        let persistentContext = RenderPersistentContext(host: host,
                                                        markerSource: markerSource,
                                                        sceneModelSource: sceneModelSource,
                                                        layerSource: layerSource,
                                                        styleRuntime: styleRuntime,
                                                        config: settings,
                                                        eventSink: eventSink,
                                                        tileTraceRecorder: tileTraceRecorder,
                                                        baseLabelTraceRecorder: baseLabelTraceRecorder)
        let attachments = FrameAttachmentStore(device: persistentContext.gpuDevice,
                                               renderSampleCount: persistentContext.renderSampleCount)

        let renderGraph = RenderGraphFactory.makeDefaultGraph(context: persistentContext,
                                                              settings: settings,
                                                              debugOverlayControls: debugOverlayControls,
                                                              postProcessingInputTextureProvider: { [attachments] in
                                                                  attachments.currentPostProcessingInputTexture
                                                              },
                                                              shadowMapTextureProvider: { [attachments] in
                                                                  attachments.currentShadowMapTexture
                                                              },
                                                              groundShadowMaskTextureProvider: { [attachments] in
                                                                  attachments.currentGroundShadowMaskTexture
                                                              })

        self.settings = settings
        self.debugOverlayControls = debugOverlayControls
        self.clock = clock
        self.persistentContext = persistentContext
        self.renderCamera = renderCamera
        self.presentationStateResolver = presentationStateResolver
        self.attachments = attachments
        self.renderGraph = renderGraph
        self.eventSink = eventSink
        self.passEncoder = RenderFramePassEncoder(attachments: attachments,
                                                  renderGraph: renderGraph)
        self.visibilityResolver = RenderFrameVisibilityResolver()
        // The HUD reads the loader's state between frames through this; the
        // reporter is held weakly so a discarded engine's reporter answers
        // nothing rather than living on in the sink.
        if let reporter = persistentContext.tileLoadingStatusReporter {
            eventSink.attachTileLoadingStatus(provider: { [weak reporter] in reporter?.snapshot() })
            reporter.onChange = { [weak eventSink] in eventSink?.tileLoadingStatusDidChange() }
        }
        // Over a terrain the camera looks at a point on it
        // (`GroundReliefFrameState.makeTerrainFollow`).
        if let groundRelief = persistentContext.groundRelief {
            renderCamera.setTerrainFollow(groundRelief.makeTerrainFollow(
                tileSettings: settings.tiles,
                globeRadiusScale: settings.presentation.globeRadiusScale,
                cameraZoom: { [weak renderCamera] in renderCamera?.currentCameraState().zoom ?? 0 }))
        }
    }

    // MARK: - Rendering

    /// Renders one frame into `target`: the platform's drawable, presented
    /// through the target, or an offscreen texture, presented nowhere.
    /// `onGPUComplete` fires on the backend's completion thread only when
    /// this call returned `true`. False when every frame slot is in flight
    /// or the frame was not scheduled.
    @discardableResult
    func render(into target: FrameRenderTarget,
                drawSize: CGSize,
                pixelsPerPoint: CGFloat,
                onGPUComplete: (@Sendable (Bool) -> Void)? = nil) -> Bool {
        guard let frameSlotIndex = inFlightFramePool.tryAcquire() else {
            recordSkippedFrame(reason: .inFlightSlotsExhausted)
            return false
        }

        let didSchedule = renderFrame(drawSize: drawSize,
                                      pixelsPerPoint: pixelsPerPoint,
                                      frameSlotIndex: frameSlotIndex,
                                      acquireTarget: { target },
                                      onGPUComplete: onGPUComplete)
        if didSchedule == false {
            inFlightFramePool.release(slot: frameSlotIndex)
            #if DEBUG
            debugFrameSkipCounts["notScheduled", default: 0] += 1
            #endif
        }
        #if DEBUG
        if didSchedule {
            debugScheduledFrameCount += 1
        }
        #endif
        return didSchedule
    }

    // MARK: - Settings

    func applySettings(_ settings: ImmersiveMapSettings) {
        renderCamera.applyCameraSettings(settings.camera)
        presentationStateResolver.applySettings(settings)
        persistentContext.applySettings(settings)
        self.settings = settings
    }

    // MARK: - Teardown

    /// Called when this engine is being discarded while the process lives on
    /// (renderer recreation, view-reuse pool drop, export teardown): stops the
    /// tile loader and cuts late event deliveries from in-flight GPU frames,
    /// which would otherwise resurrect state a successor has just reset.
    func prepareForDiscard() {
        persistentContext.tileRenderStore.cancelLoading()
        eventSink.attachTileLoadingStatus(provider: nil)
        persistentContext.tileLoadingStatusReporter?.onChange = nil
        eventSink.invalidateDelivery()
    }

    // MARK: - Memory

    func handleMemoryWarning() {
        renderGraph.handleMemoryWarning()
        attachments.reset()
    }

    // MARK: - Frame Workflow

    private func renderFrame(drawSize: CGSize,
                             pixelsPerPoint: CGFloat,
                             frameSlotIndex: Int,
                             acquireTarget: () -> FrameRenderTarget?,
                             onGPUComplete: (@Sendable (Bool) -> Void)?) -> Bool {
        let signposter = MapSignposts.render
        let frameSignpostState = signposter.beginInterval("frame")
        defer { signposter.endInterval("frame", frameSignpostState) }

        let collectSignpostState = signposter.beginInterval("stage", "collectInput")
        let collectStart = CACurrentMediaTime()
        let collectedContext = collectInput(drawSize: drawSize,
                                            pixelsPerPoint: pixelsPerPoint,
                                            frameSlotIndex: frameSlotIndex)
        signposter.endInterval("stage", collectSignpostState)
        guard let frameContext = collectedContext else {
            return false
        }
        frameContext.diagnostics.recordStage(.collectInput, duration: CACurrentMediaTime() - collectStart)

        RenderFrameStageMeasurer.measure(.updateScene, diagnostics: frameContext.diagnostics) {
            renderGraph.update(frameContext: frameContext)
        }
        publishDisplayedTilesForDebug(frameContext: frameContext)
        RenderFrameStageMeasurer.measure(.prepareGPU, diagnostics: frameContext.diagnostics) {
            prepareGPU(frameContext: frameContext)
        }
        let encodeSignpostState = signposter.beginInterval("stage", "encodePasses")
        let encodeStart = CACurrentMediaTime()
        let target = passEncoder.encode(frameContext: frameContext,
                                        acquireTarget: acquireTarget,
                                        settings: settings)
        frameContext.diagnostics.recordStage(.encodePasses, duration: CACurrentMediaTime() - encodeStart)
        signposter.endInterval("stage", encodeSignpostState)

        let presentSignpostState = signposter.beginInterval("stage", "presentFrame")
        let presentStart = CACurrentMediaTime()
        let didSchedule = presentFrame(frameContext: frameContext,
                                       target: target,
                                       frameSlotIndex: frameSlotIndex,
                                       onGPUComplete: onGPUComplete)
        frameContext.diagnostics.recordStage(.presentFrame, duration: CACurrentMediaTime() - presentStart)
        signposter.endInterval("stage", presentSignpostState)

        // The terrain still on its way, for whoever waits for a settled
        // scene (the still capture): the tiles the frame asked the relief
        // for this frame, less the ones in.
        frameContext.diagnostics.setCounter(.pendingTerrainTiles,
                                            value: persistentContext.groundRelief?.pendingTerrainTileCount ?? 0)
        let hasActiveLabelFadeAnimations = frameContext.sharedState.baseLabelState.hasActiveFadeAnimations
            || frameContext.sharedState.roadLabelState.hasActiveFadeAnimations
        let hasActiveAvatarAnimations = frameContext.sharedState.avatarState.hasActiveAnimations
        let hasActiveSceneModelAnimations = frameContext.sharedState.sceneModelState.hasActiveAnimations
        eventSink.applyActivityState(RenderActivityState(labelFadeRenderingActive: hasActiveLabelFadeAnimations,
                                                         avatarAnimationRenderingActive: hasActiveAvatarAnimations,
                                                         sceneModelAnimationRenderingActive: hasActiveSceneModelAnimations,
                                                         extrusionRiseRenderingActive: frameContext.sharedState.isExtrusionRising,
                                                         animatedZoomRenderingActive: animatedZoom.isSettling
                                                             || (persistentContext.groundRelief?.isTransitioning ?? false)))
        // Independent of `didSchedule`: the animation advanced in `update`
        // whether or not this frame reached a drawable.
        let pathAnimationResults = frameContext.sharedState.sceneModelState.pathAnimationResults
        if pathAnimationResults.isEmpty == false {
            eventSink.completeSceneModelPathAnimations(pathAnimationResults)
        }
        // Synchronously and within the same frame: SwiftUI marker positions must
        // land in the same CA transaction as this frame's present. When didSchedule
        // == false the screen shows the old frame and there is nothing to publish.
        if didSchedule, let markerProjectionSnapshot = frameContext.sharedState.markerState.snapshot {
            eventSink.updateMarkerProjectionSnapshot(markerProjectionSnapshot)
        }
        publishDebugOverlayHUDSnapshot(frameContext: frameContext)

        currentDiagnostics = frameContext.diagnostics
        currentTerrainSurroundings = frameContext.terrainSurroundings
        return didSchedule
    }

    private func collectInput(drawSize: CGSize,
                              pixelsPerPoint: CGFloat,
                              frameSlotIndex: Int) -> FrameContext? {
        let frameTick = clock.nextFrameTick()
        let diagnostics = FrameDiagnostics(frameIndex: frameTick.index, frameDeltaTime: frameTick.deltaTime)
        diagnostics.setMeasurement(.gpuFrameDurationMs,
                                   value: lastCompletedGPUFrameDuration.withLock { $0 } * 1000.0)
        var services = FrameContextServices(diagnostics: diagnostics,
                                            settings: settings,
                                            baseColors: persistentContext.baseColors,
                                            now: clock.currentDate())
        let groundRelief = persistentContext.groundRelief

        // The presentation depends on the semantic camera state alone, and
        // the render camera's pose depends on the presentation's phase (the
        // globe proximity), so the presentation resolves first.
        let resolvedPresentation = presentationStateResolver.resolve(cameraState: renderCamera.currentCameraState())
        guard let cameraFrameState = renderCamera.makeFrameState(drawSize: drawSize,
                                                                 diagnostics: diagnostics,
                                                                 transition: resolvedPresentation.presentationState.transition) else {
            currentDiagnostics = diagnostics
            return nil
        }

        // The animated zoom: the camera's followed over a few frames, or
        // snapped to a camera set outright.
        let cameraJumpCount = renderCamera.cameraJumpCount
        let cameraJumped = cameraJumpCount != animatedZoomCameraJumpCount
        animatedZoomCameraJumpCount = cameraJumpCount
        let animatedZoomValue = animatedZoom.advance(toward: cameraFrameState.mapCameraState.zoom,
                                                     deltaTime: frameTick.deltaTime,
                                                     halfLife: settings.camera.animatedZoomHalfLife,
                                                     snap: cameraJumped)
        // The terrain tiles' edges welded to their neighbours' since the
        // last frame, written before this frame's command buffer, on the
        // same queue (`GroundReliefFrameState.beginFrame`).
        groundRelief?.beginFrame(commandQueue: persistentContext.gpuCommandQueue)
        guard let commandBuffer = persistentContext.gpuCommandQueue.makeCommandBuffer() else {
            diagnostics.recordSkipReason(.missingCommandBuffer)
            currentDiagnostics = diagnostics
            return nil
        }

        publishStaticResources(frameIndex: frameTick.index)
        // The ring rules are the debug panel's: an edited rule re-runs
        // the coverage like a camera change would.
        // How far the relief falls and rises about the plane this frame,
        // in world units from the last frame's datum: the coverage reaches
        // the tiles the relief lifts into view (`CoveragePolygonBuilder`).
        var reliefHeights: ClosedRange<Float>?
        // The relief's thresholds read the planning zoom, which a drag
        // over the terrain never moves: through a drag the drawn relief
        // must stand still.
        groundRelief?.setFrame(zoom: cameraFrameState.planningZoom,
                               centerWorldMercator: cameraFrameState.mapCameraState.centerWorldMercator,
                               deltaTime: frameTick.deltaTime,
                               snap: cameraJumped)
        // One rise a metre for every tile this frame, the latitude of the
        // point the camera looks at.
        groundRelief?.setWorldScale(centerWorldMercator: cameraFrameState.mapCameraState.centerWorldMercator,
                                                           renderMapSize: resolvedPresentation.flatRenderState.renderMapSize)
        // The slopes are shaded by the scene's light, which the settings
        // change live, and fade with the distance from the eye, in metres
        // at the frame's zoom. The debug panel drags the fade's curves and
        // the amounts over the style's.
        groundRelief?.setLight(direction: settings.scene.light.direction,
                                                      cameraEye: cameraFrameState.cameraEye,
                                                      fade: debugOverlayControls.hillshadeFade(),
                                                      amounts: debugOverlayControls.hillshadeAmounts())
        // The darkening where the terrain hides the sky, the style's or the
        // debug panel's over it, and the panel's view of it alone.
        groundRelief?.setOcclusion(debugOverlayControls.terrainOcclusion(),
                                                          debugView: debugOverlayControls.terrainOcclusionDebugView())
        // The mountains' shadows, as the settings and the debug panel say.
        groundRelief?.setCastsShadows(settings.tiles.groundRelief.castsShadows
            && debugOverlayControls.reliefCastsShadows() != false)
        // On the terrain and at the datum as the last frame left them, at
        // this frame's rise.
        if let relief = groundRelief?.frame, relief.isActive,
           resolvedPresentation.renderSurfaceMode == .flat,
           let range = relief.heightRangeMetres {
            // At the strength of a mountain: the most any point rises.
            let unitsPerMetre = relief.worldUnitsPerMetre * relief.strength
            reliefHeights = ((range.lowerBound - relief.datumMetres) * unitsPerMetre)
                ... ((range.upperBound - relief.datumMetres) * unitsPerMetre)
        }
        let visibleContent = visibilityResolver.resolve(cameraFrameState: cameraFrameState,
                                                        resolvedPresentation: resolvedPresentation,
                                                        tileSettings: settings.tiles,
                                                        ruleSets: debugOverlayControls.snapshot().ringRuleSets,
                                                        reliefHeights: reliefHeights,
                                                        diagnostics: diagnostics)
        // The relief is drawn from under the point the camera looks at:
        // the terrain there is the frame's datum, so the point lies on the
        // ground at the origin and the pose holds as it is. The clearance
        // over a ridge under the eye is the camera's own business, kept
        // through the zoom (`CameraStateController`), never a lift here.
        // After the coverage, which the camera's own pose decides.
        let cameraMatrices = cameraFrameState.cameraMatrices
        let cameraEye = cameraFrameState.cameraEye
        if let groundRelief {
            // The terrain each ring reads is its rule's, resolved with the
            // coverage (`FlatRingBand.terrainZoom`).
            groundRelief.setBands(resolvedPresentation.renderSurfaceMode == .flat ? visibleContent.flatRingBands : [])
            if resolvedPresentation.renderSurfaceMode == .flat {
                groundRelief.setActive(visibleContent.tileZoomLevel >= groundRelief.fromTileZoom
                                       && groundRelief.isVisible(atZoom: cameraFrameState.planningZoom))
                if let datum = GroundReliefCameraLift.datumMetres(relief: groundRelief.frame,
                                                                  centerWorldMercator: cameraFrameState.mapCameraState.centerWorldMercator,
                                                                  tileZoom: visibleContent.tileZoomLevel) {
                    groundRelief.setDatum(metres: datum)
                }
            } else {
                groundRelief.setActive(false)
                groundRelief.setDatum(metres: 0)
            }
            // Settled: every feature of the frame reads this one relief.
            services.groundRelief = groundRelief.frame
        }
        // How opaque the names and the POIs are at the zoom the labels are
        // planned by: the style's curves, or the debug panel's over them.
        services.labelOpacity = (debugOverlayControls.labelOpacity() ?? persistentContext.labelOpacity)
            .frame(atZoom: cameraFrameState.planningZoom)
        // Mountains or a plain around the point the camera looks at, read
        // off the terrain now that the frame knows whether it is on it. A
        // few dozen height lookups on the CPU, nil off the terrain.
        let terrainSurroundings: ImmersiveMapTerrainSurroundings?
        if let relief = services.groundRelief {
            terrainSurroundings = groundReliefSurroundings.update(relief: relief,
                                                                  centerWorldMercator: cameraFrameState.mapCameraState.centerWorldMercator,
                                                                  settings: settings.tiles.groundRelief.surroundings,
                                                                  deltaTime: frameTick.deltaTime)
        } else {
            groundReliefSurroundings.reset()
            terrainSurroundings = nil
        }
        // Resolved once here, so the pass injection and every receiver bind
        // site take the same answer from `ShadowPassGateResolver`.
        let shadowFrameState = shadowMapReuse.resolveFrameState(
            renderSurfaceMode: resolvedPresentation.renderSurfaceMode,
            projectionView: cameraMatrices.projectionView,
            cameraEye: cameraEye,
            centerWorldMercator: cameraFrameState.mapCameraState.centerWorldMercator,
            flatRenderPan: resolvedPresentation.flatRenderState.pan,
            renderMapSize: resolvedPresentation.flatRenderState.renderMapSize,
            // The relief's heights as the coverage reads them: the window
            // reaches the valleys and the summits.
            groundHeights: reliefHeights,
            // The strength and the coverages read the zoom the eye sees,
            // so a zoom gesture plays them.
            zoom: animatedZoomValue,
            scene: settings.scene
        )

        return FrameContext(frameIndex: frameTick.index,
                            frameSlotIndex: frameSlotIndex,
                            time: frameTick.time,
                            deltaTime: frameTick.deltaTime,
                            drawSize: cameraFrameState.drawSize,
                            pixelsPerPoint: pixelsPerPoint,
                            viewport: cameraFrameState.viewport,
                            cameraMatrices: cameraMatrices,
                            cameraEye: cameraEye,
                            gpuCommandBuffer: commandBuffer,
                            services: services,
                            mapCameraState: cameraFrameState.mapCameraState,
                            animatedZoom: animatedZoomValue,
                            planningZoom: cameraFrameState.planningZoom,
                            terrainFollowReport: renderCamera.lastTerrainFollowReport,
                            terrainSurroundings: terrainSurroundings,
                            resolvedPresentation: resolvedPresentation,
                            visibleContent: visibleContent,
                            shadowFrameState: shadowFrameState,
                            shadowMapReuse: shadowMapReuse,
                            diagnostics: diagnostics)
    }

    private func publishStaticResources(frameIndex: UInt64) {
        let resourceRegistry = renderGraph.resourceRegistry
        resourceRegistry.beginFrame(frameIndex: frameIndex)
        resourceRegistry.setPipeline(persistentContext.polygonPipeline.pipelineState, named: .polygonPipeline)
        resourceRegistry.setPipeline(persistentContext.tilePipeline.pipelineState, named: .tilePipeline)
        resourceRegistry.setPipeline(persistentContext.extrudedTilePipeline.pipelineState, named: .extrudedTilePipeline)
        resourceRegistry.setTexture(persistentContext.textRenderer.texture, named: .labelGlyphAtlas)
        resourceRegistry.setTexture(persistentContext.poiSpriteTexture, named: .poiSpriteAtlas)
    }

    private func prepareGPU(frameContext: FrameContext) {
        renderGraph.prepareGPU(frameContext: frameContext)

        let counts = renderGraph.resourceRegistry.counts
        frameContext.services.diagnostics.setCounter(.resourceBufferCount, value: counts.buffers)
        frameContext.services.diagnostics.setCounter(.resourceTextureCount, value: counts.textures)
        frameContext.services.diagnostics.setCounter(.resourcePipelineCount, value: counts.pipelines)
    }

    /// Every rendered frame, for the content the panel shows: the panel is
    /// in step with the frame, one to one, and the frame pays for one
    /// tab's data.
    private func publishDebugOverlayHUDSnapshot(frameContext: FrameContext) {
        // A panel hidden with the map's controls reads nothing.
        guard settings.debug.enableDebugPanel, settings.controls.isHidden == false else {
            return
        }
        let content = eventSink.debugOverlayHUDContentRequest()
        #if DEBUG
        let diagnosticsOverlay: FrameDiagnostics? = content.contains(.stats) ? frameContext.diagnostics : nil
        #else
        let diagnosticsOverlay: FrameDiagnostics? = nil
        #endif
        let tileLoadingStatus = content.contains(.tiles) ? persistentContext.tileLoadingStatusReporter?.snapshot() : nil
        if let tileLoadingStatus, tileLoadingStatus != lastTracedTileLoadingStatus {
            lastTracedTileLoadingStatus = tileLoadingStatus
            persistentContext.tileTraceRecorder.record(
                .tileLoadingStatusSnapshot(frameIndex: frameContext.frameIndex,
                                           snapshot: tileLoadingStatus)
            )
        }
        eventSink.updateDebugOverlayHUDSnapshot(
            DebugOverlayHUDSnapshot.make(settings: settings.debug,
                                         frameContext: frameContext,
                                         diagnostics: diagnosticsOverlay,
                                         tileLoadingStatus: tileLoadingStatus,
                                         content: content)
        )
    }

    private func publishDisplayedTilesForDebug(frameContext: FrameContext) {
        guard let tileLoadingStatusReporter = persistentContext.tileLoadingStatusReporter else {
            return
        }
        let displayedTiles = frameContext.sharedState.tilePlacementState.placeTilesContext.tilePlacements
            .map(\.metalTile.tile)
        tileLoadingStatusReporter.recordDisplayedTiles(displayedTiles)
    }

    private func presentFrame(frameContext: FrameContext,
                              target: FrameRenderTarget?,
                              frameSlotIndex: Int,
                              onGPUComplete: (@Sendable (Bool) -> Void)?) -> Bool {
        guard let commandBuffer = frameContext.gpuCommandBuffer,
              let target else {
            return false
        }

        let avatarSelectionSnapshot = frameContext.sharedState.avatarState.selectionSnapshot
        let sceneModelSelectionSnapshot = frameContext.sharedState.sceneModelState.selectionSnapshot
        // The handler runs on a Metal thread, so it takes the engine's
        // thread-safe parts and never the engine itself.
        commandBuffer.addCompletedHandler(reporting: { [lastCompletedGPUFrameDuration, inFlightFramePool, eventSink] completion in
            if let gpuFrameDuration = completion.gpuDuration {
                lastCompletedGPUFrameDuration.withLock { $0 = gpuFrameDuration }
            }
            inFlightFramePool.release(slot: frameSlotIndex)
            eventSink.updateAvatarSelectionSnapshot(avatarSelectionSnapshot)
            eventSink.updateSceneModelSelectionSnapshot(sceneModelSelectionSnapshot)
            onGPUComplete?(completion.succeeded)
        })
        if let present = target.present {
            present(commandBuffer)
        } else {
            commandBuffer.commit()
        }
        renderGraph.frameCommitted()
        return true
    }

    // MARK: - Diagnostics

    private func recordSkippedFrame(reason: RenderSkipReason) {
        #if DEBUG
        debugFrameSkipCounts[reason.rawValue, default: 0] += 1
        #endif
        let frameTick = clock.nextFrameTick()
        let diagnostics = FrameDiagnostics(frameIndex: frameTick.index, frameDeltaTime: frameTick.deltaTime)
        diagnostics.recordSkipReason(reason)
        diagnostics.recordStage(.collectInput, duration: 0)
        diagnostics.recordStage(.updateScene, duration: 0)
        diagnostics.recordStage(.prepareGPU, duration: 0)
        diagnostics.recordStage(.encodePasses, duration: 0)
        diagnostics.recordStage(.presentFrame, duration: 0)
        currentDiagnostics = diagnostics
    }
}
