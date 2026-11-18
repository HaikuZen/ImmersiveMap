// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// Runs the map page's module headless: ImmersiveMapWebMap, as
// Web/map/build.sh builds it, loaded as the page loads it (Web/map/map.mjs)
// and drawing frames on Dawn into an offscreen canvas. No network: the tile
// archive is the overview archive the engine ships, its ranges answered
// from the file, so the tiles travel the whole path from `fetch` to the
// GPU. `node map.mjs [module.wasm]` here, after `npm ci`. Fails on any
// WebGPU validation error, a trap in the module, no request reaching the
// archive, a camera not read back where it was put, a first frame not
// drawn, a marker at the camera's centre not placed at the canvas's
// centre, or the tile cache (in memory here) not answering a second load
// or keeping ranges of an archive replaced. Looks at no pixel: the page is judged in a
// browser.

import { create, globals } from 'webgpu';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { repositoryRoot } from './wgsl.mjs';
import { shaderBundle } from './reflect.mjs';

Object.assign(globalThis, globals);
const { chooseFeatures } = await import(join(repositoryRoot, 'Web', 'ImmersiveMapWebGPU.js'));
const { startMap } = await import(join(repositoryRoot, 'Web', 'map', 'map.mjs'));
const { ArchiveRangeCache, MemoryStore } = await import(join(repositoryRoot, 'Web', 'map', 'rangeCache.mjs'));

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
// The archive's version on its host, changed to replace it.
let archiveETag = '"overview"';
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
        headers: { 'Content-Range': `bytes ${start}-${Number(start) + body.length - 1}/${archive.length}`, ETag: archiveETag },
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
const frames = { drawn: 0 };
const cache = new ArchiveRangeCache(new MemoryStore(), { warn: (message) => notes.push(message) });
const loads = [];
try {
    const options = {
        device,
        module: await WebAssembly.compile(readFileSync(path)),
        shaders: shaderBundle(),
        resources,
        canvasTexture: () => canvas,
        archiveURL,
        fetch: localFetch,
        warn: (message) => notes.push(message),
        print: (stream, line) => output.push(`${stream === 2 ? 'stderr' : 'stdout'}: ${line}`),
        rangeCache: cache,
    };
    map = await startMap(options);
    map.look(45.46, 9.19, 5);
    const camera = map.camera();
    if (!camera || Math.abs(camera.latitude - 45.46) > 1e-6 || Math.abs(camera.longitude - 9.19) > 1e-6 || Math.abs(camera.zoom - 5) > 1e-6) {
        errors.push(`map: the camera reads back as ${JSON.stringify(camera)}, not where it was put`);
    }
    // A marker where the camera looks, and one on the far side of the globe.
    map.setMarker(1, 45.46, 9.19);
    map.setMarker(2, -45.46, -170.81);
    // Frames with the event loop turning between them, so the requests'
    // answers and the GPU's completions arrive as on a page. Every one is
    // offered, as a page that keeps asking would: a frame not needed draws
    // nothing.
    for (let frame = 0; frame < 90; frame += 1) {
        const { drew } = map.frame(size[0], size[1], 1);
        if (drew) frames.drawn += 1;
        if (frame === 0) {
            if (!drew) errors.push('map: the first frame was not drawn');
            const places = map.markers();
            const centre = places.find((place) => place.id === 1);
            if (!centre || Math.abs(centre.x - size[0] / 2) > 1 || Math.abs(centre.y - size[1] / 2) > 1) {
                errors.push(`map: the marker at the camera's centre is at ${JSON.stringify(centre)}, not the canvas's centre`);
            }
            if (places.some((place) => place.id === 2)) errors.push('map: a marker beyond the horizon was placed');
        }
        if (frame === 30) {
            // A fast release: the globe glides on through the next frames.
            map.pan(40, 10);
            map.endPan(1500, 300);
        }
        if (frame === 50) map.zoom(1);
        if (frame === 60) map.orbit(0.3, 0.4);
        if (frame === 70) map.removeMarker(1);
        await device.queue.onSubmittedWorkDone();
        await new Promise((resolve) => setTimeout(resolve, 5));
    }
    if (map.markers().some((place) => place.id === 1)) errors.push('map: a removed marker is still placed');

    // A page loaded again: another map over the same cache, looking where
    // the first one started, its requests counted.
    const load = async () => {
        const before = { network: requests.archive, hits: cache.counts.hits };
        const again = await startMap(options);
        again.look(45.46, 9.19, 5);
        for (let frame = 0; frame < 20; frame += 1) {
            again.frame(size[0], size[1], 1);
            await device.queue.onSubmittedWorkDone();
            await new Promise((resolve) => setTimeout(resolve, 5));
        }
        const counts = { network: requests.archive - before.network, cached: cache.counts.hits - before.hits };
        loads.push(counts);
        return counts;
    };
    if (cache.counts.stored === 0) errors.push('map: the tile cache kept no range');
    const second = await load();
    if (second.cached === 0) errors.push('map: a second load read no range from the tile cache');
    // The header always goes to the network.
    if (second.network === 0) errors.push('map: a second load read the archive\'s header from the tile cache');
    // The archive replaced on its host: what the cache holds is dropped.
    archiveETag = '"overview-replaced"';
    await load();
    if (cache.counts.dropped !== 1) errors.push(`map: a replaced archive dropped ${cache.counts.dropped} times from the tile cache, not once`);
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
    console.log(`${requests.archive} archive requests, ${requests.other} refused, ${frames.drawn} of 90 frames drawn`);
    console.log(`tile cache: ${cache.counts.stored} stored, ${cache.counts.hits} answered, ${cache.counts.dropped} dropped; `
        + `loads again: ${loads.map(({ network, cached }) => `${network} from the network and ${cached} from the cache`).join(', then ')}`);
}
canvas.destroy();
device.destroy();
process.exit(errors.length > 0 ? 1 : 0);
