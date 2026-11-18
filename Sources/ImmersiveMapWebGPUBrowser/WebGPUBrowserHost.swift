// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// The backend in a browser: the module hands each submission's stream to
// the page's host (Web/ImmersiveMapWebGPU.js) through one import, and the
// host calls one export back when the queue has finished a submission. The
// page gives the import as `immersivemap_webgpu.submit`, reading the stream
// out of the module's memory during the call.

#if arch(wasm32)
import ImmersiveMapGPU
import ImmersiveMapWebGPU

@_extern(wasm, module: "immersivemap_webgpu", name: "submit")
private func hostSubmit(_ stream: UnsafeRawPointer?, _ length: Int32)

/// Hands each submission to the page's host, one call a submission.
private final class WebGPUBrowserSink: WebGPUCommandSink, @unchecked Sendable {
    func submit(_ stream: UnsafeRawBufferPointer) {
        hostSubmit(stream.baseAddress, Int32(stream.count))
    }
}

/// The device of the page, which the host's completions go to. A page has
/// one: WebAssembly in a browser runs on the page's one thread.
nonisolated(unsafe) private var browserDevice: WebGPUDevice?

extension WebGPUDevice {
    /// The device that draws through the page's host. Made once: a second
    /// call gives the first device.
    /// - Parameter features: what the page's WebGPU device offers of the
    ///   optional features the engine uses.
    package static func browser(features: GPUDeviceFeatures) -> WebGPUDevice {
        if let browserDevice {
            return browserDevice
        }
        let device = WebGPUDevice(features: features, sink: WebGPUBrowserSink())
        browserDevice = device
        return device
    }
}

/// Called by the host once the queue has finished a submission.
@_expose(wasm, "immersivemap_webgpu_completed")
@_cdecl("immersivemap_webgpu_completed")
func immersiveMapWebGPUCompleted(_ id: UInt32) {
    browserDevice?.commandBufferCompleted(id)
}
#endif
