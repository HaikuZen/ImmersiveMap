// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// The rules the WGSL sources follow, shared by check.mjs and stamp.mjs. The
// Swift side reads the same lines (WGSLSources in ImmersiveMapPortableTests).

import { readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
export const sourcesRoot = join(repositoryRoot, 'Sources', 'ImmersiveMap');

/// `// include: <path>`, relative to the file: a WGSL file put in front of
/// this one, since WGSL has no include of its own.
const includeLine = /^\/\/ include: (\S+)\s*$/;
/// `// ported-from: <path> fnv1a64=<hex>`, relative to the file: the Metal
/// source this file is the twin of, and its hash when the two last agreed.
export const stampLine = /^\/\/ ported-from: (\S+) fnv1a64=([0-9a-f]{16})\s*$/;

/// Every .wgsl file under the engine's sources, sorted.
export function wgslFiles(directory = sourcesRoot) {
    const found = [];
    for (const name of readdirSync(directory).sort()) {
        const path = join(directory, name);
        if (statSync(path).isDirectory()) {
            found.push(...wgslFiles(path));
        } else if (name.endsWith('.wgsl')) {
            found.push(path);
        }
    }
    return found;
}

/// The file with its includes in front, each file once, in the order they
/// are first named, and a map from each line of the result to its file and
/// line, so a compiler message names the source.
export function compose(path) {
    const lines = [];
    const origins = [];
    const seen = new Set();
    function add(file) {
        if (seen.has(file)) return;
        seen.add(file);
        const text = readFileSync(file, 'utf8').split('\n');
        for (const line of text) {
            const match = includeLine.exec(line);
            if (match) add(resolve(dirname(file), match[1]));
        }
        text.forEach((line, index) => {
            lines.push(line);
            origins.push({ file: relative(repositoryRoot, file), line: index + 1 });
        });
    }
    add(path);
    return { code: lines.join('\n'), origins };
}

/// FNV-1a, 64 bits, over the file's bytes, as 16 hex digits. A change
/// detector, not a security hash.
export function fnv1a64(bytes) {
    let hash = 0xcbf29ce484222325n;
    for (const byte of bytes) {
        hash ^= BigInt(byte);
        hash = (hash * 0x100000001b3n) & 0xffffffffffffffffn;
    }
    return hash.toString(16).padStart(16, '0');
}
