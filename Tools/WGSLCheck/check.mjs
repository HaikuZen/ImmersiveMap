// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// Compiles every WGSL shader of the engine with Dawn, the WebGPU of
// Chrome, run in Node: `npm ci && node check.mjs` here. Each file is
// compiled with its includes in front (wgsl.mjs), and a message names the
// source file and line. Exits 1 on any error. Needs a GPU adapter: a
// Vulkan driver, or a software one (lavapipe) on a machine without a GPU.

import { create, globals } from 'webgpu';
import { relative } from 'node:path';
import { compose, repositoryRoot, wgslFiles } from './wgsl.mjs';

Object.assign(globalThis, globals);
// The instance is kept for the whole run: dropped, it is collected while
// the adapter and the device still use it, and Node crashes.
const gpu = create([]);
const adapter = await gpu.requestAdapter();
if (!adapter) {
    console.error('No WebGPU adapter: install a Vulkan driver, or lavapipe for a software one.');
    process.exit(2);
}
const device = await adapter.requestDevice();

let errors = 0;
for (const path of wgslFiles()) {
    const { code, origins } = compose(path);
    device.pushErrorScope('validation');
    const module = device.createShaderModule({ code, label: relative(repositoryRoot, path) });
    const info = await module.getCompilationInfo();
    const scope = await device.popErrorScope();
    const messages = info.messages.filter((message) => message.type !== 'info');
    for (const message of messages) {
        const origin = origins[message.lineNum - 1] ?? { file: relative(repositoryRoot, path), line: message.lineNum };
        console.error(`${origin.file}:${origin.line}:${message.linePos}: ${message.type}: ${message.message}`);
        if (message.type === 'error') errors += 1;
    }
    if (scope && messages.length === 0) {
        console.error(`${relative(repositoryRoot, path)}: ${scope.message}`);
        errors += 1;
    }
    if (messages.every((message) => message.type !== 'error') && !scope) {
        console.log(`ok ${relative(repositoryRoot, path)}`);
    }
}
device.destroy();
process.exit(errors > 0 ? 1 : 0);
