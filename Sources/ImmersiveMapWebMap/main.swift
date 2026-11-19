// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// The map in a browser, for Web/map/: the engine (`PortableMapRenderer`)
// drawing through the WebGPU backend and the page's host, its archives read
// through the page's `fetch` (BrowserFetch.swift). A WebAssembly reactor:
// the page calls `_initialize`, then `immersivemap_map_start` once,
// `immersivemap_map_frame` on the animation frames it asks for and the
// camera's and the markers' exports on input. Rendering is on demand: a
// frame call draws only when something changed, and says whether the page
// should ask for another animation frame. Nothing here runs off
// WebAssembly, where the target builds empty.
//
// A page has one thread and no run loop of Swift's: the tasks the engine
// starts (the tile loads, the archives' requests) wait on the runtime's
// executor until something runs it. Each frame and each answered request
// runs what is ready (`runReadyTasks`), never waiting for a timer.

#if arch(wasm32)
@_spi(ExperimentalCustomExecutors) import _Concurrency
import ImmersiveMap
import ImmersiveMapGPU
import ImmersiveMapWebGPU
import ImmersiveMapWebGPUBrowser
import PMTiles
import PortableFoundation

// A reactor never runs this file's top-level code, so its globals stay
// zero: only an optional object reference, whose zero is nil, belongs
// here. Any other state is in PageMemory.swift.
nonisolated(unsafe) private var device: WebGPUDevice?
nonisolated(unsafe) private var map: PortableMapRenderer?

/// Room for the page to write `length` bytes into (a URL), freed with
/// `immersivemap_free`.
@_expose(wasm, "immersivemap_alloc")
@_cdecl("immersivemap_alloc")
func mapAlloc(_ length: Int32) -> UnsafeMutableRawPointer? {
    malloc(Int(max(length, 1)))
}

@_expose(wasm, "immersivemap_free")
@_cdecl("immersivemap_free")
func mapFree(_ pointer: UnsafeMutableRawPointer?) {
    WASILibc.free(pointer)
}

/// Makes the device and the map. `features` is `GPUDeviceFeatures`' raw
/// value for what the page's WebGPU device offers, `multisample` asks for
/// MSAA 4x, the archive's URL, UTF-8 at `archive`, is the tile source, the
/// engine's own when empty, and the bytes at `poiAtlas` are the POI icons'
/// atlas the page drew (`immersivemap_poi_atlas_layout`), no icons when
/// empty, and the JSON at `attribution` the page's own attribution
/// (`PortableAttributionOptions`), the engine's when empty. Returns 1 when
/// the map is made, 0 with the reason printed when it is not.
@_expose(wasm, "immersivemap_map_start")
@_cdecl("immersivemap_map_start")
func mapStart(_ features: UInt32, _ multisample: Int32,
              _ archive: UnsafePointer<UInt8>?, _ archiveLength: Int32,
              _ poiAtlas: UnsafePointer<UInt8>?, _ poiAtlasLength: Int32,
              _ attribution: UnsafePointer<UInt8>?, _ attributionLength: Int32,
              _ tileWorkers: Int32) -> Int32 {
    PMTilesArchiveClient.hostFetcherMaker = { url, headers in BrowserFetch.fetcher(archiveURL: url, requestHeaders: headers) }
    // The page's workers parse the tiles (BrowserTileWorkers.swift).
    OffThreadTilePreparation.prepare = tileWorkers != 0 ? BrowserTileWorkers.prepare : nil
    var settings = pageSettings(multisample: multisample, archive: archive, archiveLength: archiveLength)
    if let attribution, attributionLength > 0 {
        do {
            let options = try PortableAttributionOptions(json: Data(UnsafeBufferPointer(start: attribution,
                                                                                        count: Int(attributionLength))))
            settings = options.applied(to: settings)
        } catch {
            print("ImmersiveMap: the page's attribution was not read: \(error)")
            return 0
        }
    }
    // Copied before the main actor's closure, which takes no pointer.
    let atlas = poiAtlas.flatMap { pointer in
        poiAtlasLength > 0 ? Array(UnsafeBufferPointer(start: pointer, count: Int(poiAtlasLength))) : nil
    }
    let made = WebGPUDevice.browser(features: GPUDeviceFeatures(rawValue: UInt8(truncatingIfNeeded: features)))
    device = made
    return MainActor.assumeIsolated {
        do {
            map = try PortableMapRenderer(device: made, settings: settings, poiAtlas: atlas)
            return 1
        } catch {
            print("ImmersiveMap: \(error)")
            return 0
        }
    }
}

/// The map's settings on a page: the engine's defaults, MSAA as asked, no
/// prepared-tile disk cache (a page has no disk), no model archive (its
/// textures are ASTC, which most desktop GPUs lack), and the archive at the
/// URL, UTF-8 at `archive`, the engine's own when empty. The map's and a
/// tile worker's alike, so the worker parses under the map's identity: the
/// attribution, which `immersivemap_map_start` adds, is not part of it.
private func pageSettings(multisample: Int32, archive: UnsafePointer<UInt8>?, archiveLength: Int32) -> ImmersiveMapSettings {
    var settings = ImmersiveMapSettings.default.msaa(isEnabled: multisample != 0)
    settings.tiles.cache.preparedTileCacheEnabled = false
    settings.modelArchive.archiveURL = nil
    if let archive, archiveLength > 0,
       let url = URL(string: String(decoding: UnsafeBufferPointer(start: archive, count: Int(archiveLength)), as: UTF8.self)) {
        settings = settings.tileArchive(url)
    }
    return settings
}

/// After running the tasks that are ready, draws a frame into the canvas
/// when one is needed (`PortableMapRenderer.needsFrame`), of its size in
/// pixels, a point being `pixelsPerPoint` of them. Returns bit 1 when the
/// page should ask for another animation frame and bit 2 when a frame was
/// drawn, after which `immersivemap_map_markers` holds the markers' new
/// positions. A frame not needed leaves the canvas's texture untouched,
/// so the page keeps showing the last one.
@_expose(wasm, "immersivemap_map_frame")
@_cdecl("immersivemap_map_frame")
func mapFrame(_ width: Int32, _ height: Int32, _ pixelsPerPoint: Double) -> Int32 {
    runReadyTasks()
    guard let device, width > 0, height > 0 else { return 0 }
    let size = (width: Int(width), height: Int(height))
    return MainActor.assumeIsolated {
        guard let map else { return 0 }
        var drew = false
        if map.needsFrame(width: size.width, height: size.height, pixelsPerPoint: pixelsPerPoint) {
            drew = map.render(into: device.canvasTexture(format: .bgra8Unorm, width: size.width, height: size.height),
                              width: size.width, height: size.height, pixelsPerPoint: pixelsPerPoint)
        }
        let needsAnother = map.needsFrame(width: size.width, height: size.height, pixelsPerPoint: pixelsPerPoint)
        return (needsAnother ? 1 : 0) | (drew ? 2 : 0)
    }
}

/// Places the marker of the page's id at the point, or moves it there.
@_expose(wasm, "immersivemap_map_set_marker")
@_cdecl("immersivemap_map_set_marker")
func mapSetMarker(_ id: UInt32, _ latitude: Double, _ longitude: Double) {
    MainActor.assumeIsolated {
        map?.setMarker(id: UInt64(id), latitudeDegrees: latitude, longitudeDegrees: longitude)
    }
}

/// Takes the marker of the page's id away.
@_expose(wasm, "immersivemap_map_remove_marker")
@_cdecl("immersivemap_map_remove_marker")
func mapRemoveMarker(_ id: UInt32) {
    MainActor.assumeIsolated { map?.removeMarker(id: UInt64(id)) }
}

/// The markers' positions on the last frame drawn
/// (`PortableMapRenderer.markerPositions`), as doubles: their count, then
/// the id, x, y and opacity of each, x and y in points from the canvas's top
/// left corner. A marker beyond the horizon is absent. The memory is the
/// module's and holds until the next call.
@_expose(wasm, "immersivemap_map_markers")
@_cdecl("immersivemap_map_markers")
func mapMarkers() -> UnsafeMutableRawPointer? {
    let positions = MainActor.assumeIsolated { map?.markerPositions ?? [] }
    let count = 1 + positions.count * 4
    let buffer = PageMemory.markers(count: count)
    buffer[0] = Double(positions.count)
    for (index, position) in positions.enumerated() {
        let base = 1 + index * 4
        buffer[base] = Double(position.id)
        buffer[base + 1] = position.x
        buffer[base + 2] = position.y
        buffer[base + 3] = position.alpha
    }
    return UnsafeMutableRawPointer(buffer.baseAddress)
}

/// Sets the pins' picture drawer and remote picture loader, before
/// `immersivemap_map_start`: the drawer where the page has a 2D canvas
/// (`drawsPictures`), the loader where it can fetch and decode a picture
/// (`loadsImages`). Without them a pin's shape other than the bubble is
/// drawn as the bubble, a counter is left out and a remote picture keeps
/// the placeholder.
@_expose(wasm, "immersivemap_pins_start")
@_cdecl("immersivemap_pins_start")
func pinsStart(_ drawsPictures: Int32, _ loadsImages: Int32) {
    BrowserPins.start(drawsPictures: drawsPictures != 0, loadsImages: loadsImages != 0)
}

/// A picture for pins, `width` by `height` pixels of straight RGBA at
/// `rgba` (a canvas's `getImageData`), kept until released. Returns its id,
/// 0 for a size of no pixels. Pins given the same id share the picture.
@_expose(wasm, "immersivemap_pin_picture")
@_cdecl("immersivemap_pin_picture")
func pinPicture(_ width: Int32, _ height: Int32, _ rgba: UnsafePointer<UInt8>?) -> UInt32 {
    guard let rgba, width > 0, height > 0 else { return 0 }
    return BrowserPins.addPicture(width: Int(width), height: Int(height), rgba: rgba)
}

/// Lets go of a picture. Pins that show it keep it until they change.
@_expose(wasm, "immersivemap_pin_picture_release")
@_cdecl("immersivemap_pin_picture_release")
func pinPictureRelease(_ id: UInt32) {
    BrowserPins.pictures[id] = nil
}

/// Places the pin of the page's id, or changes it: at the point, showing
/// the picture of id `picture`, or the picture at the URL, UTF-8 at `url`,
/// with that picture (or the placeholder) until it loads. `badge` is the
/// counter's number, none when 0. `border` is the outline's colour as RGBA
/// bytes, red highest, used when bit 1 of `flags` is set, the settings'
/// otherwise. `scale` sizes the pin, `priority` draws it over pins of less,
/// bit 0 of `flags` draws it as selected. Returns 1 when placed, 0 when the
/// pin has no picture.
@_expose(wasm, "immersivemap_map_set_pin")
@_cdecl("immersivemap_map_set_pin")
func mapSetPin(_ id: UInt32, _ latitude: Double, _ longitude: Double,
               _ picture: UInt32, _ url: UnsafePointer<UInt8>?, _ urlLength: Int32,
               _ badge: Int32, _ border: UInt32, _ scale: Double, _ priority: Int32, _ flags: Int32) -> Int32 {
    let image = BrowserPins.pictures[picture]
    let remote = url.flatMap { url in
        urlLength > 0 ? URL(string: String(decoding: UnsafeBufferPointer(start: url, count: Int(urlLength)), as: UTF8.self)) : nil
    }
    let source: PinImageSource
    if let remote {
        source = .remote(remote, placeholder: image)
    } else if let image {
        source = .image(image)
    } else {
        return 0
    }
    var borderColor: SIMD4<Float>?
    if flags & 2 != 0 {
        borderColor = SIMD4<Float>(Float((border >> 24) & 0xFF), Float((border >> 16) & 0xFF),
                                   Float((border >> 8) & 0xFF), Float(border & 0xFF)) / 255
    }
    let pin = ImmersiveMapPin(id: UInt64(id),
                              coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                              image: source,
                              countBadge: badge > 0 ? PinCountBadge(count: Int(badge)) : nil,
                              borderColor: borderColor,
                              screenSizeScale: Float(scale),
                              isSelected: flags & 1 != 0,
                              drawPriority: Int(priority))
    MainActor.assumeIsolated { map?.pinsController.upsert([pin]) }
    return 1
}

/// Takes the pin of the page's id away.
@_expose(wasm, "immersivemap_map_remove_pin")
@_cdecl("immersivemap_map_remove_pin")
func mapRemovePin(_ id: UInt32) {
    MainActor.assumeIsolated { map?.pinsController.remove(ids: [UInt64(id)]) }
}

/// The page's id of the pin drawn at the point, in points from the
/// canvas's top left corner, on the last frame drawn, -1 where none is.
@_expose(wasm, "immersivemap_map_pin_at")
@_cdecl("immersivemap_map_pin_at")
func mapPinAt(_ x: Double, _ y: Double, _ pixelsPerPoint: Double) -> Double {
    MainActor.assumeIsolated {
        // Converted as a number: `map(Double.init)` takes `init(bitPattern:)`.
        map?.pin(atX: x, y: y, pixelsPerPoint: pixelsPerPoint).map { Double($0) } ?? -1
    }
}

/// The page wants room for a loaded picture (BrowserPins.swift).
@_expose(wasm, "immersivemap_pins_image_buffer")
@_cdecl("immersivemap_pins_image_buffer")
func pinsImageBuffer(_ id: UInt32, _ width: Int32, _ height: Int32) -> UnsafeMutableRawPointer? {
    BrowserPins.imageBuffer(id: id, width: Int(width), height: Int(height))
}

/// The page loaded a picture into the buffer (`loaded` 1) or could not
/// (0), and the tasks it wakes run now.
@_expose(wasm, "immersivemap_pins_image_finish")
@_cdecl("immersivemap_pins_image_finish")
func pinsImageFinish(_ id: UInt32, _ loaded: Int32) {
    BrowserPins.finishImage(id: id, loaded: loaded != 0)
    runReadyTasks()
}

/// A drag of the points. Stops a glide.
@_expose(wasm, "immersivemap_map_pan")
@_cdecl("immersivemap_map_pan")
func mapPan(_ deltaX: Double, _ deltaY: Double) {
    MainActor.assumeIsolated { map?.pan(deltaX: deltaX, deltaY: deltaY) }
}

/// The drag ended, the pointer moving at the velocity in points a second:
/// on the globe, a fast release glides on
/// (`PortableMapRenderer.endPan(velocityX:velocityY:)`).
@_expose(wasm, "immersivemap_map_end_pan")
@_cdecl("immersivemap_map_end_pan")
func mapEndPan(_ velocityX: Double, _ velocityY: Double) {
    MainActor.assumeIsolated { map?.endPan(velocityX: velocityX, velocityY: velocityY) }
}

/// Zooms by the levels, positive in.
@_expose(wasm, "immersivemap_map_zoom")
@_cdecl("immersivemap_map_zoom")
func mapZoom(_ delta: Double) {
    MainActor.assumeIsolated { map?.zoom(delta: delta) }
}

/// Turns the camera by `yaw` and tilts it by `pitch`, in radians.
@_expose(wasm, "immersivemap_map_orbit")
@_cdecl("immersivemap_map_orbit")
func mapOrbit(_ yaw: Double, _ pitch: Double) {
    MainActor.assumeIsolated {
        map?.rotate(yaw: yaw)
        map?.tilt(by: pitch)
    }
}

/// Puts the camera over the point at the zoom.
@_expose(wasm, "immersivemap_map_look")
@_cdecl("immersivemap_map_look")
func mapLook(_ latitude: Double, _ longitude: Double, _ zoom: Double) {
    MainActor.assumeIsolated {
        map?.setCamera(latitudeDegrees: latitude, longitudeDegrees: longitude, zoom: zoom)
    }
}

/// Where the camera is, as five doubles: latitude and longitude in
/// degrees, the zoom, and the bearing and the pitch in radians. The memory
/// is the module's and holds until the next call.
@_expose(wasm, "immersivemap_map_camera")
@_cdecl("immersivemap_map_camera")
func mapCamera() -> UnsafeMutableRawPointer? {
    let position = MainActor.assumeIsolated { map?.cameraPosition }
    guard let position else { return nil }
    let buffer = PageMemory.camera
    buffer[0] = position.latitudeDegrees
    buffer[1] = position.longitudeDegrees
    buffer[2] = position.zoom
    buffer[3] = Double(position.bearing)
    buffer[4] = Double(position.pitch)
    return UnsafeMutableRawPointer(buffer.baseAddress)
}

/// The credits the map's data asks for at the camera's zoom
/// (`PortableMapRenderer.attribution`): the length of its JSON as 4 bytes,
/// little endian, then the JSON in UTF-8. The memory is the module's and
/// holds until the next call. Null before the map is made.
@_expose(wasm, "immersivemap_map_attribution")
@_cdecl("immersivemap_map_attribution")
func mapAttribution() -> UnsafeMutableRawPointer? {
    let json = MainActor.assumeIsolated { map?.attribution.json }
    guard let json else { return nil }
    return UnsafeMutableRawPointer(PageMemory.attribution(json).baseAddress)
}

/// The POI icons' atlas the page draws for `immersivemap_map_start`
/// (`PortableMapRenderer.poiAtlasLayoutDescription`): the length of its
/// JSON as 4 bytes, little endian, then the JSON in UTF-8. The memory is
/// the module's and lasts.
@_expose(wasm, "immersivemap_poi_atlas_layout")
@_cdecl("immersivemap_poi_atlas_layout")
func poiAtlasLayout() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(PageMemory.poiAtlasLayout.baseAddress)
}

/// A tile worker wants room for the entry of a tile it prepared
/// (BrowserTileWorkers.swift).
@_expose(wasm, "immersivemap_tiles_buffer")
@_cdecl("immersivemap_tiles_buffer")
func tilesBuffer(_ id: UInt32, _ length: Int32) -> UnsafeMutableRawPointer? {
    BrowserTileWorkers.buffer(id: id, length: Int(length))
}

/// A tile worker answered, `prepared` 0 when it could not prepare the tile,
/// and the tasks it wakes run now.
@_expose(wasm, "immersivemap_tiles_finish")
@_cdecl("immersivemap_tiles_finish")
func tilesFinish(_ id: UInt32, _ prepared: Int32) {
    BrowserTileWorkers.finish(id: id, prepared: prepared != 0)
    runReadyTasks()
}

/// What became of the tiles handed to the workers
/// (`OffThreadTilePreparation.counts`), as three doubles: accepted,
/// refused and failed. The memory is the module's and holds until the next
/// call.
@_expose(wasm, "immersivemap_tiles_counts")
@_cdecl("immersivemap_tiles_counts")
func tilesCounts() -> UnsafeMutableRawPointer? {
    let counts = OffThreadTilePreparation.counts
    let buffer = PageMemory.tileCounts
    buffer[0] = Double(counts.accepted)
    buffer[1] = Double(counts.refused)
    buffer[2] = Double(counts.failed)
    return UnsafeMutableRawPointer(buffer.baseAddress)
}

// MARK: - A tile worker

/// Starts this module as a tile worker, not a map: it parses the tiles of
/// the map started with the same `multisample` and archive
/// (`pageSettings`), with the font metrics from the resources folder.
/// Returns 1.
@_expose(wasm, "immersivemap_worker_start")
@_cdecl("immersivemap_worker_start")
func workerStart(_ multisample: Int32, _ archive: UnsafePointer<UInt8>?, _ archiveLength: Int32) -> Int32 {
    let settings = pageSettings(multisample: multisample, archive: archive, archiveLength: archiveLength)
    PageMemory.preparer = PortableTilePreparer(settings: settings)
    return 1
}

/// The tile at `x`, `y`, `z`, from its `length` bytes at `data`, parsed and
/// encoded as a prepared-tile entry (`PortableTilePreparer.prepare`): the
/// entry's length as 4 bytes, little endian, then the entry. Null when the
/// tile does not parse or the worker is not started. The memory is the
/// module's and holds until the next call.
@_expose(wasm, "immersivemap_worker_prepare")
@_cdecl("immersivemap_worker_prepare")
func workerPrepare(_ x: Int32, _ y: Int32, _ z: Int32, _ data: UnsafePointer<UInt8>?, _ length: Int32) -> UnsafeMutableRawPointer? {
    guard let preparer = PageMemory.preparer, let data, length >= 0,
          let entry = preparer.prepare(x: Int(x), y: Int(y), z: Int(z),
                                       data: Data(UnsafeBufferPointer(start: data, count: Int(length)))) else {
        return nil
    }
    return UnsafeMutableRawPointer(PageMemory.workerEntry(entry).baseAddress)
}

/// The page's `fetch` wants room for the answer of a request
/// (BrowserFetch.swift).
@_expose(wasm, "immersivemap_fetch_buffer")
@_cdecl("immersivemap_fetch_buffer")
func fetchBuffer(_ id: UInt32, _ kind: Int32, _ length: Int32) -> UnsafeMutableRawPointer? {
    BrowserFetch.buffer(id: id, kind: kind, length: Int(length))
}

/// The page's `fetch` answered a request, and the tasks it wakes run now.
@_expose(wasm, "immersivemap_fetch_finish")
@_cdecl("immersivemap_fetch_finish")
func fetchFinish(_ id: UInt32, _ status: Int32) {
    BrowserFetch.finish(id: id, status: status)
    runReadyTasks()
}

/// Runs the jobs the executors hold that are due, a few passes, so the
/// jobs those wake run too. A pass that finds only timers not yet due
/// sleeps until the first, which on a page returns at once (the WASI shim
/// has no `poll_oneoff`), so this never blocks the page.
private func runReadyTasks() {
    var executors: [any RunLoopExecutor] = [MainActor.executor]
    if let global = Task.defaultExecutor as? any RunLoopExecutor,
       (global as AnyObject) !== (MainActor.executor as AnyObject) {
        executors.append(global)
    }
    for executor in executors {
        var passes = 0
        try? executor.runUntil {
            passes += 1
            return passes > 4
        }
    }
}
#endif
