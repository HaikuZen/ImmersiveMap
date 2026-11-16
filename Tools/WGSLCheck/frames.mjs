// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// Runs the frames of Web/test/frames/ on Dawn through the WebGPU backend's
// host (Web/ImmersiveMapWebGPU.js): `node frames.mjs` here, after
// `npm ci`. Each frame is the command stream the engine writes for moved
// features (WebGPUFrameStreamTests writes them), run as a browser would run
// it, into an offscreen canvas texture. Fails on any WebGPU validation
// error, which names the pipeline, the bind group or the pass WebGPU
// refused. Looks at no pixel: the frames are judged in a browser.

import { create, globals } from 'webgpu';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { repositoryRoot } from './wgsl.mjs';
import { shaderBundle } from './reflect.mjs';

Object.assign(globalThis, globals);
const { ImmersiveMapWebGPUHost, chooseFeatures } = await import(join(repositoryRoot, 'Web', 'ImmersiveMapWebGPU.js'));

const gpu = create([]);
const adapter = await gpu.requestAdapter();
if (!adapter) {
    console.error('No WebGPU adapter: install a Vulkan driver, or lavapipe for a software one.');
    process.exit(2);
}
const device = await adapter.requestDevice({ requiredFeatures: chooseFeatures(adapter) });
const errors = [];
device.addEventListener('uncapturederror', (event) => errors.push(event.error.message));

const shaders = shaderBundle();
const framesDirectory = join(repositoryRoot, 'Web', 'test', 'frames');
let failed = 0;
for (const name of readdirSync(framesDirectory).filter((file) => file.endsWith('.bin')).sort()) {
    const canvas = device.createTexture({ size: [64, 64], format: 'bgra8unorm', usage: GPUTextureUsage.RENDER_ATTACHMENT, label: 'canvas' });
    const warnings = [];
    const completedIDs = [];
    errors.length = 0;
    let host = null;
    try {
        host = new ImmersiveMapWebGPUHost({
            device,
            shaders,
            canvasTexture: () => canvas,
            completed: (id) => completedIDs.push(id),
            warn: (message) => warnings.push(message),
        });
        host.submit(new Uint8Array(readFileSync(join(framesDirectory, name))));
        await device.queue.onSubmittedWorkDone();
        await new Promise((resolve) => setTimeout(resolve, 50));
    } catch (error) {
        errors.push(`host: ${error.stack ?? error.message}`);
    }
    for (const warning of warnings) console.log(`${name}: note: ${warning}`);
    if (errors.length > 0) {
        failed += 1;
        for (const error of errors) console.error(`${name}: ${error}`);
    } else {
        const counts = Object.entries(host?.counts ?? {}).map(([key, value]) => `${value} ${key}`).join(', ');
        console.log(`ok ${name}: ${counts}, ${completedIDs.length} completed`);
    }
    canvas.destroy();
}

device.destroy();
process.exit(failed > 0 ? 1 : 0);
