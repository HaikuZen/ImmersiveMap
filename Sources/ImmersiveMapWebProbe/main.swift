// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// The browser probe: the WebGPU backend drawing the probe scene
// (`GPUProbeScene`) through the page's host, for Web/probe/. A WebAssembly
// reactor: the page calls `_initialize`, then `immersivemap_probe_start`
// once and `immersivemap_probe_frame` every animation frame. Nothing here
// runs off WebAssembly, where the target builds empty.

#if arch(wasm32)
import ImmersiveMap
import ImmersiveMapGPU
import ImmersiveMapWebGPU
import ImmersiveMapWebGPUBrowser

nonisolated(unsafe) private var device: WebGPUDevice?
nonisolated(unsafe) private var scene: GPUProbeScene?

/// Makes the device and the scene. `features` is `GPUDeviceFeatures`'
/// raw value for what the page's WebGPU device offers. Returns 1 when the
/// scene is made.
@_expose(wasm, "immersivemap_probe_start")
@_cdecl("immersivemap_probe_start")
func probeStart(_ features: UInt32) -> Int32 {
    let made = WebGPUDevice.browser(features: GPUDeviceFeatures(rawValue: UInt8(truncatingIfNeeded: features)))
    device = made
    scene = GPUProbeScene(device: made)
    return scene == nil ? 0 : 1
}

/// Draws one frame into the canvas, of the canvas's size in pixels, the
/// globe turned by `turn`.
@_expose(wasm, "immersivemap_probe_frame")
@_cdecl("immersivemap_probe_frame")
func probeFrame(_ width: Int32, _ height: Int32, _ turn: Float) {
    guard let device, let scene, width > 0, height > 0 else { return }
    scene.drawFrame(into: device.canvasTexture(format: .bgra8Unorm, width: Int(width), height: Int(height)),
                    width: Int(width), height: Int(height), turn: turn)
}
#endif
