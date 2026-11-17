// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import PortableFoundation

/// The map for a host that is no Apple view (the browser program,
/// `ImmersiveMapWebMap`): the frame engine over the platform's GPU device
/// (`RenderHost.portable`), with no markers, no scene models, no layers of
/// the app's and no avatars, and the camera moves a pointer and a wheel
/// make. The host calls `render` once a display frame.
@MainActor
package final class PortableMapRenderer {
    /// The device made no command queue.
    package struct Unavailable: Error, CustomStringConvertible {
        package var description: String { "The GPU device made no command queue." }
    }

    private let engine: RenderFrameEngine
    private let camera: FrameCameraStateResolver
    private let presentation: MapPresentationStateController
    private let settings: ImmersiveMapSettings
    // The engine holds its sources. They are kept here as well, as the engine's
    // contract does not promise to.
    private let markers = NoMarkers()
    private let sceneModels = NoSceneModels()
    private let eventSink = DiscardingEventSink()

    /// The world pass's sample count is the settings', 1 or 4: the two
    /// counts every WebGPU device renders with.
    package init(device: any GPUDevice, settings: ImmersiveMapSettings) throws {
        guard let commandQueue = device.makeCommandQueue() else {
            throw Unavailable()
        }
        let sampleCount = settings.postProcessing.multisampleCount > 1 ? 4 : 1
        var settings = settings
        settings.postProcessing.multisampleCount = sampleCount
        self.settings = settings
        camera = FrameCameraStateResolver(settings: settings)
        presentation = MapPresentationStateController(settings: settings)
        engine = RenderFrameEngine(host: .portable(device: device, commandQueue: commandQueue, sampleCount: sampleCount),
                                   markerSource: markers,
                                   sceneModelSource: sceneModels,
                                   styleRuntime: MapStyleRuntime(settings: settings),
                                   settings: settings,
                                   renderCamera: camera,
                                   presentationStateResolver: presentation,
                                   eventSink: eventSink,
                                   tileTraceRecorder: TileTraceRecorder(),
                                   baseLabelTraceRecorder: BaseLabelTraceRecorder())
    }

    /// Draws one frame into the texture, `width` by `height` pixels, a
    /// point being `pixelsPerPoint` of them. False when the frame was not
    /// scheduled (every frame slot still on the GPU).
    @discardableResult
    package func render(into texture: any GPUTexture, width: Int, height: Int, pixelsPerPoint: Double) -> Bool {
        engine.render(into: FrameRenderTarget(texture: texture),
                      drawSize: CGSize(width: width, height: height),
                      pixelsPerPoint: CGFloat(pixelsPerPoint))
    }

    // MARK: - Camera

    /// Where the camera is.
    package var cameraPosition: ImmersiveMapCameraPosition {
        camera.currentCameraPosition()
    }

    /// Moves the map by a drag of the points, as the Apple views' pan does
    /// (`CameraSettings.gesturePanTranslationScale`).
    package func pan(deltaX: Double, deltaY: Double) {
        let scale = settings.camera.gesturePanTranslationScale
        let transition = presentation.resolve(cameraState: camera.currentCameraState()).presentationState.transition
        camera.panCamera(deltaX: deltaX * scale, deltaY: deltaY * scale, transition: transition)
    }

    /// The drag ended: the next one is its own.
    package func endPan() {
        camera.endPanCamera()
    }

    /// Zooms by the levels, positive in.
    package func zoom(delta: Double) {
        camera.zoomCamera(delta: delta)
        applyConstraints()
    }

    /// Turns the camera about the map's centre, in radians.
    package func rotate(yaw: Double) {
        camera.rotateCameraYaw(delta: Float(yaw))
        applyConstraints()
    }

    /// Tilts the camera by the radians, held between flat and the zoom's
    /// steepest pitch.
    package func tilt(by delta: Double) {
        camera.setCameraPitch(camera.currentCameraState().pitch + Float(delta))
        applyConstraints()
    }

    /// Puts the camera over the point at the zoom, looking straight down.
    package func setCamera(latitudeDegrees: Double, longitudeDegrees: Double, zoom: Double) {
        camera.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: latitudeDegrees,
                                                            longitudeDegrees: longitudeDegrees,
                                                            zoom: zoom))
        applyConstraints()
    }

    private func applyConstraints() {
        camera.applyConstraints(presentation.cameraConstraints(cameraState: camera.currentCameraState()))
    }
}

private final class NoMarkers: MarkerRenderSource {
    var currentMarkerProjectionInput: MarkerProjectionInput { .empty }
}

private final class NoSceneModels: SceneModelRenderSource {
    var currentSceneModelsController: ImmersiveMapSceneModelsController? { nil }
}

/// The host draws every display frame, so nothing the engine reports is
/// needed: no redraw request, no selection, no HUD.
private final class DiscardingEventSink: RenderFrameEventSink, @unchecked Sendable {
    func invalidate(_ reason: RenderInvalidationReason) {}
    func applyActivityState(_ state: RenderActivityState) {}
    func updateAvatarSelectionSnapshot(_ snapshot: AvatarSelectionSnapshot) {}
    func updateSceneModelSelectionSnapshot(_ snapshot: SceneModelSelectionSnapshot) {}
    func completeSceneModelPathAnimations(_ results: [SceneModelPathAnimationResult]) {}
    func updateDebugOverlayHUDSnapshot(_ snapshot: DebugOverlayHUDSnapshot?) {}
    func updateMarkerProjectionSnapshot(_ snapshot: MarkerProjectionSnapshot) {}
}
