// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// Runs the map page's module headless: ImmersiveMapWebMap, as
// Web/map/build.sh builds it, loaded as the page loads it (Web/map/map.mjs)
// and drawing frames on Dawn into an offscreen canvas. No network: the tile
// archive is the overview archive the engine ships, its ranges answered
// from the file, so the tiles travel the whole path from `fetch` to the
// GPU. `node map.mjs [module.wasm]` here, after `npm ci`. Fails on any
// WebGPU validation error, a trap in the module, or no request reaching
// the archive. Looks at no pixel: the page is judged in a browser.

import { create, globals } from 'webgpu';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { repositoryRoot } from './wgsl.mjs';
import { shaderBundle } from './reflect.mjs';

Object.assign(globalThis, globals);
const { chooseFeatures } = await import(join(repositoryRoot, 'Web', 'ImmersiveMapWebGPU.js'));
const { startMap } = await import(join(repositoryRoot, 'Web', 'map', 'map.mjs'));

const engine = join(repositoryRoot, 'Sources', 'ImmersiveMap');
const path = process.argv[2] ?? join(repositoryRoot, 'Web', 'map', 'build', 'ImmersiveMapWebMap.wasm');
const archivePath = join(engine, 'Tile', 'Overview', 'Resources', 'overview.pmtiles');
const archiveURL = 'https://archive.invalid/overview.pmtiles';

// The resources build.sh copies, read where they are.
const resources = new Map();
for (const name of readdirSync(join(engine, 'Text', 'Resources'))) {
    resources.set(name, readFileSync(join(engine, 'Text', 'Resources', name)));
}
resources.set('overview.pmtiles', readFileSync(archivePath));
resources.set('tree_broadleaf.immtree', readFileSync(join(engine, 'Tile', 'Trees', 'Resources', 'tree_broadleaf.immtree')));

// The archive's ranges from the file. Any other URL has no network.
const archive = readFileSync(archivePath);
const requests = { archive: 0, other: 0 };
async function localFetch(url, { headers }) {
    if (url !== archiveURL) {
        requests.other += 1;
        throw new Error(`no network in the headless run: ${url}`);
    }
    requests.archive += 1;
    const [, start, end] = /bytes=(\d+)-(\d+)/.exec(headers.get('Range'));
    const body = archive.subarray(Number(start), Math.min(Number(end) + 1, archive.length));
    return new Response(body, {
        status: 206,
        headers: { 'Content-Range': `bytes ${start}-${Number(start) + body.length - 1}/${archive.length}`, ETag: '"overview"' },
    });
}

const gpu = create([]);
const adapter = await gpu.requestAdapter();
if (!adapter) {
    console.error('No WebGPU adapter: install a Vulkan driver, or lavapipe for a software one.');
    process.exit(2);
}
const device = await adapter.requestDevice({ requiredFeatures: chooseFeatures(adapter) });
const errors = [];
device.addEventListener('uncapturederror', (event) => errors.push(event.error.message));

const size = [160, 120];
const canvas = device.createTexture({ size, format: 'bgra8unorm', usage: GPUTextureUsage.RENDER_ATTACHMENT, label: 'canvas' });
const notes = [];
const output = [];
let map = null;
try {
    map = await startMap({
        device,
        module: await WebAssembly.compile(readFileSync(path)),
        shaders: shaderBundle(),
        resources,
        canvasTexture: () => canvas,
        archiveURL,
        fetch: localFetch,
        warn: (message) => notes.push(message),
        print: (stream, line) => output.push(`${stream === 2 ? 'stderr' : 'stdout'}: ${line}`),
    });
    map.look(45.46, 9.19, 5);
    // Frames with the event loop turning between them, so the requests'
    // answers and the GPU's completions arrive as on a page.
    for (let frame = 0; frame < 90; frame += 1) {
        map.frame(size[0], size[1], 1);
        if (frame === 30) map.pan(40, 10, true);
        if (frame === 50) map.zoom(1);
        if (frame === 60) map.orbit(0.3, 0.4);
        await device.queue.onSubmittedWorkDone();
        await new Promise((resolve) => setTimeout(resolve, 5));
    }
} catch (error) {
    errors.push(`map: ${error.stack ?? error.message}`);
}
if (map && requests.archive === 0) errors.push('map: no request reached the tile archive');

for (const line of output.slice(-20)) console.log(line);
for (const note of notes) console.log(`note: ${note}`);
for (const error of errors.slice(0, 20)) console.error(error);
if (errors.length > 20) console.error(`… and ${errors.length - 20} more errors`);
if (map) {
    console.log(Object.entries(map.host.counts).map(([key, value]) => `${value} ${key}`).join(', '));
    console.log(`${requests.archive} archive requests, ${requests.other} refused`);
}
canvas.destroy();
device.destroy();
process.exit(errors.length > 0 ? 1 : 0);
