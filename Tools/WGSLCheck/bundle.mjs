// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// Writes the shader bundle the WebGPU backend's host loads in a browser
// (Web/ImmersiveMapWebGPU.js): every WGSL file of the engine that declares
// an entry point, composed with its includes, and the bindings each entry
// point uses (reflect.mjs). `node bundle.mjs <output.json>`. Built, not
// committed: the WGSL files are the source.

import { writeFileSync } from 'node:fs';
import { shaderBundle } from './reflect.mjs';

const output = process.argv[2];
if (!output) {
    console.error('usage: node bundle.mjs <output.json>');
    process.exit(2);
}
writeFileSync(output, JSON.stringify(shaderBundle()));
console.log(`wrote ${output}`);
