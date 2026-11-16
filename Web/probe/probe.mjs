// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// Loads the browser probe (the ImmersiveMapWebProbe module) onto a WebGPU
// device: the module, the page's host of the backend and the WASI shim
// wired together. The page (index.html) and the headless run
// (Tools/WGSLCheck/probe.mjs) both start it here.

import { ImmersiveMapWebGPUHost } from '../ImmersiveMapWebGPU.js';
import { WASIShim } from '../WASIShim.js';

/// GPUDeviceFeatures' raw value for the device's features.
function engineFeatures(device) {
    let features = 0;
    if (device.features.has('texture-compression-astc')) features |= 1;
    if (device.features.has('depth-clip-control')) features |= 2;
    return features;
}

/// - module: the compiled WebAssembly module.
/// - shaders: the bundle of Tools/WGSLCheck/bundle.mjs.
/// - canvasTexture: the frame's drawable.
/// Returns the host and `frame(width, height, turn)`, which draws a frame.
export async function startProbe({ device, module, shaders, canvasTexture, warn = console.warn, print }) {
    const wasi = new WASIShim({ print });
    let host = null;
    let memory = null;
    const instance = await WebAssembly.instantiate(module, {
        ...wasi.imports,
        immersivemap_webgpu: {
            submit(pointer, length) {
                host.submit(new Uint8Array(memory.buffer, pointer, length));
            },
        },
    });
    memory = instance.exports.memory;
    wasi.bind(instance);
    host = new ImmersiveMapWebGPUHost({
        device,
        shaders,
        canvasTexture,
        completed: (id) => instance.exports.immersivemap_webgpu_completed(id),
        warn,
    });
    instance.exports._initialize();
    if (instance.exports.immersivemap_probe_start(engineFeatures(device)) !== 1) {
        throw new Error('The probe could not make its scene');
    }
    return {
        host,
        frame: (width, height, turn) => instance.exports.immersivemap_probe_frame(width, height, turn),
    };
}
