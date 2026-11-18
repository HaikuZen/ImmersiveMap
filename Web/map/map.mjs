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
/// Returns:
/// - `frame(width, height, pixelsPerPoint)`, which runs what the module has
///   ready and draws a frame only when one is needed. It returns
///   `{ needsFrame, drew }`: whether to ask for another animation frame, and
///   whether this one drew, after which `markers()` has their new places.
/// - The camera's moves: `pan(dx, dy, ended)` in points, `zoom(levels)`,
///   `orbit(yaw, pitch)` in radians, `look(lat, lon, zoom)`.
/// - The markers: `setMarker(id, lat, lon)` with an id of the page's (an
///   integer from 0 to 2^32 - 1), `removeMarker(id)`, and `markers()`, the
///   places on the last frame drawn, `{ id, x, y, alpha }` in points from the
///   canvas's top left corner, a marker beyond the horizon left out.
/// - `downloads`: the requests answered, the ones that failed (`fetch`
///   threw, as it does when the archive's host refuses the page's origin, or
///   an HTTP error) and the first failure's text, for the page to show, as
///   the engine only logs them.
/// - `host`, the WebGPU host.
export async function startMap({
    device, module, shaders, resources, canvasTexture,
    archiveURL = '', multisample = true, fetch: fetchFunction = globalThis.fetch,
    warn = console.warn, print, wake = () => {},
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
    const downloads = { answered: 0, failed: 0, firstFailure: null };
    const noteFailure = (text) => {
        downloads.failed += 1;
        downloads.firstFailure ??= text;
    };
    const answer = (id, { status, headers, body }) => {
        downloads.answered += 1;
        // A missing tile is a 206 or a 200 of the archive's own bytes, so
        // any error status is the archive's host refusing or failing.
        if (status >= 400) noteFailure(`HTTP ${status}`);
        hand(id, 0, body);
        hand(id, 1, encoder.encode(headers));
        instance.exports.immersivemap_fetch_finish(id, status);
        wake();
    };
    const fail = (id, error) => {
        noteFailure(String(error?.message ?? error));
        hand(id, 1, encoder.encode(String(error?.message ?? error)));
        instance.exports.immersivemap_fetch_finish(id, 0);
        wake();
    };

    instance = await WebAssembly.instantiate(module, {
        ...wasi.imports,
        immersivemap_webgpu: {
            submit(pointer, length) {
                host.submit(new Uint8Array(memory(), pointer, length));
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
                fetchRange({ url, headers, start, end }, fetchFunction)
                    .then((response) => answer(id, response), (error) => fail(id, error));
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

    const archive = encoder.encode(archiveURL);
    const archivePointer = instance.exports.immersivemap_alloc(archive.length);
    new Uint8Array(memory(), archivePointer, archive.length).set(archive);
    const started = instance.exports.immersivemap_map_start(engineFeatures(device), multisample ? 1 : 0,
                                                            archivePointer, archive.length);
    instance.exports.immersivemap_free(archivePointer);
    if (started !== 1) throw new Error('The map could not be made');

    const exports = instance.exports;
    /// Runs a call that changes the map, then wakes the page.
    const changing = (call) => (...values) => {
        call(...values);
        wake();
    };
    return {
        host,
        downloads,
        frame(width, height, pixelsPerPoint) {
            const result = exports.immersivemap_map_frame(width, height, pixelsPerPoint);
            return { needsFrame: (result & 1) !== 0, drew: (result & 2) !== 0 };
        },
        pan: changing((dx, dy, ended = false) => exports.immersivemap_map_pan(dx, dy, ended ? 1 : 0)),
        zoom: changing((levels) => exports.immersivemap_map_zoom(levels)),
        orbit: changing((yaw, pitch) => exports.immersivemap_map_orbit(yaw, pitch)),
        look: changing((latitude, longitude, zoom) => exports.immersivemap_map_look(latitude, longitude, zoom)),
        setMarker: changing((id, latitude, longitude) => exports.immersivemap_map_set_marker(id, latitude, longitude)),
        removeMarker: changing((id) => exports.immersivemap_map_remove_marker(id)),
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
