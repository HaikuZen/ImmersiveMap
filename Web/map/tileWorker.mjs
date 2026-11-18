// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// A tile worker: another instance of the map's module (ImmersiveMapWebMap),
// started as a worker (`immersivemap_worker_start`), that parses the tiles
// the map hands it off the page's thread (BrowserTileWorkers.swift,
// `OffThreadTilePreparation`). The same script in a browser's Web Worker and
// in a Node `worker_threads` worker (the headless run).
//
// Messages in: `{ type: 'start', module, resources, multisample, archiveURL }`
// once, the module compiled and the font metrics' files (a Map of name to
// bytes, the text's `.json` files are all a parse reads), then
// `{ type: 'prepare', id, x, y, z, bytes }` for each tile. Message out, one a
// tile, in the order asked: `{ id, entry }`, the prepared-tile entry's bytes,
// transferred, or null when the tile did not parse.

import { WASIShim } from '../WASIShim.js';

const nodeWorker = typeof self === 'undefined' ? await import('node:worker_threads') : null;
const send = nodeWorker
    ? (message, transfer) => nodeWorker.parentPort.postMessage(message, transfer)
    : (message, transfer) => self.postMessage(message, transfer);
const listen = nodeWorker
    ? (handler) => nodeWorker.parentPort.on('message', handler)
    : (handler) => { self.onmessage = (event) => handler(event.data); };

/// Where the module finds the resources, as on the page (map.mjs).
const resourceFolder = '/resources';

let ready = null;

async function start({ module, resources, multisample, archiveURL }) {
    const files = new Map([...resources].map(([name, bytes]) => [`${resourceFolder.slice(1)}/${name}`, bytes]));
    const wasi = new WASIShim({
        environment: { IMMERSIVE_MAP_RESOURCES: resourceFolder },
        folder: { path: '/', files },
    });
    const refused = (what) => () => { throw new Error(`A tile worker has no ${what}`); };
    // The module imports what the map needs: a worker draws and fetches
    // nothing.
    const instance = await WebAssembly.instantiate(module, {
        ...wasi.imports,
        immersivemap_webgpu: { submit: refused('GPU') },
        immersivemap_fetch: { range: refused('network') },
        immersivemap_tiles: { prepare: refused('workers of its own') },
    });
    wasi.bind(instance);
    instance.exports._initialize();
    const { exports } = instance;
    const memory = () => exports.memory.buffer;
    const archive = new TextEncoder().encode(archiveURL);
    const archivePointer = exports.immersivemap_alloc(archive.length);
    new Uint8Array(memory(), archivePointer, archive.length).set(archive);
    exports.immersivemap_worker_start(multisample ? 1 : 0, archivePointer, archive.length);
    exports.immersivemap_free(archivePointer);
    return { exports, memory };
}

function prepare({ exports, memory }, { x, y, z, bytes }) {
    const pointer = exports.immersivemap_alloc(bytes.length);
    new Uint8Array(memory(), pointer, bytes.length).set(bytes);
    const entryPointer = exports.immersivemap_worker_prepare(x, y, z, pointer, bytes.length);
    exports.immersivemap_free(pointer);
    if (entryPointer === 0) return null;
    const length = new DataView(memory(), entryPointer, 4).getUint32(0, true);
    return new Uint8Array(memory(), entryPointer + 4, length).slice();
}

listen(async (message) => {
    if (message.type === 'start') {
        ready = start(message);
        return;
    }
    let entry = null;
    try {
        entry = prepare(await ready, message);
    } catch {
        // A trap or a worker that did not start: the map parses the tile
        // itself and counts it as failed.
        entry = null;
    }
    send({ id: message.id, entry }, entry ? [entry.buffer] : []);
});
