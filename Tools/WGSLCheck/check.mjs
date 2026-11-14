// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// Compiles every WGSL shader of the engine with Dawn, the WebGPU of
// Chrome, run in Node: `npm ci && node check.mjs` here. Each file is
// compiled with its includes in front (wgsl.mjs), and a message names the
// source file and line. Then it builds every pipeline of pipelines.json,
// the ported features' pipelines as the engine describes them
// (WGSLPipelineManifestTests writes it), against the WGSL entry points, so
// an override left unset, a vertex format the shader cannot read or a
// binding used twice by one entry point fails here. Exits 1 on any error.
// Needs a GPU adapter: a Vulkan driver, or a software one (lavapipe) on a
// machine without a GPU.

import { create, globals } from 'webgpu';
import { readFileSync } from 'node:fs';
import { join, relative } from 'node:path';
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
// The engine's depth target is depth32float-stencil8, and the casters
// clamp their depth (unclippedDepth): both optional in WebGPU.
const wanted = ['depth32float-stencil8', 'depth-clip-control'];
const missing = wanted.filter((feature) => !adapter.features.has(feature));
if (missing.length > 0) {
    console.error(`The adapter lacks ${missing.join(', ')}, which the engine's pipelines need.`);
    process.exit(2);
}
const device = await adapter.requestDevice({ requiredFeatures: wanted });
const info = adapter.info ?? {};
console.log(`adapter: ${[info.vendor, info.architecture, info.description].filter(Boolean).join(' ')}`);

let errors = 0;
const modules = new Map();
for (const path of wgslFiles()) {
    const { code, origins } = compose(path);
    device.pushErrorScope('validation');
    const module = device.createShaderModule({ code, label: relative(repositoryRoot, path) });
    modules.set(path, { module, code });
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
// The pipelines: each entry point is taken from the file that declares it.
function moduleDeclaring(entryPoint) {
    for (const [path, { module, code }] of modules) {
        const own = readFileSync(path, 'utf8');
        if (new RegExp(`\\bfn ${entryPoint}\\(`).test(own)) return { path, module };
    }
    return null;
}

const manifest = JSON.parse(readFileSync(join(repositoryRoot, 'Tools', 'WGSLCheck', 'pipelines.json'), 'utf8'));
for (const pipeline of manifest.pipelines) {
    const vertexModule = moduleDeclaring(pipeline.vertex.entryPoint);
    const fragmentModule = pipeline.fragment ? moduleDeclaring(pipeline.fragment.entryPoint) : null;
    if (!vertexModule || (pipeline.fragment && !fragmentModule)) {
        console.error(`${pipeline.label}: an entry point is in no WGSL file`);
        errors += 1;
        continue;
    }
    const descriptor = {
        label: pipeline.label,
        layout: 'auto',
        vertex: {
            module: vertexModule.module,
            entryPoint: pipeline.vertex.entryPoint,
            constants: pipeline.vertex.constants,
            buffers: pipeline.buffers,
        },
        primitive: { topology: pipeline.topology },
        multisample: { count: pipeline.sampleCount },
    };
    if (pipeline.fragment) {
        descriptor.fragment = {
            module: fragmentModule.module,
            entryPoint: pipeline.fragment.entryPoint,
            constants: pipeline.fragment.constants,
            targets: pipeline.targets.map((target) => ({
                format: target.format,
                blend: target.blend ?? undefined,
                writeMask: target.writesColor ? GPUColorWrite.ALL : 0,
            })),
        };
    }
    if (pipeline.depthStencilFormat) {
        // The depth state is set per draw (GPURenderStateTracker), so any
        // valid one builds the pipeline.
        descriptor.depthStencil = { format: pipeline.depthStencilFormat, depthWriteEnabled: false, depthCompare: 'always' };
    }
    // A pipeline the device refuses rejects the call, and a validation
    // error the call does not throw lands in the scope: either fails it.
    device.pushErrorScope('validation');
    let failure = null;
    try {
        await device.createRenderPipelineAsync(descriptor);
    } catch (error) {
        failure = error.message;
    }
    const scope = await device.popErrorScope();
    failure ??= scope?.message ?? null;
    if (failure) {
        console.error(`pipeline ${pipeline.label} (${relative(repositoryRoot, vertexModule.path)}): ${failure}`);
        errors += 1;
    } else {
        console.log(`ok pipeline ${pipeline.label}`);
    }
}

device.destroy();
process.exit(errors > 0 ? 1 : 0);
