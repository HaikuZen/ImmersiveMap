// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// Loads the map (the ImmersiveMapWebMap module) onto a WebGPU device: the
// module, the page's host of the backend, the WASI shim with the engine's
// resources as a folder, and the archives' range requests answered with
// `fetch`. The page (index.html) and the headless run
// (Tools/WGSLCheck/map.mjs) both start it here.

import { ImmersiveMapWebGPUHost } from '../ImmersiveMapWebGPU.js';
import { WASIShim } from '../WASIShim.js';

/// Where the module finds the resources: the folder and the variable the
/// engine reads its location from (`ImmersiveMapResourceBundle`).
const resourceFolder = '/resources';

/// GPUDeviceFeatures' raw value for the device's features.
function engineFeatures(device) {
    let features = 0;
    if (device.features.has('texture-compression-astc')) features |= 1;
    if (device.features.has('depth-clip-control')) features |= 2;
    return features;
}

/// One range request with the page's `fetch`: the status, the response's
/// headers as `name: value` lines, and its body.
async function fetchRange({ url, headers, start, end }, fetchFunction) {
    const request = new Headers(headers);
    request.set('Range', `bytes=${start}-${end - 1}`);
    const response = await fetchFunction(url, { headers: request, cache: 'no-store' });
    const lines = [];
    response.headers.forEach((value, name) => lines.push(`${name}: ${value}`));
    return { status: response.status, headers: lines.join('\n'), body: new Uint8Array(await response.arrayBuffer()) };
}

/// - module: the compiled WebAssembly module.
/// - shaders: the bundle of Tools/WGSLCheck/bundle.mjs.
/// - resources: the engine's resource files, a Map of name to bytes.
/// - canvasTexture: the frame's drawable.
/// - archiveURL: the tile archive, the engine's own when empty.
/// - fetch: what the requests go through, the page's `fetch` by default.
/// - wake: called when the map may need a frame it did not ask for at the
///   last one (a camera move, a marker, a request answered), so a page that
///   stopped asking for animation frames asks again.
/// - downloadFailed: called with `downloads` after each failed request.
/// - rangeCache: an `ArchiveRangeCache` (rangeCache.mjs) the archives'
///   requests go through, none by default.
/// - attribution: the page's own credits for the badge, as the class takes
///   them (ImmersiveMap.d.ts, `AttributionOptions`), the engine's when null.
/// - tileWorkers: the workers that parse the tiles off the page's thread,
///   each tileWorker.mjs behind `{ send(message, transfer), listen(handler) }`,
///   none by default, when the tiles are parsed on the page's thread.
/// - drawPoiIcons: given the POI icons' atlas layout the module describes,
///   returns the atlas's pixels (`drawPoiAtlas` of poiIcons.mjs) or null
///   for no icons, the default.
/// Returns:
/// - `frame(width, height, pixelsPerPoint)`, which runs what the module has
///   ready and draws a frame only when one is needed. It returns
///   `{ needsFrame, drew }`: whether to ask for another animation frame, and
///   whether this one drew, after which `markers()` has their new places.
/// - The camera's moves: `pan(dx, dy)` in points, `endPan(vx, vy)` when the
///   drag ends with the pointer's velocity in points a second (a fast
///   release on the globe glides on), `zoom(levels)`,
///   `orbit(yaw, pitch)` in radians, `look(lat, lon, zoom)`, and `camera()`,
///   where it is: `{ latitude, longitude, zoom, bearing, pitch }`, the
///   bearing and the pitch in radians.
/// - `attribution()`: the credits the map's data asks for at the camera's
///   zoom, `{ credits, link }`, the words in order and where a click on
///   them leads (null for nowhere).
/// - The markers: `setMarker(id, lat, lon)` with an id of the page's (an
///   integer from 0 to 2^32 - 1), `removeMarker(id)`, and `markers()`, the
///   places on the last frame drawn, `{ id, x, y, alpha }` in points from the
///   canvas's top left corner, a marker beyond the horizon left out.
/// - `downloads`: the requests answered, from the cache or the network
///   (`cached` of them from the cache), the ones that failed (`fetch`
///   threw, as it does when the archive's host refuses the page's origin, or
///   an HTTP error) and the first failure's text, for the page to show, as
///   the engine only logs them.
/// - `timings`: how long the module's calls held the page's thread, in
///   milliseconds, as `{ calls, total, longest, overBudget }` each:
///   `frames` and `answers` (a request answered, which runs the tasks it
///   wakes, the tiles' parsing among them) the module's own time, and
///   `submissions` the WebGPU host's inside them, apart, and `tiles` the
///   module's handling of a tile a worker prepared (its materialize).
///   `overBudget` counts the calls longer than a frame at 60 Hz.
/// - `tileWorkers()`: how many workers parse the tiles, and what became of
///   the tiles they prepared, `{ workers, accepted, refused, failed }`:
///   a refused or failed tile is parsed on the page's thread after all.
/// - `host`, the WebGPU host, and `poiAtlasLayout`, the layout the icons
///   were drawn to.
export async function startMap({
    device, module, shaders, resources, canvasTexture,
    archiveURL = '', multisample = true, fetch: fetchFunction = globalThis.fetch,
    warn = console.warn, print, wake = () => {}, downloadFailed = () => {}, rangeCache = null,
    drawPoiIcons = () => null, attribution = null, tileWorkers = [],
}) {
    const files = new Map([...resources].map(([name, bytes]) => [`${resourceFolder.slice(1)}/${name}`, bytes]));
    const wasi = new WASIShim({
        print,
        environment: { IMMERSIVE_MAP_RESOURCES: resourceFolder },
        folder: { path: '/', files },
    });
    const decoder = new TextDecoder();
    const encoder = new TextEncoder();
    let host = null;
    let instance = null;
    const memory = () => instance.exports.memory.buffer;
    const text = (pointer, length) => decoder.decode(new Uint8Array(memory(), pointer, length).slice());

    /// Copies the bytes into a buffer the module gives for the request.
    const hand = (id, kind, bytes) => {
        const pointer = instance.exports.immersivemap_fetch_buffer(id, kind, bytes.length);
        if (pointer !== 0) new Uint8Array(memory(), pointer, bytes.length).set(bytes);
    };
    const downloads = { answered: 0, cached: 0, failed: 0, firstFailure: null };

    // The page's thread held by the module, its calls timed apart from the
    // WebGPU host's submissions inside them.
    const frameBudget = 1000 / 60;
    const stat = () => ({ calls: 0, total: 0, longest: 0, overBudget: 0 });
    const timings = { frames: stat(), answers: stat(), tiles: stat(), submissions: stat() };
    const note = (entry, milliseconds) => {
        entry.calls += 1;
        entry.total += milliseconds;
        entry.longest = Math.max(entry.longest, milliseconds);
        if (milliseconds > frameBudget) entry.overBudget += 1;
    };
    let submitting = 0;
    const timed = (entry, call) => {
        submitting = 0;
        const start = performance.now();
        const result = call();
        note(entry, performance.now() - start - submitting);
        return result;
    };
    const noteFailure = (text) => {
        downloads.failed += 1;
        downloads.firstFailure ??= text;
        downloadFailed(downloads);
    };
    const answer = (id, { status, headers, body }) => {
        downloads.answered += 1;
        // A missing tile is a 206 or a 200 of the archive's own bytes, so
        // any error status is the archive's host refusing or failing.
        if (status >= 400) noteFailure(`HTTP ${status}`);
        hand(id, 0, body);
        hand(id, 1, encoder.encode(headers));
        timed(timings.answers, () => instance.exports.immersivemap_fetch_finish(id, status));
        wake();
    };
    const fail = (id, error) => {
        noteFailure(String(error?.message ?? error));
        hand(id, 1, encoder.encode(String(error?.message ?? error)));
        timed(timings.answers, () => instance.exports.immersivemap_fetch_finish(id, 0));
        wake();
    };

    instance = await WebAssembly.instantiate(module, {
        ...wasi.imports,
        immersivemap_webgpu: {
            submit(pointer, length) {
                const start = performance.now();
                host.submit(new Uint8Array(memory(), pointer, length));
                const milliseconds = performance.now() - start;
                submitting += milliseconds;
                note(timings.submissions, milliseconds);
            },
        },
        immersivemap_tiles: {
            prepare(id, x, y, z, pointer, length) {
                // The worker with the fewest tiles waiting, the bytes
                // copied out of the module's memory and moved to it.
                const worker = workers.reduce((least, next) => (next.waiting < least.waiting ? next : least));
                const bytes = new Uint8Array(memory(), pointer, length).slice();
                worker.waiting += 1;
                worker.send({ type: 'prepare', id, x, y, z, bytes }, [bytes.buffer]);
            },
        },
        immersivemap_fetch: {
            range(id, urlPointer, urlLength, headersPointer, headersLength, start, end) {
                const url = text(urlPointer, urlLength);
                const headers = text(headersPointer, headersLength).split('\n')
                    .filter((line) => line.includes(':'))
                    .map((line) => [line.slice(0, line.indexOf(':')).trim(), line.slice(line.indexOf(':') + 1).trim()]);
                // Answered on a later turn of the event loop, never inside
                // the module's call.
                const request = { url, headers, start, end };
                const network = (range) => fetchRange(range, fetchFunction);
                (rangeCache ? rangeCache.fetch(request, network) : network(request))
                    .then((response) => {
                        downloads.cached = rangeCache?.counts.hits ?? 0;
                        answer(id, response);
                    }, (error) => fail(id, error));
            },
        },
    });
    wasi.bind(instance);
    host = new ImmersiveMapWebGPUHost({
        device,
        shaders,
        canvasTexture,
        completed: (id) => instance.exports.immersivemap_webgpu_completed(id),
        warn,
    });
    instance.exports._initialize();

    // The tile workers, each another instance of the module, started with
    // the map's settings and the text's metrics, the `.json` files.
    const workers = tileWorkers.map((worker) => ({ ...worker, waiting: 0 }));
    const metrics = new Map([...resources].filter(([name]) => name.endsWith('.json')));
    for (const worker of workers) {
        worker.send({ type: 'start', module, resources: metrics, multisample, archiveURL });
        worker.listen(({ id, entry }) => {
            worker.waiting -= 1;
            if (entry) {
                const pointer = instance.exports.immersivemap_tiles_buffer(id, entry.length);
                if (pointer !== 0) new Uint8Array(memory(), pointer, entry.length).set(entry);
            }
            timed(timings.tiles, () => instance.exports.immersivemap_tiles_finish(id, entry ? 1 : 0));
            wake();
        });
    }

    // The POI icons, drawn by the page into the atlas the module lays out.
    const layoutPointer = instance.exports.immersivemap_poi_atlas_layout();
    const layoutLength = new DataView(memory(), layoutPointer, 4).getUint32(0, true);
    const poiAtlasLayout = JSON.parse(text(layoutPointer + 4, layoutLength));
    const poiAtlas = drawPoiIcons(poiAtlasLayout) ?? new Uint8Array();

    /// Copies the bytes into memory of the module's, freed with `free`.
    const place = (bytes) => {
        const pointer = instance.exports.immersivemap_alloc(bytes.length);
        new Uint8Array(memory(), pointer, bytes.length).set(bytes);
        return pointer;
    };
    const archive = encoder.encode(archiveURL);
    const archivePointer = place(archive);
    const atlasPointer = place(poiAtlas);
    const attributionJSON = encoder.encode(attribution ? JSON.stringify(attribution) : '');
    const attributionPointer = place(attributionJSON);
    const started = instance.exports.immersivemap_map_start(engineFeatures(device), multisample ? 1 : 0,
                                                            archivePointer, archive.length,
                                                            atlasPointer, poiAtlas.length,
                                                            attributionPointer, attributionJSON.length,
                                                            workers.length > 0 ? 1 : 0);
    instance.exports.immersivemap_free(archivePointer);
    instance.exports.immersivemap_free(atlasPointer);
    instance.exports.immersivemap_free(attributionPointer);
    if (started !== 1) throw new Error('The map could not be made (the module printed why)');

    const exports = instance.exports;
    /// Runs a call that changes the map, then wakes the page.
    const changing = (call) => (...values) => {
        call(...values);
        wake();
    };
    return {
        host,
        poiAtlasLayout,
        downloads,
        timings,
        frame(width, height, pixelsPerPoint) {
            const result = timed(timings.frames, () => exports.immersivemap_map_frame(width, height, pixelsPerPoint));
            return { needsFrame: (result & 1) !== 0, drew: (result & 2) !== 0 };
        },
        pan: changing((dx, dy) => exports.immersivemap_map_pan(dx, dy)),
        endPan: changing((vx = 0, vy = 0) => exports.immersivemap_map_end_pan(vx, vy)),
        zoom: changing((levels) => exports.immersivemap_map_zoom(levels)),
        orbit: changing((yaw, pitch) => exports.immersivemap_map_orbit(yaw, pitch)),
        look: changing((latitude, longitude, zoom) => exports.immersivemap_map_look(latitude, longitude, zoom)),
        setMarker: changing((id, latitude, longitude) => exports.immersivemap_map_set_marker(id, latitude, longitude)),
        removeMarker: changing((id) => exports.immersivemap_map_remove_marker(id)),
        attribution() {
            const pointer = exports.immersivemap_map_attribution();
            if (pointer === 0) return { credits: [], link: null };
            const length = new DataView(memory(), pointer, 4).getUint32(0, true);
            return JSON.parse(text(pointer + 4, length));
        },
        tileWorkers() {
            const pointer = exports.immersivemap_tiles_counts();
            const [accepted, refused, failed] = new Float64Array(memory(), pointer, 3);
            return { workers: workers.length, accepted, refused, failed };
        },
        camera() {
            const pointer = exports.immersivemap_map_camera();
            if (pointer === 0) return null;
            const [latitude, longitude, zoom, bearing, pitch] = new Float64Array(memory(), pointer, 5);
            return { latitude, longitude, zoom, bearing, pitch };
        },
        markers() {
            const pointer = exports.immersivemap_map_markers();
            const count = new Float64Array(memory(), pointer, 1)[0];
            const values = new Float64Array(memory(), pointer + 8, count * 4);
            const places = [];
            for (let index = 0; index < count; index += 1) {
                const [id, x, y, alpha] = values.subarray(index * 4, index * 4 + 4);
                places.push({ id, x, y, alpha });
            }
            return places;
        },
    };
}

/// Fetches the resource files build.sh listed in `resources.json` beside
/// them, as the Map `startMap` takes.
export async function fetchResources(base) {
    const names = await fetch(`${base}/resources.json`).then((response) => response.json());
    const files = await Promise.all(names.map(async (name) => {
        const response = await fetch(`${base}/${name}`);
        if (!response.ok) throw new Error(`The resource ${name} did not load (HTTP ${response.status})`);
        return [name, new Uint8Array(await response.arrayBuffer())];
    }));
    return new Map(files);
}
