// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// A cache of the tile archives' range responses in front of the page's
// `fetch`, so a page loaded again reads the ranges it read before from the
// browser's own storage (OPFS) instead of the network. The engine sees the
// same responses either way.
//
// An archive replaced on its host must never be read through ranges of its
// old version, so every range is held under the version it was read with:
// the ETag of its response, or its Last-Modified where the ETag is not
// readable (a host that does not expose it across origins). The archive
// client reads the header first, a range at byte 0, and checks every later
// range against the ETag the header came with
// (`PMTilesArchiveClient.fetchIndex`). That read always goes to the network
// and sets the archive's version for the session: when it differs from the
// version stored, the archive's ranges are dropped. A later range is
// answered from the cache only under that version, and kept only when the
// network answers it with a 206 of the same version. An archive with no
// version, or a host that ignores ranges, is never cached.
//
// The cache is best effort: a storage failure is warned about once and the
// request goes to the network.

/// A store of byte files by path (`<folder>/<name>`), one folder an archive.
/// `list()` gives every file's path, size and last write time.
///
/// The browser's: the origin private file system, or null where the
/// browser has none or cannot write to it from the page.
export async function openBrowserStore(name = 'immersivemap-tile-archives') {
    try {
        const root = await navigator.storage?.getDirectory?.();
        if (!root) return null;
        const top = await root.getDirectoryHandle(name, { create: true });
        const probe = await top.getFileHandle('.probe', { create: true });
        if (typeof probe.createWritable !== 'function') return null;
        return new FileSystemStore(top);
    } catch {
        return null;
    }
}

class FileSystemStore {
    #top;

    constructor(top) {
        this.#top = top;
    }

    async #folder(name, create) {
        try {
            return await this.#top.getDirectoryHandle(name, { create });
        } catch (error) {
            if (!create && error?.name === 'NotFoundError') return null;
            throw error;
        }
    }

    #split(path) {
        const slash = path.indexOf('/');
        return [path.slice(0, slash), path.slice(slash + 1)];
    }

    async read(path) {
        const [folderName, fileName] = this.#split(path);
        const folder = await this.#folder(folderName, false);
        if (!folder) return null;
        try {
            const file = await (await folder.getFileHandle(fileName)).getFile();
            return new Uint8Array(await file.arrayBuffer());
        } catch (error) {
            if (error?.name === 'NotFoundError') return null;
            throw error;
        }
    }

    async write(path, bytes) {
        const [folderName, fileName] = this.#split(path);
        const folder = await this.#folder(folderName, true);
        const writable = await (await folder.getFileHandle(fileName, { create: true })).createWritable();
        await writable.write(bytes);
        await writable.close();
    }

    async remove(path) {
        const [folderName, fileName] = this.#split(path);
        const folder = await this.#folder(folderName, false);
        await folder?.removeEntry(fileName).catch(() => {});
    }

    async removeFolder(name) {
        await this.#top.removeEntry(name, { recursive: true }).catch(() => {});
    }

    async list() {
        const files = [];
        for await (const [folderName, folder] of this.#top.entries()) {
            if (folder.kind !== 'directory') continue;
            for await (const [fileName, handle] of folder.entries()) {
                if (handle.kind !== 'file') continue;
                const file = await handle.getFile();
                files.push({ path: `${folderName}/${fileName}`, size: file.size, time: file.lastModified });
            }
        }
        return files;
    }
}

/// The same store in memory, for a run with no browser storage (the
/// headless run), and to share between maps of one page.
export class MemoryStore {
    #files = new Map();

    async read(path) {
        return this.#files.get(path)?.bytes.slice() ?? null;
    }

    async write(path, bytes) {
        this.#files.set(path, { bytes: bytes.slice(), time: Date.now() });
    }

    async remove(path) {
        this.#files.delete(path);
    }

    async removeFolder(name) {
        for (const path of [...this.#files.keys()]) {
            if (path.startsWith(`${name}/`)) this.#files.delete(path);
        }
    }

    async list() {
        return [...this.#files].map(([path, { bytes, time }]) => ({ path, size: bytes.length, time }));
    }
}

/// The name of an archive's folder: a hash of its URL and the request
/// headers, as two FNV-1a 32-bit hashes in hexadecimal.
function archiveFolder(url, headers) {
    const text = `${url}\n${headers.map(([name, value]) => `${name.toLowerCase()}: ${value}`).sort().join('\n')}`;
    const bytes = new TextEncoder().encode(text);
    let first = 0x811c9dc5;
    let second = 0x01000193 ^ 0x5bd1e995;
    for (const byte of bytes) {
        first = Math.imul(first ^ byte, 0x01000193) >>> 0;
        second = Math.imul(second ^ byte, 0x01000193) >>> 0;
    }
    return first.toString(16).padStart(8, '0') + second.toString(16).padStart(8, '0');
}

/// The response's version: its ETag, else its Last-Modified, from its
/// `name: value` lines. Null when it has neither.
function versionOf(headerLines) {
    let lastModified = null;
    for (const line of headerLines.split('\n')) {
        const colon = line.indexOf(':');
        if (colon < 0) continue;
        const name = line.slice(0, colon).trim().toLowerCase();
        const value = line.slice(colon + 1).trim();
        if (name === 'etag' && value) return `etag ${value}`;
        if (name === 'last-modified' && value) lastModified = `modified ${value}`;
    }
    return lastModified;
}

const versionFile = 'version';

/// A response kept as one file: the length of its header lines (4 bytes,
/// little endian), the lines in UTF-8, then the body.
function encodeEntry(headerLines, body) {
    const lines = new TextEncoder().encode(headerLines);
    const bytes = new Uint8Array(4 + lines.length + body.length);
    new DataView(bytes.buffer).setUint32(0, lines.length, true);
    bytes.set(lines, 4);
    bytes.set(body, 4 + lines.length);
    return bytes;
}

function decodeEntry(bytes) {
    if (bytes.length < 4) return null;
    const length = new DataView(bytes.buffer, bytes.byteOffset).getUint32(0, true);
    if (4 + length > bytes.length) return null;
    return {
        headers: new TextDecoder().decode(bytes.subarray(4, 4 + length)),
        body: bytes.slice(4 + length),
    };
}

export class ArchiveRangeCache {
    #store;
    #maxBytes;
    #warn;
    #warned = false;
    /// The version each archive's header was read with in this session,
    /// null for one that is not cached.
    #versions = new Map();
    /// Every file's size and last write, read from the store once.
    #index = null;
    #total = 0;

    /// What it has done: ranges answered from the store, ranges stored,
    /// archives dropped for a new version.
    counts = { hits: 0, stored: 0, dropped: 0 };

    /// - store: `openBrowserStore()`'s, or a `MemoryStore`.
    /// - maxBytes: the most the cache keeps, the oldest ranges dropped past it.
    constructor(store, { maxBytes = 256 * 1024 * 1024, warn = console.warn } = {}) {
        this.#store = store;
        this.#maxBytes = maxBytes;
        this.#warn = warn;
    }

    /// Answers the range request `{ url, headers, start, end }` (`headers` a
    /// list of `[name, value]`) from the store or with `network(request)`,
    /// which gives `{ status, headers, body }` (`headers` as `name: value`
    /// lines).
    async fetch(request, network) {
        const folder = archiveFolder(request.url, request.headers);
        if (request.start === 0) return this.#readHeader(folder, request, network);

        const version = this.#versions.get(folder);
        const name = `${request.start}-${request.end}`;
        if (version) {
            const stored = await this.#attempt(async () => decodeEntry(await this.#store.read(`${folder}/${name}`) ?? new Uint8Array()));
            if (stored && versionOf(stored.headers) === version) {
                this.counts.hits += 1;
                return { status: 206, headers: stored.headers, body: stored.body };
            }
        }
        const response = await network(request);
        if (version && response.status === 206 && versionOf(response.headers) === version) {
            await this.#attempt(() => this.#write(`${folder}/${name}`, encodeEntry(response.headers, response.body)));
        }
        return response;
    }

    /// The header's read: always the network's, and the archive's version
    /// for the session. A version other than the one stored drops the
    /// archive's ranges.
    async #readHeader(folder, request, network) {
        const response = await network(request);
        const version = response.status === 206 ? versionOf(response.headers) : null;
        this.#versions.set(folder, version);
        if (version) {
            await this.#attempt(async () => {
                const stored = await this.#store.read(`${folder}/${versionFile}`);
                if (stored && new TextDecoder().decode(stored) === version) return;
                if (stored) {
                    await this.#dropFolder(folder);
                    this.counts.dropped += 1;
                }
                await this.#write(`${folder}/${versionFile}`, new TextEncoder().encode(version));
            });
        }
        return response;
    }

    async #loadIndex() {
        if (this.#index) return;
        this.#index = new Map();
        for (const { path, size, time } of await this.#store.list()) {
            this.#index.set(path, { size, time });
            this.#total += size;
        }
    }

    async #write(path, bytes) {
        await this.#loadIndex();
        await this.#store.write(path, bytes);
        const previous = this.#index.get(path);
        if (previous) this.#total -= previous.size;
        // The clock of the files' `lastModified`.
        this.#index.set(path, { size: bytes.length, time: Date.now() });
        this.#total += bytes.length;
        if (!path.endsWith(`/${versionFile}`)) this.counts.stored += 1;
        if (this.#total > this.#maxBytes) await this.#evict();
    }

    /// Drops the oldest ranges until the cache holds nine tenths of its
    /// most, keeping the archives' versions.
    async #evict() {
        const ranges = [...this.#index].filter(([path]) => !path.endsWith(`/${versionFile}`))
            .sort(([, a], [, b]) => a.time - b.time);
        for (const [path, { size }] of ranges) {
            if (this.#total <= this.#maxBytes * 0.9) break;
            await this.#store.remove(path);
            this.#index.delete(path);
            this.#total -= size;
        }
    }

    async #dropFolder(folder) {
        await this.#loadIndex();
        await this.#store.removeFolder(folder);
        for (const [path, { size }] of [...this.#index]) {
            if (!path.startsWith(`${folder}/`)) continue;
            this.#index.delete(path);
            this.#total -= size;
        }
    }

    /// Runs a step of the store's, a failure warned about once and taken as
    /// nothing found.
    async #attempt(step) {
        try {
            return await step();
        } catch (error) {
            if (!this.#warned) {
                this.#warned = true;
                this.#warn(`The tile archive cache failed and is passed by: ${error?.message ?? error}`);
            }
            return null;
        }
    }
}
