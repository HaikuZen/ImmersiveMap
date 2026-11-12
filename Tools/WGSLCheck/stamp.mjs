// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// Stamps WGSL files with the hashes of the Metal sources they were ported
// from: `node stamp.mjs <file.wgsl>...`, after the WGSL was brought level
// with a change to its Metal twin. ShaderPortStampTests fails while a
// Metal file differs from the hash its twin records, so a change made to
// one copy alone is caught. Stamp only a file you have brought level.

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fnv1a64, stampLine } from './wgsl.mjs';

const files = process.argv.slice(2);
if (files.length === 0) {
    console.error('usage: node stamp.mjs <file.wgsl>...');
    process.exit(2);
}
for (const file of files) {
    const path = resolve(file);
    const lines = readFileSync(path, 'utf8').split('\n');
    let stamped = 0;
    const updated = lines.map((line) => {
        const match = stampLine.exec(line);
        if (!match) return line;
        stamped += 1;
        const hash = fnv1a64(readFileSync(resolve(dirname(path), match[1])));
        return `// ported-from: ${match[1]} fnv1a64=${hash}`;
    });
    if (stamped === 0) {
        console.error(`${file}: no "// ported-from:" line`);
        process.exit(1);
    }
    writeFileSync(path, updated.join('\n'));
    console.log(`stamped ${file}`);
}
