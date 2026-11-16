// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// The bindings each WGSL entry point uses, for the WebGPU backend's host
// (Web/ImmersiveMapWebGPU.js), which makes an explicit bind group layout
// per stage from them. WebGPU's 'auto' layout has the same entries, but
// the host cannot read them back, and it must know which bindings a draw
// fills and where it binds a placeholder.
//
// A binding is used by an entry point when the entry point or a function
// it calls names it, whatever override guards the use: WebGPU's static
// use, which is what an 'auto' layout holds too. The reading is lexical,
// over the composed file, and holds for the engine's WGSL: module-scope
// declarations one per line, functions as `fn name(...) ... { ... }`.

import { compose, sourcesRoot, wgslFiles } from './wgsl.mjs';
import { readFileSync } from 'node:fs';
import { relative } from 'node:path';

const bindingLine = /^@group\((\d+)\)\s*@binding\((\d+)\)\s*var(?:<([^>]+)>)?\s+(\w+)\s*:\s*([^;]+);/;
const functionStart = /(?:@(vertex|fragment)\s+)?fn\s+(\w+)\s*\(/g;

/// The WebGPU layout entry of a declaration: its resource and how it is
/// read.
function resourceOf(addressSpace, type) {
    if (addressSpace) {
        const space = addressSpace.replace(/\s/g, '');
        if (space === 'uniform') return { buffer: { type: 'uniform' } };
        if (space === 'storage' || space === 'storage,read') return { buffer: { type: 'read-only-storage' } };
        throw new Error(`unknown address space ${addressSpace}`);
    }
    const trimmed = type.trim();
    if (trimmed === 'sampler') return { sampler: { type: 'filtering' } };
    if (trimmed === 'sampler_comparison') return { sampler: { type: 'comparison' } };
    const texture = /^texture_(depth_)?(multisampled_)?(2d_array|2d|cube)(?:<(\w+)>)?$/.exec(trimmed);
    if (texture) {
        const [, depth, multisampled, dimension, sampled] = texture;
        const viewDimension = dimension === '2d_array' ? '2d-array' : dimension;
        let sampleType = depth ? 'depth' : 'float';
        if (sampled === 'u32') sampleType = 'uint';
        if (sampled === 'i32') sampleType = 'sint';
        return { texture: { sampleType, viewDimension, multisampled: Boolean(multisampled) } };
    }
    throw new Error(`unknown binding type ${type}`);
}

/// The module-scope bindings and the functions of composed WGSL, with the
/// names each function's body uses.
function readModule(code) {
    const bindings = new Map();
    for (const line of code.split('\n')) {
        const match = bindingLine.exec(line.trim());
        if (!match) continue;
        const [, group, binding, addressSpace, name, type] = match;
        bindings.set(name, { group: Number(group), binding: Number(binding), ...resourceOf(addressSpace, type) });
    }
    const functions = new Map();
    for (const match of code.matchAll(functionStart)) {
        const open = code.indexOf('{', match.index);
        let depth = 0;
        let end = open;
        for (; end < code.length; end += 1) {
            if (code[end] === '{') depth += 1;
            if (code[end] === '}' && --depth === 0) break;
        }
        // The signature and the body: a parameter's type or an attribute
        // names nothing bound, and a body names what it reads.
        const text = code.slice(match.index + match[0].length, end).replace(/\/\/[^\n]*/g, '');
        // A parameter or a local shadows a global of its name, and a
        // member access (`.name`) names no global.
        const signature = text.slice(0, text.indexOf('{'));
        const declared = new Set([
            ...[...signature.matchAll(/(\w+)\s*:/g)].map((found) => found[1]),
            ...[...text.matchAll(/\b(?:let|var|const)\s+(\w+)/g)].map((found) => found[1]),
        ]);
        const names = new Set([...text.matchAll(/(?<![.\w])[A-Za-z_]\w*/g)].map((found) => found[0]).filter((name) => !declared.has(name)));
        functions.set(match[2], { stage: match[1] ?? null, names });
    }
    return { bindings, functions };
}

/// Each entry point of composed WGSL with the bindings it uses, sorted by
/// group and binding.
export function reflectEntryPoints(code) {
    const { bindings, functions } = readModule(code);
    const entryPoints = {};
    for (const [name, fn] of functions) {
        if (!fn.stage) continue;
        const used = new Map();
        const visited = new Set();
        const pending = [name];
        while (pending.length > 0) {
            const current = pending.pop();
            if (visited.has(current)) continue;
            visited.add(current);
            for (const word of functions.get(current).names) {
                if (bindings.has(word)) used.set(word, bindings.get(word));
                if (functions.has(word) && !visited.has(word)) pending.push(word);
            }
        }
        entryPoints[name] = {
            stage: fn.stage,
            bindings: [...used.values()].sort((a, b) => a.group - b.group || a.binding - b.binding),
        };
    }
    return entryPoints;
}

/// Every WGSL file of the engine that declares an entry point, composed
/// with its includes, with the entry points it declares itself: an
/// included file's belong to its own module.
export function shaderBundle() {
    const modules = [];
    for (const path of wgslFiles()) {
        const declared = new Set([...readFileSync(path, 'utf8').matchAll(/@(?:vertex|fragment)\s+fn\s+(\w+)/g)].map((match) => match[1]));
        if (declared.size === 0) continue;
        const { code } = compose(path);
        const entryPoints = Object.fromEntries(Object.entries(reflectEntryPoints(code)).filter(([name]) => declared.has(name)));
        modules.push({ file: relative(sourcesRoot, path), code, entryPoints });
    }
    return { modules };
}
