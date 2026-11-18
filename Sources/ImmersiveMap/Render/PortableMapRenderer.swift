// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import PortableFoundation
#if canImport(QuartzCore)
import QuartzCore
#endif

/// The map for a host that is no Apple view (the browser program,
/// `ImmersiveMapWebMap`): the frame engine over the platform's GPU device
/// (`RenderHost.portable`), with no scene models, no layers of the app's and
/// no avatars, the camera moves a pointer and a wheel make, and markers the
/// host draws itself at the positions each frame projects them to
/// (`markerPositions`), as the Apple views place theirs.
///
/// Rendering is on demand, as on Apple's platforms: the host asks
/// `needsFrame` once a display frame and calls `render` only when it is
/// true, and stops asking for display frames while it stays false. A frame
/// is needed after a camera move, a marker change or a new drawing size,
/// when the engine asks for one (a tile arrived, a retry is due) and while
/// one of its animations runs (a label fade, a rise, a zoom settling) or
/// the globe glides on after a drag (`endPan(velocityX:velocityY:)`).
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
    private let markers = PortableMarkers()
    private let sceneModels = NoSceneModels()
    private let eventSink = PortableEventSink()
    /// What asked for a frame on this side: the camera, the markers, the
    /// drawing size.
    private var demand = PortableFrameDemand()
    private var drawnSize: (width: Int, height: Int, pixelsPerPoint: Double)?
    /// The globe's glide after a drag, as the Apple views' pan inertia, from
    /// the camera settings' `globePanInertia` values.
    private let inertia: GlobeCameraPanInertia
    /// The time the glide advances by, in seconds.
    private let clock: () -> CFTimeInterval

    /// Where the markers were on the last frame drawn, in points from the
    /// drawing's top left corner. A marker beyond the globe's horizon or
    /// behind the camera is absent.
    package private(set) var markerPositions: [PortableMarkerPosition] = []

    /// The world pass's sample count is the settings', 1 or 4: the two
    /// counts every WebGPU device renders with. `poiAtlas` is the POI
    /// icons' atlas the host drew (`poiAtlasLayoutDescription`), none by
    /// default. The clock is the media clock unless a test drives its own.
    package init(device: any GPUDevice,
                 settings: ImmersiveMapSettings,
                 poiAtlas: [UInt8]? = nil,
                 clock: @escaping () -> CFTimeInterval = { CACurrentMediaTime() }) throws {
        guard let commandQueue = device.makeCommandQueue() else {
            throw Unavailable()
        }
        let sampleCount = settings.postProcessing.multisampleCount > 1 ? 4 : 1
        var settings = settings
        settings.postProcessing.multisampleCount = sampleCount
        self.settings = settings
        self.clock = clock
        let cameraSettings = settings.camera
        inertia = GlobeCameraPanInertia(configuration: .init(isEnabled: cameraSettings.globePanInertiaEnabled,
                                                             halfLife: cameraSettings.globePanInertiaHalfLife,
                                                             activationVelocity: cameraSettings.globePanInertiaActivationVelocity,
                                                             stopVelocity: cameraSettings.globePanInertiaStopVelocity,
                                                             maximumInitialVelocity: cameraSettings.globePanInertiaMaxInitialVelocity))
        camera = FrameCameraStateResolver(settings: settings)
        presentation = MapPresentationStateController(settings: settings)
        engine = RenderFrameEngine(host: .portable(device: device, commandQueue: commandQueue,
                                                   sampleCount: sampleCount, poiAtlas: poiAtlas),
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

    /// The POI icons' atlas a host draws for `init`, as JSON
    /// (`PoiSpriteAtlasLayout.hostDescription`): where each icon goes and
    /// in what format.
    package static var poiAtlasLayoutDescription: String {
        PoiSpriteAtlasLayout().hostDescription
    }

    /// Whether a frame of the size must be drawn: something changed since
    /// the last one drawn, or an animation runs.
    package func needsFrame(width: Int, height: Int, pixelsPerPoint: Double) -> Bool {
        if let drawnSize, drawnSize == (width, height, pixelsPerPoint) {
            return demand.isRequested || isGliding || eventSink.needsFrame
        }
        return true
    }

    /// Draws one frame into the texture, `width` by `height` pixels, a
    /// point being `pixelsPerPoint` of them. False when the frame was not
    /// scheduled (every frame slot still on the GPU), and the frame is then
    /// still needed.
    @discardableResult
    package func render(into texture: any GPUTexture, width: Int, height: Int, pixelsPerPoint: Double) -> Bool {
        advanceGlide()
        // Taken before the frame, so a request made while it is drawn (a
        // tile landing) asks for the next one.
        let requestedHere = demand.take()
        let requestedByEngine = eventSink.takeRequest()
        let didSchedule = engine.render(into: FrameRenderTarget(texture: texture),
                                        drawSize: CGSize(width: width, height: height),
                                        pixelsPerPoint: CGFloat(pixelsPerPoint))
        guard didSchedule else {
            if requestedHere { demand.request() }
            if requestedByEngine { eventSink.invalidate(.externalStateChanged) }
            return false
        }
        drawnSize = (width, height, pixelsPerPoint)
        markerPositions = eventSink.takeMarkerSnapshot().map {
            Self.positions(of: $0, pixelsPerPoint: pixelsPerPoint)
        } ?? markerPositions
        return true
    }

    /// The snapshot's pixels (bottom left origin, y up) as points from the
    /// top left corner, as `MarkerOverlayLayoutMath.pointFromPixel` places
    /// the Apple views' markers.
    private static func positions(of snapshot: MarkerProjectionSnapshot, pixelsPerPoint: Double) -> [PortableMarkerPosition] {
        guard pixelsPerPoint > 0 else { return [] }
        let height = Double(snapshot.drawSize.height)
        return snapshot.entries.map { entry in
            PortableMarkerPosition(id: entry.id,
                                   x: Double(entry.positionPx.x) / pixelsPerPoint,
                                   y: (height - Double(entry.positionPx.y)) / pixelsPerPoint,
                                   alpha: Double(entry.visibilityAlpha))
        }
    }

    // MARK: - Markers

    /// Places the marker of the host's id at the point, or moves it there.
    /// Markers are projected in the order they were first placed.
    package func setMarker(id: UInt64, latitudeDegrees: Double, longitudeDegrees: Double) {
        markers.set(id: id, coordinate: GeoCoordinate(latitude: latitudeDegrees, longitude: longitudeDegrees))
        demand.request()
    }

    /// Takes the marker away. Its position goes with the next frame.
    package func removeMarker(id: UInt64) {
        guard markers.remove(id: id) else { return }
        markerPositions.removeAll { $0.id == id }
        demand.request()
    }

    // MARK: - Camera

    /// Where the camera is.
    package var cameraPosition: ImmersiveMapCameraPosition {
        camera.currentCameraPosition()
    }

    /// Whether the globe still glides after a drag.
    package var isGliding: Bool {
        inertia.isActive
    }

    /// Moves the map by a drag of the points, as the Apple views' pan does
    /// (`CameraSettings.gesturePanTranslationScale`). Stops a glide.
    package func pan(deltaX: Double, deltaY: Double) {
        inertia.cancel()
        applyPan(deltaX: deltaX, deltaY: deltaY)
    }

    /// The drag ended, the pointer moving at the velocity, in points a
    /// second: on the globe, a release fast enough
    /// (`globePanInertiaActivationVelocity`) lets the map glide on and slow
    /// to a stop, as the Apple views do. The next drag is its own.
    package func endPan(velocityX: Double = 0, velocityY: Double = 0) {
        camera.endPanCamera()
        guard presentation.isSphericalSurfaceActive(cameraState: camera.currentCameraState()) else {
            inertia.cancel()
            return
        }
        if inertia.start(initialVelocity: CGPoint(x: velocityX, y: velocityY), currentTime: clock()) {
            demand.request()
        }
    }

    /// Moves the glide on to now, which `render` does before each frame: the
    /// camera pans by what it covered since the last step, until it slows to
    /// a stop or the map is no longer a globe.
    package func advanceGlide() {
        guard inertia.isActive else { return }
        guard presentation.isSphericalSurfaceActive(cameraState: camera.currentCameraState()) else {
            inertia.cancel()
            return
        }
        let step = inertia.advance(currentTime: clock())
        if step.translation != .zero {
            applyPan(deltaX: Double(step.translation.x), deltaY: Double(step.translation.y))
        }
    }

    private func applyPan(deltaX: Double, deltaY: Double) {
        let scale = settings.camera.gesturePanTranslationScale
        let transition = presentation.resolve(cameraState: camera.currentCameraState()).presentationState.transition
        camera.panCamera(deltaX: deltaX * scale, deltaY: deltaY * scale, transition: transition)
        demand.request()
    }

    /// Zooms by the levels, positive in. Stops a glide, as every move of
    /// the camera's below does.
    package func zoom(delta: Double) {
        inertia.cancel()
        camera.zoomCamera(delta: delta)
        applyConstraints()
    }

    /// Turns the camera about the map's centre, in radians.
    package func rotate(yaw: Double) {
        inertia.cancel()
        camera.rotateCameraYaw(delta: Float(yaw))
        applyConstraints()
    }

    /// Tilts the camera by the radians, held between flat and the zoom's
    /// steepest pitch.
    package func tilt(by delta: Double) {
        inertia.cancel()
        camera.setCameraPitch(camera.currentCameraState().pitch + Float(delta))
        applyConstraints()
    }

    /// Puts the camera over the point at the zoom, looking straight down.
    package func setCamera(latitudeDegrees: Double, longitudeDegrees: Double, zoom: Double) {
        inertia.cancel()
        camera.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: latitudeDegrees,
                                                            longitudeDegrees: longitudeDegrees,
                                                            zoom: zoom))
        applyConstraints()
    }

    /// Every camera move ends here, so it asks for the frame.
    private func applyConstraints() {
        camera.applyConstraints(presentation.cameraConstraints(cameraState: camera.currentCameraState()))
        demand.request()
    }
}

/// A marker's place on the last frame drawn: the host's id, the point in
/// points from the drawing's top left corner, and the opacity of the globe
/// horizon's soft fade.
package struct PortableMarkerPosition: Equatable, Sendable {
    package let id: UInt64
    package let x: Double
    package let y: Double
    package let alpha: Double
}

/// Whether this side asked for a frame since the last one drawn.
package struct PortableFrameDemand {
    package private(set) var isRequested = true

    package init() {}

    package mutating func request() {
        isRequested = true
    }

    /// Whether a frame was asked for, and the request cleared.
    package mutating func take() -> Bool {
        defer { isRequested = false }
        return isRequested
    }
}

/// The markers the host placed, by its ids, as the engine projects them.
private final class PortableMarkers: MarkerRenderSource {
    private var order: [UInt64] = []
    private var bases: [UInt64: GeoProjectionBasis] = [:]
    private(set) var currentMarkerProjectionInput: MarkerProjectionInput = .empty

    func set(id: UInt64, coordinate: GeoCoordinate) {
        if bases.updateValue(GeoProjectionBasis(coordinate: coordinate), forKey: id) == nil {
            order.append(id)
        }
        rebuild()
    }

    func remove(id: UInt64) -> Bool {
        guard bases.removeValue(forKey: id) != nil else { return false }
        order.removeAll { $0 == id }
        rebuild()
        return true
    }

    private func rebuild() {
        currentMarkerProjectionInput = MarkerProjectionInput(entries: order.compactMap { id in
            bases[id].map { MarkerProjectionEntry(id: id, basis: $0) }
        })
    }
}

private final class NoSceneModels: SceneModelRenderSource {
    var currentSceneModelsController: ImmersiveMapSceneModelsController? { nil }
}

/// What the engine reports that the host acts on: a frame asked for, the
/// animations that keep frames coming (`RenderLoopPacing` on Apple's
/// platforms) and the markers' projection. Nothing else is needed: no
/// selection, no HUD. A request comes from the tile loading's tasks too,
/// so the state is behind a lock.
private final class PortableEventSink: RenderFrameEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var isRequested = false
    private var isAnimating = false
    private var markerSnapshot: MarkerProjectionSnapshot?

    var needsFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRequested || isAnimating
    }

    func takeRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        defer { isRequested = false }
        return isRequested
    }

    func takeMarkerSnapshot() -> MarkerProjectionSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        defer { markerSnapshot = nil }
        return markerSnapshot
    }

    func invalidate(_ reason: RenderInvalidationReason) {
        lock.lock()
        isRequested = true
        lock.unlock()
    }

    func applyActivityState(_ state: RenderActivityState) {
        let animating = state.labelFadeRenderingActive
            || state.avatarAnimationRenderingActive
            || state.sceneModelAnimationRenderingActive
            || state.extrusionRiseRenderingActive
            || state.animatedZoomRenderingActive
        lock.lock()
        isAnimating = animating
        lock.unlock()
    }

    func updateMarkerProjectionSnapshot(_ snapshot: MarkerProjectionSnapshot) {
        lock.lock()
        markerSnapshot = snapshot
        lock.unlock()
    }

    func updateAvatarSelectionSnapshot(_ snapshot: AvatarSelectionSnapshot) {}
    func updateSceneModelSelectionSnapshot(_ snapshot: SceneModelSelectionSnapshot) {}
    func completeSceneModelPathAnimations(_ results: [SceneModelPathAnimationResult]) {}
    func updateDebugOverlayHUDSnapshot(_ snapshot: DebugOverlayHUDSnapshot?) {}
}
