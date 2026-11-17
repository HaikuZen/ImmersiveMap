// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// The host of the engine's WebGPU backend (ImmersiveMapWebGPU in Swift): it
// runs the command stream the backend hands over once a submission, in the
// format WebGPUCommandStream.swift states, against a WebGPU device. The
// same module runs in a browser and in Node with Dawn (Web/test/).
//
// - Objects live in a table under the handles the backend gives them.
// - A pipeline is made per variant the backend asks for, with explicit
//   bind group layouts from the shader bundle's reflection
//   (Tools/WGSLCheck/reflect.mjs): group 0 the vertex stage's bindings,
//   group 1 the fragment stage's.
// - A stage's buffer, texture and sampler i are bound at binding i, 16 + i
//   and 32 + i, or as the vertex buffer of slot i where the pipeline reads
//   one there. Bindings 48 and 49 are the samplers WGSL declares in place
//   of Metal's inline ones (RenderUniforms.wgsl). A binding the draw left
//   unset gets a placeholder, as Metal leaves a resource a function
//   constant compiles out unbound.
// - Constant data goes into uniform chunks at 256-byte offsets, written to
//   the GPU before the submission that reads it.

const opcodes = {
    createBuffer: 1, writeBuffer: 2, createTexture: 3, writeTexture: 4, createSampler: 5,
    createDepthStencilState: 6, createRenderPipeline: 7, createPipelineVariant: 8, release: 9,
    beginRenderPass: 20, endPass: 21, setPipelineVariant: 22, setStencilReference: 23, setViewport: 24,
    setScissorRect: 25, setBuffer: 26, setBytes: 27, setTexture: 28, setSampler: 29, draw: 30,
    drawIndexed: 31, pushDebugGroup: 32, popDebugGroup: 33, copyBufferToBuffer: 34,
    copyBufferToTexture: 35, generateMipmaps: 36, submit: 37, copyTextureToTexture: 38,
};

const canvasHandle = 1;
const loadOps = ['clear', 'load', 'clear'];
const storeOps = ['discard', 'store', 'discard'];
const cullModes = ['none', 'front', 'back'];
const frontFaces = ['cw', 'ccw'];
const topologies = ['point-list', 'line-list', 'triangle-list', 'triangle-strip'];
const indexFormats = ['uint16', 'uint32'];
const uniformAlignment = 256;
const uniformChunkSize = 1 << 20;
const placeholderBufferSize = 1 << 16;
const maxUniformBindingSize = 1 << 16;

/// The device's optional features the engine asks for, of those the
/// adapter offers, and the depth format the world pass takes on it.
export function chooseFeatures(adapter) {
    const wanted = ['depth32float-stencil8', 'depth-clip-control', 'texture-compression-astc'];
    return wanted.filter((feature) => adapter.features.has(feature));
}

export class ImmersiveMapWebGPUHost {
    /// - shaders: the bundle of Tools/WGSLCheck/bundle.mjs.
    /// - canvasTexture: the frame's drawable, for the handle the backend
    ///   names it by.
    /// - completed: called with a submission's id once the queue has done
    ///   its work, for the backend's completed handlers.
    /// - warn: where the host says what it does not do yet.
    constructor({ device, shaders, canvasTexture = () => null, completed = () => {}, warn = console.warn }) {
        this.device = device;
        this.canvasTexture = canvasTexture;
        this.completed = completed;
        this.warn = warn;
        this.warned = new Set();
        this.objects = new Map();
        this.depthFormat = device.features.has('depth32float-stencil8') ? 'depth32float-stencil8' : 'depth24plus-stencil8';
        this.clampsDepth = device.features.has('depth-clip-control');
        this.entryPoints = new Map();
        for (const shader of shaders.modules) {
            const module = device.createShaderModule({ code: shader.code, label: shader.file });
            for (const [name, entryPoint] of Object.entries(shader.entryPoints)) {
                this.entryPoints.set(name, { module, hostClampsDepth: shader.hostClampsDepth === true, ...entryPoint });
            }
        }
        this.emptyFragment = device.createShaderModule({ code: '@fragment fn immersiveMapEmptyFragment() {}', label: 'empty fragment' });
        this.layoutCache = new Map();
        this.makePlaceholders();
        this.uniformChunks = [];
        this.encoder = null;
        this.pass = null;
        /// What the host has made and run, for a test's report.
        this.counts = { pipelines: 0, bindGroups: 0, draws: 0, passes: 0, submissions: 0 };
    }

    makePlaceholders() {
        const device = this.device;
        this.placeholderBuffer = device.createBuffer({
            size: placeholderBufferSize,
            usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.STORAGE | GPUBufferUsage.VERTEX,
            label: 'placeholder',
        });
        this.placeholderTextures = new Map();
        this.linearSampler = device.createSampler({ magFilter: 'linear', minFilter: 'linear', addressModeU: 'clamp-to-edge', addressModeV: 'clamp-to-edge' });
        this.comparisonSampler = device.createSampler({ magFilter: 'linear', minFilter: 'linear', compare: 'less-equal' });
    }

    placeholderView(texture) {
        const key = `${texture.sampleType}/${texture.viewDimension}/${texture.multisampled}`;
        let view = this.placeholderTextures.get(key);
        if (!view) {
            const format = texture.sampleType === 'depth' ? 'depth16unorm'
                : texture.sampleType === 'uint' ? 'r8uint' : texture.sampleType === 'sint' ? 'r8sint' : 'rgba8unorm';
            const gpu = this.device.createTexture({
                size: [1, 1, texture.viewDimension === '2d-array' ? 2 : 1],
                format,
                sampleCount: texture.multisampled ? 4 : 1,
                usage: GPUTextureUsage.TEXTURE_BINDING | (texture.multisampled ? GPUTextureUsage.RENDER_ATTACHMENT : 0),
                label: `placeholder ${key}`,
            });
            view = gpu.createView({ dimension: texture.viewDimension });
            this.placeholderTextures.set(key, view);
        }
        return view;
    }

    warnOnce(message) {
        if (this.warned.has(message)) return;
        this.warned.add(message);
        this.warn(message);
    }

    colorFormat(format) {
        return format;
    }

    textureFormat(format) {
        return format === 'depth32float-stencil8' ? this.depthFormat : format;
    }

    // MARK: - The stream

    /// Runs one submission's stream: a Uint8Array, valid only for the call.
    submit(bytes) {
        const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
        const decoder = new TextDecoder();
        let position = 0;
        const word = () => { const value = view.getUint32(position, true); position += 4; return value; };
        const int = () => { const value = view.getInt32(position, true); position += 4; return value; };
        const float = () => { const value = view.getFloat32(position, true); position += 4; return value; };
        const run = () => {
            const length = word();
            const start = position;
            position += (length + 3) & ~3;
            return bytes.subarray(start, start + length);
        };
        const string = () => decoder.decode(run());
        const json = () => JSON.parse(string());

        while (position < bytes.byteLength) {
            const opcode = word();
            switch (opcode) {
            case opcodes.createBuffer: this.createBuffer(word(), word()); break;
            case opcodes.writeBuffer: { const handle = word(), offset = word(); this.writeBuffer(handle, offset, run()); break; }
            case opcodes.createTexture: { const handle = word(); this.createTexture(handle, json()); break; }
            case opcodes.writeTexture: {
                const handle = word(), x = word(), y = word(), width = word(), height = word();
                const mipLevel = word(), slice = word(), bytesPerRow = word();
                this.writeTexture(handle, { x, y, width, height, mipLevel, slice, bytesPerRow }, run());
                break;
            }
            case opcodes.createSampler: { const handle = word(); this.createSampler(handle, json()); break; }
            case opcodes.createDepthStencilState: { const handle = word(); this.objects.set(handle, { kind: 'depthStencil', descriptor: json() }); break; }
            case opcodes.createRenderPipeline: { const handle = word(); this.objects.set(handle, { kind: 'pipeline', descriptor: json() }); break; }
            case opcodes.createPipelineVariant: {
                const handle = word(), pipeline = word(), depthStencil = word(), cull = word(), front = word();
                const bias = float(), slopeScale = float(), biasClamp = float(), clamp = word(), topology = word();
                this.createVariant(handle, { pipeline, depthStencil, cull, front, bias, slopeScale, biasClamp, clamp, topology });
                break;
            }
            case opcodes.release: this.release(word()); break;
            case opcodes.beginRenderPass: this.beginRenderPass(word, float, string); break;
            case opcodes.endPass: this.pass.end(); this.pass = null; break;
            case opcodes.setPipelineVariant: this.setVariant(word()); break;
            case opcodes.setStencilReference: this.pass.setStencilReference(word()); break;
            case opcodes.setViewport: this.pass.setViewport(float(), float(), float(), float(), float(), float()); break;
            case opcodes.setScissorRect: this.pass.setScissorRect(word(), word(), word(), word()); break;
            case opcodes.setBuffer: { const stage = word(), index = word(), handle = word(), offset = word(); this.setSlot(stage, 'buffers', index, handle ? { handle, offset } : null); break; }
            case opcodes.setBytes: { const stage = word(), index = word(); this.setSlot(stage, 'buffers', index, this.uniformBytes(run())); break; }
            case opcodes.setTexture: { const stage = word(), index = word(), handle = word(); this.setSlot(stage, 'textures', index, handle || null); break; }
            case opcodes.setSampler: { const stage = word(), index = word(), handle = word(); this.setSlot(stage, 'samplers', index, handle || null); break; }
            case opcodes.draw: {
                const first = word(), count = word(), instances = word(), baseInstance = word();
                this.prepareDraw();
                this.pass.draw(count, instances, first, baseInstance);
                break;
            }
            case opcodes.drawIndexed: {
                const format = indexFormats[word()], count = word(), handle = word(), offset = word();
                const instances = word(), baseVertex = int(), baseInstance = word();
                this.prepareDraw();
                this.pass.setIndexBuffer(this.objects.get(handle).gpu, format, offset);
                this.pass.drawIndexed(count, instances, 0, baseVertex, baseInstance);
                break;
            }
            case opcodes.pushDebugGroup: { const name = string(); this.pass?.pushDebugGroup(name); break; }
            case opcodes.popDebugGroup: this.pass?.popDebugGroup(); break;
            case opcodes.copyBufferToBuffer: {
                const source = word(), sourceOffset = word(), destination = word(), destinationOffset = word(), size = word();
                this.commandEncoder().copyBufferToBuffer(this.objects.get(source).gpu, sourceOffset,
                                                         this.objects.get(destination).gpu, destinationOffset, size);
                break;
            }
            case opcodes.copyBufferToTexture: {
                const source = word(), offset = word(), bytesPerRow = word(), texture = word();
                const slice = word(), mipLevel = word(), x = word(), y = word(), width = word(), height = word();
                this.commandEncoder().copyBufferToTexture({ buffer: this.objects.get(source).gpu, offset, bytesPerRow },
                                                          { texture: this.objects.get(texture).gpu, mipLevel, origin: { x, y, z: slice } },
                                                          { width, height });
                break;
            }
            case opcodes.copyTextureToTexture: {
                const source = word(), slice = word(), mipLevel = word(), x = word(), y = word();
                const destination = word(), destinationSlice = word(), destinationMipLevel = word();
                const destinationX = word(), destinationY = word(), width = word(), height = word();
                this.commandEncoder().copyTextureToTexture(
                    { texture: this.objects.get(source).gpu, mipLevel, origin: { x, y, z: slice } },
                    { texture: this.objects.get(destination).gpu, mipLevel: destinationMipLevel,
                      origin: { x: destinationX, y: destinationY, z: destinationSlice } },
                    { width, height });
                break;
            }
            case opcodes.generateMipmaps: word(); this.warnOnce('generateMipmaps: not done yet, the texture keeps its first level'); break;
            case opcodes.submit: this.finish(word()); break;
            default:
                throw new Error(`unknown opcode ${opcode} at byte ${position - 4}`);
            }
        }
    }

    // MARK: - Resources

    createBuffer(handle, size) {
        const gpu = this.device.createBuffer({
            size,
            usage: GPUBufferUsage.VERTEX | GPUBufferUsage.INDEX | GPUBufferUsage.UNIFORM | GPUBufferUsage.STORAGE
                | GPUBufferUsage.COPY_DST | GPUBufferUsage.COPY_SRC,
        });
        this.objects.set(handle, { kind: 'buffer', gpu, size });
    }

    writeBuffer(handle, offset, data) {
        this.device.queue.writeBuffer(this.objects.get(handle).gpu, offset, data.buffer, data.byteOffset, data.byteLength);
    }

    createTexture(handle, descriptor) {
        const format = this.textureFormat(descriptor.format);
        const isDepth = format.startsWith('depth');
        const multisampled = descriptor.sampleCount > 1;
        let usage = descriptor.shaderRead || isDepth || multisampled ? GPUTextureUsage.TEXTURE_BINDING : 0;
        if (descriptor.renderTarget || isDepth || multisampled) usage |= GPUTextureUsage.RENDER_ATTACHMENT;
        if (!isDepth && !multisampled) usage |= GPUTextureUsage.COPY_DST | GPUTextureUsage.COPY_SRC;
        if (format.startsWith('astc') && !this.device.features.has('texture-compression-astc')) {
            this.warnOnce(`${format}: the device has no ASTC, the texture is left out`);
            return;
        }
        const gpu = this.device.createTexture({
            size: [descriptor.width, descriptor.height, descriptor.depthOrArrayLayers],
            format,
            mipLevelCount: descriptor.mipLevelCount,
            sampleCount: descriptor.sampleCount,
            usage,
        });
        this.objects.set(handle, { kind: 'texture', gpu, descriptor, format, views: new Map() });
    }

    writeTexture(handle, region, data) {
        const texture = this.objects.get(handle);
        if (!texture) return;
        const rowsPerImage = data.byteLength / region.bytesPerRow;
        this.device.queue.writeTexture({ texture: texture.gpu, mipLevel: region.mipLevel, origin: { x: region.x, y: region.y, z: region.slice } },
                                       data, { offset: 0, bytesPerRow: region.bytesPerRow, rowsPerImage },
                                       { width: region.width, height: region.height });
    }

    createSampler(handle, descriptor) {
        const anisotropic = descriptor.maxAnisotropy > 1
            && descriptor.magFilter === 'linear' && descriptor.minFilter === 'linear' && descriptor.mipmapFilter === 'linear';
        const gpu = this.device.createSampler({
            addressModeU: descriptor.addressModeU,
            addressModeV: descriptor.addressModeV,
            magFilter: descriptor.magFilter,
            minFilter: descriptor.minFilter,
            mipmapFilter: descriptor.mipmapFilter,
            maxAnisotropy: anisotropic ? descriptor.maxAnisotropy : 1,
        });
        this.objects.set(handle, { kind: 'sampler', gpu });
    }

    release(handle) {
        const object = this.objects.get(handle);
        if (object?.kind === 'buffer' || object?.kind === 'texture') object.gpu.destroy();
        this.objects.delete(handle);
    }

    /// A view of a texture for sampling, as its binding reads it.
    textureView(handle, binding) {
        const texture = handle ? this.objects.get(handle) : null;
        if (!texture) return this.placeholderView(binding);
        const key = `sample/${binding.viewDimension}`;
        let view = texture.views.get(key);
        if (!view) {
            const aspect = texture.format.includes('stencil') ? 'depth-only' : 'all';
            view = texture.gpu.createView({ dimension: binding.viewDimension, aspect });
            texture.views.set(key, view);
        }
        return view;
    }

    /// The view a pass draws into: the canvas's texture of the frame, or
    /// the first slice and level of a texture.
    attachmentView(handle) {
        if (handle === canvasHandle) {
            const texture = this.canvasTexture();
            if (!texture) throw new Error('A pass draws into the canvas, and the host has no canvas texture');
            return texture.createView();
        }
        const texture = this.objects.get(handle);
        let view = texture.views.get('attachment');
        if (!view) {
            view = texture.gpu.createView({ dimension: '2d', baseArrayLayer: 0, arrayLayerCount: 1, baseMipLevel: 0, mipLevelCount: 1 });
            texture.views.set('attachment', view);
        }
        return view;
    }

    // MARK: - Pipelines

    bindGroupLayout(entryPoint, group, visibility) {
        const key = `${entryPoint}/${group}`;
        let layout = this.layoutCache.get(key);
        if (!layout) {
            const bindings = entryPoint ? this.entryPoints.get(entryPoint).bindings.filter((binding) => binding.group === group) : [];
            layout = {
                bindings,
                gpu: this.device.createBindGroupLayout({
                    label: key,
                    entries: bindings.map((binding) => {
                        const entry = { binding: binding.binding, visibility };
                        if (binding.buffer) entry.buffer = binding.buffer;
                        if (binding.texture) entry.texture = binding.texture;
                        if (binding.sampler) entry.sampler = binding.sampler;
                        return entry;
                    }),
                }),
            };
            this.layoutCache.set(key, layout);
        }
        return layout;
    }

    createVariant(handle, state) {
        const pipeline = this.objects.get(state.pipeline).descriptor;
        const vertex = this.entryPoints.get(pipeline.vertex.entryPoint);
        const fragment = pipeline.fragment ? this.entryPoints.get(pipeline.fragment.entryPoint) : null;
        if (!vertex || (pipeline.fragment && !fragment)) {
            throw new Error(`${pipeline.label}: an entry point is in no WGSL module`);
        }
        const layouts = [
            this.bindGroupLayout(pipeline.vertex.entryPoint, 0, GPUShaderStage.VERTEX),
            this.bindGroupLayout(pipeline.fragment?.entryPoint ?? null, 1, GPUShaderStage.FRAGMENT),
        ];
        const topology = topologies[state.topology];
        const descriptor = {
            label: pipeline.label,
            layout: this.device.createPipelineLayout({ bindGroupLayouts: layouts.map((layout) => layout.gpu) }),
            vertex: {
                module: vertex.module,
                entryPoint: pipeline.vertex.entryPoint,
                constants: pipeline.vertex.constants,
                buffers: pipeline.buffers,
            },
            primitive: { topology, cullMode: cullModes[state.cull], frontFace: frontFaces[state.front] },
            multisample: { count: pipeline.sampleCount },
        };
        if (state.clamp === 1) {
            if (this.clampsDepth) {
                descriptor.primitive.unclippedDepth = true;
            } else if (vertex.hostClampsDepth) {
                // No depth-clip-control: the vertex stage clamps the depth
                // itself (kHostClampsDepth, RenderUniforms.wgsl).
                descriptor.vertex.constants = { ...pipeline.vertex.constants, 1000: 1 };
            }
        }
        if (pipeline.depthStencilFormat) {
            const format = this.textureFormat(pipeline.depthStencilFormat);
            const depth = state.depthStencil ? this.objects.get(state.depthStencil).descriptor : null;
            const depthStencil = {
                format,
                depthCompare: depth?.depthCompare ?? 'always',
                depthWriteEnabled: depth?.depthWriteEnabled ?? false,
            };
            if (format.includes('stencil') && depth?.usesStencil) {
                depthStencil.stencilFront = depth.stencilFront;
                depthStencil.stencilBack = depth.stencilBack;
                depthStencil.stencilReadMask = depth.stencilReadMask;
                depthStencil.stencilWriteMask = depth.stencilWriteMask;
            }
            // WebGPU takes no depth bias for lines and points.
            const biased = state.bias !== 0 || state.slopeScale !== 0 || state.biasClamp !== 0;
            if (biased && (topology === 'line-list' || topology === 'point-list')) {
                this.warnOnce(`${pipeline.label}: WebGPU takes no depth bias for ${topology}, drawn without one`);
            } else if (biased) {
                depthStencil.depthBias = Math.round(state.bias);
                depthStencil.depthBiasSlopeScale = state.slopeScale;
                depthStencil.depthBiasClamp = state.biasClamp;
            }
            descriptor.depthStencil = depthStencil;
        }
        const targets = pipeline.targets.map((target) => ({
            format: this.colorFormat(target.format),
            blend: target.blend ?? undefined,
            writeMask: target.writesColor ? GPUColorWrite.ALL : 0,
        }));
        if (fragment) {
            descriptor.fragment = { module: fragment.module, entryPoint: pipeline.fragment.entryPoint, constants: pipeline.fragment.constants, targets };
        } else if (targets.length > 0) {
            // A pipeline Metal makes without a fragment function beside a
            // colour target that writes nothing: WebGPU's pass refuses a
            // pipeline without its targets.
            descriptor.fragment = { module: this.emptyFragment, entryPoint: 'immersiveMapEmptyFragment', targets: targets.map((target) => ({ ...target, writeMask: 0 })) };
        }
        const vertexSlots = pipeline.buffers.flatMap((buffer, slot) => (buffer ? [slot] : []));
        this.objects.set(handle, { kind: 'variant', gpu: this.device.createRenderPipeline(descriptor), layouts, vertexSlots });
        this.counts.pipelines += 1;
    }

    // MARK: - Passes

    commandEncoder() {
        this.encoder ??= this.device.createCommandEncoder();
        return this.encoder;
    }

    beginRenderPass(word, float, string) {
        const colorAttachments = [];
        const count = word();
        for (let index = 0; index < count; index += 1) {
            const texture = word(), resolve = word(), load = word(), store = word();
            const clearValue = [float(), float(), float(), float()];
            const attachment = { view: this.attachmentView(texture), loadOp: loadOps[load], storeOp: storeOps[store], clearValue };
            if (resolve) attachment.resolveTarget = this.attachmentView(resolve);
            colorAttachments.push(attachment);
        }
        const descriptor = { colorAttachments };
        if (word() === 1) {
            const texture = word(), load = word(), store = word(), depthClearValue = float(), stencilClearValue = word();
            const attachment = { view: this.attachmentView(texture), depthLoadOp: loadOps[load], depthStoreOp: storeOps[store], depthClearValue };
            const format = texture === canvasHandle ? '' : this.objects.get(texture).format;
            if (format.includes('stencil')) {
                attachment.stencilLoadOp = loadOps[load];
                attachment.stencilStoreOp = storeOps[store];
                attachment.stencilClearValue = stencilClearValue;
            }
            descriptor.depthStencilAttachment = attachment;
        }
        descriptor.label = string() || undefined;
        this.pass = this.commandEncoder().beginRenderPass(descriptor);
        this.counts.passes += 1;
        this.variant = null;
        this.slots = [this.emptySlots(), this.emptySlots()];
        this.boundGroups = [null, null];
        this.boundVertexBuffers = new Map();
    }

    emptySlots() {
        return { buffers: new Map(), textures: new Map(), samplers: new Map(), dirty: true };
    }

    setSlot(stage, kind, index, value) {
        const slots = this.slots[stage];
        if (value === null) slots[kind].delete(index); else slots[kind].set(index, value);
        slots.dirty = true;
    }

    setVariant(handle) {
        this.variant = this.objects.get(handle);
        this.pass.setPipeline(this.variant.gpu);
        this.boundGroups = [null, null];
        this.slots[0].dirty = true;
        this.slots[1].dirty = true;
    }

    /// Constant data in this submission's uniform chunks: a 256-byte
    /// aligned place, bound as a buffer.
    uniformBytes(data) {
        // The chunks are written before each submission and reused by the
        // next: the queue runs a write after the commands submitted before.
        let chunk = this.uniformChunks.find((candidate) => candidate.used + data.byteLength <= uniformChunkSize);
        if (!chunk) {
            chunk = {
                gpu: this.device.createBuffer({ size: uniformChunkSize, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST, label: 'constant data' }),
                staging: new Uint8Array(uniformChunkSize),
                used: 0,
            };
            this.uniformChunks.push(chunk);
        }
        const offset = chunk.used;
        chunk.staging.set(data, offset);
        chunk.used = offset + Math.max(Math.ceil(data.byteLength / uniformAlignment), 1) * uniformAlignment;
        return { chunk, offset, length: chunk.used - offset };
    }

    bufferResource(slot, binding) {
        if (!slot) {
            return { buffer: this.placeholderBuffer, offset: 0, size: placeholderBufferSize };
        }
        if (slot.chunk) {
            return { buffer: slot.chunk.gpu, offset: slot.offset, size: slot.length };
        }
        const buffer = this.objects.get(slot.handle);
        let size = buffer.size - slot.offset;
        if (binding.buffer.type === 'uniform') size = Math.min(size, maxUniformBindingSize);
        return { buffer: buffer.gpu, offset: slot.offset, size };
    }

    /// The bind groups and vertex buffers of the variant's layouts from the
    /// slots, where they changed.
    prepareDraw() {
        this.counts.draws += 1;
        const variant = this.variant;
        if (!variant) throw new Error('A draw before any pipeline variant');
        for (let group = 0; group < 2; group += 1) {
            const slots = this.slots[group];
            if (!slots.dirty && this.boundGroups[group]) continue;
            const layout = variant.layouts[group];
            const entries = layout.bindings.map((binding) => {
                const index = binding.binding;
                let resource;
                if (binding.buffer) {
                    resource = this.bufferResource(slots.buffers.get(index), binding);
                } else if (binding.texture) {
                    resource = this.textureView(slots.textures.get(index - 16), binding.texture);
                } else if (index === 48) {
                    resource = this.comparisonSampler;
                } else if (index === 49) {
                    resource = this.linearSampler;
                } else {
                    const handle = slots.samplers.get(index - 32);
                    resource = handle ? this.objects.get(handle).gpu : this.linearSampler;
                }
                return { binding: index, resource };
            });
            const bindGroup = this.device.createBindGroup({ layout: layout.gpu, entries });
            this.pass.setBindGroup(group, bindGroup);
            this.counts.bindGroups += 1;
            this.boundGroups[group] = bindGroup;
            slots.dirty = false;
        }
        for (const slot of variant.vertexSlots) {
            const bound = this.slots[0].buffers.get(slot);
            if (!bound || bound.chunk) throw new Error(`A draw without its vertex buffer in slot ${slot}`);
            const key = `${bound.handle}/${bound.offset}`;
            if (this.boundVertexBuffers.get(slot) === key) continue;
            this.pass.setVertexBuffer(slot, this.objects.get(bound.handle).gpu, bound.offset);
            this.boundVertexBuffers.set(slot, key);
        }
    }

    /// Writes the submission's constant data and submits its commands.
    finish(id) {
        for (const chunk of this.uniformChunks) {
            if (chunk.used > 0) {
                this.device.queue.writeBuffer(chunk.gpu, 0, chunk.staging.buffer, 0, chunk.used);
                chunk.used = 0;
            }
        }
        const buffers = this.encoder ? [this.encoder.finish()] : [];
        this.encoder = null;
        this.device.queue.submit(buffers);
        this.counts.submissions += 1;
        this.device.queue.onSubmittedWorkDone().then(() => this.completed(id));
    }
}
