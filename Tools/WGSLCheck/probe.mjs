// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// Runs the browser probe headless: the ImmersiveMapWebProbe module, as
// Web/probe/build.sh builds it, loaded as the page loads it
// (Web/probe/probe.mjs), drawing a few frames on Dawn into an offscreen
// canvas. `node probe.mjs [module.wasm]` here, after `npm ci`. Fails on any
// WebGPU validation error or a trap in the module. Looks at no pixel: the
// page is judged in a browser.

import { create, globals } from 'webgpu';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { repositoryRoot } from './wgsl.mjs';
import { shaderBundle } from './reflect.mjs';

Object.assign(globalThis, globals);
const { chooseFeatures } = await import(join(repositoryRoot, 'Web', 'ImmersiveMapWebGPU.js'));
const { startProbe } = await import(join(repositoryRoot, 'Web', 'probe', 'probe.mjs'));

const path = process.argv[2] ?? join(repositoryRoot, 'Web', 'probe', 'build', 'ImmersiveMapWebProbe.wasm');
const gpu = create([]);
const adapter = await gpu.requestAdapter();
if (!adapter) {
    console.error('No WebGPU adapter: install a Vulkan driver, or lavapipe for a software one.');
    process.exit(2);
}
const device = await adapter.requestDevice({ requiredFeatures: chooseFeatures(adapter) });
const errors = [];
device.addEventListener('uncapturederror', (event) => errors.push(event.error.message));

const size = [96, 64];
const canvas = device.createTexture({ size, format: 'bgra8unorm', usage: GPUTextureUsage.RENDER_ATTACHMENT, label: 'canvas' });
const notes = [];
let probe = null;
try {
    probe = await startProbe({
        device,
        module: await WebAssembly.compile(readFileSync(path)),
        shaders: shaderBundle(),
        canvasTexture: () => canvas,
        warn: (message) => notes.push(message),
    });
    for (let frame = 0; frame < 3; frame += 1) {
        probe.frame(size[0], size[1], frame * 0.1);
        await device.queue.onSubmittedWorkDone();
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
} catch (error) {
    errors.push(`probe: ${error.stack ?? error.message}`);
}

for (const note of notes) console.log(`note: ${note}`);
for (const error of errors) console.error(error);
if (probe) {
    console.log(Object.entries(probe.host.counts).map(([key, value]) => `${value} ${key}`).join(', '));
}
canvas.destroy();
device.destroy();
process.exit(errors.length > 0 ? 1 : 0);
