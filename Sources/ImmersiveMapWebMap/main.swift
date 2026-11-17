// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// The map in a browser, for Web/map/: the engine (`PortableMapRenderer`)
// drawing through the WebGPU backend and the page's host, its archives read
// through the page's `fetch` (BrowserFetch.swift). A WebAssembly reactor:
// the page calls `_initialize`, then `immersivemap_map_start` once,
// `immersivemap_map_frame` every animation frame and the camera's exports
// on input. Nothing here runs off WebAssembly, where the target builds
// empty.
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
/// MSAA 4x, and the archive's URL, UTF-8 at `archive`, is the tile source, the
/// engine's own when empty. Returns 1 when the map is made.
@_expose(wasm, "immersivemap_map_start")
@_cdecl("immersivemap_map_start")
func mapStart(_ features: UInt32, _ multisample: Int32, _ archive: UnsafePointer<UInt8>?, _ archiveLength: Int32) -> Int32 {
    PMTilesArchiveClient.hostFetcherMaker = { url, headers in BrowserFetch.fetcher(archiveURL: url, requestHeaders: headers) }
    var settings = ImmersiveMapSettings.default.msaa(isEnabled: multisample != 0)
    // A page has no disk the prepared tiles could be kept on.
    settings.tiles.cache.preparedTileCacheEnabled = false
    // The model tiles' textures are ASTC, which most desktop GPUs lack.
    settings.modelArchive.archiveURL = nil
    if let archive, archiveLength > 0,
       let url = URL(string: String(decoding: UnsafeBufferPointer(start: archive, count: Int(archiveLength)), as: UTF8.self)) {
        settings = settings.tileArchive(url)
    }
    let made = WebGPUDevice.browser(features: GPUDeviceFeatures(rawValue: UInt8(truncatingIfNeeded: features)))
    device = made
    return MainActor.assumeIsolated {
        do {
            map = try PortableMapRenderer(device: made, settings: settings)
            return 1
        } catch {
            print("ImmersiveMap: \(error)")
            return 0
        }
    }
}

/// Draws one frame into the canvas, of its size in pixels, a point being
/// `pixelsPerPoint` of them, after running the tasks that are ready.
@_expose(wasm, "immersivemap_map_frame")
@_cdecl("immersivemap_map_frame")
func mapFrame(_ width: Int32, _ height: Int32, _ pixelsPerPoint: Double) {
    runReadyTasks()
    guard let device, width > 0, height > 0 else { return }
    MainActor.assumeIsolated {
        _ = map?.render(into: device.canvasTexture(format: .bgra8Unorm, width: Int(width), height: Int(height)),
                        width: Int(width), height: Int(height), pixelsPerPoint: pixelsPerPoint)
    }
}

/// A drag of the points, `ended` 1 when the pointer is up.
@_expose(wasm, "immersivemap_map_pan")
@_cdecl("immersivemap_map_pan")
func mapPan(_ deltaX: Double, _ deltaY: Double, _ ended: Int32) {
    MainActor.assumeIsolated {
        map?.pan(deltaX: deltaX, deltaY: deltaY)
        if ended != 0 {
            map?.endPan()
        }
    }
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
