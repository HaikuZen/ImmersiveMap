// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// The map for a page: `ImmersiveMap.create(container, options)` fills the
// element with a canvas the engine draws into (the ImmersiveMapWebMap
// module through the page's WebGPU device, map.mjs), takes the pointer, the
// wheel and two-finger touch as camera moves, draws only when something
// changed, and keeps the page's marker elements over the points they mark.
// The types are in ImmersiveMap.d.ts. The module, the shader bundle and the
// resources are what Web/map/build.sh writes, found in `build/` beside this
// file unless `assets` names another folder.

import { chooseFeatures } from '../ImmersiveMapWebGPU.js';
import { startMap, fetchResources } from './map.mjs';

/// How a drag and the wheel move the camera.
const input = {
    /// A wheel notch (100 pixels) is a fifth of a level.
    wheelPixelsPerLevel: 500,
    /// A line of a wheel that scrolls by lines, in pixels.
    wheelLinePixels: 33,
    /// A drag across the whole width turns the camera half a turn, one
    /// across the whole height tilts it a quarter of one.
    orbitYawPerWidth: Math.PI,
    orbitPitchPerHeight: Math.PI * 0.5,
};

/// A key only `create` holds, so the constructor is not called directly.
const creating = Symbol('ImmersiveMap.create');

export class ImmersiveMap {
    /// Makes the map in the element, which it fills: a canvas and a layer
    /// of markers over it. Rejects when the browser has no WebGPU or the
    /// module does not load.
    static async create(container, options = {}) {
        if (!(container instanceof HTMLElement)) throw new TypeError('ImmersiveMap needs an element to fill');
        if (!navigator.gpu) throw new Error('This browser has no WebGPU.');
        const adapter = await navigator.gpu.requestAdapter();
        if (!adapter) throw new Error('No WebGPU adapter.');
        const device = await adapter.requestDevice({ requiredFeatures: chooseFeatures(adapter) });
        try {
            return await new ImmersiveMap(creating, container, device, options).#start(options);
        } catch (error) {
            device.destroy();
            throw error;
        }
    }

    #container;
    #device;
    #canvas;
    #markerLayer;
    #map = null;
    #options;
    #markers = new Map();
    #nextMarkerID = 1;
    #frameRequest = null;
    #idleTick = null;
    #listeners = new AbortController();
    #resizeObserver = null;
    #destroyed = false;

    constructor(key, container, device, options) {
        if (key !== creating) throw new TypeError('Make an ImmersiveMap with ImmersiveMap.create');
        this.#container = container;
        this.#device = device;
        this.#options = {
            idleTickInterval: 250,
            interactive: true,
            onError: (message) => console.error(message),
            onWarning: (message) => console.warn(message),
            onDownloadFailure: () => {},
            ...options,
        };
        device.addEventListener('uncapturederror', (event) => this.#options.onError(`WebGPU: ${event.error.message}`));
        device.lost.then((info) => {
            if (!this.#destroyed) this.#options.onError(`The WebGPU device was lost: ${info.message}`);
        });

        if (getComputedStyle(container).position === 'static') container.style.position = 'relative';
        this.#canvas = document.createElement('canvas');
        Object.assign(this.#canvas.style, { display: 'block', width: '100%', height: '100%', touchAction: 'none' });
        // The markers inherit `pointer-events: none` from their layer, so a
        // drag over one moves the map. A marker meant to be clicked sets
        // `pointer-events: auto` on its element.
        this.#markerLayer = document.createElement('div');
        Object.assign(this.#markerLayer.style, { position: 'absolute', inset: '0', overflow: 'hidden', pointerEvents: 'none' });
        container.append(this.#canvas, this.#markerLayer);
    }

    async #start({ assets, archive = '', multisample = true, camera }) {
        const base = new URL(String(assets ?? new URL('./build/', import.meta.url)), document.baseURI);
        if (!base.pathname.endsWith('/')) base.pathname += '/';
        const context = this.#canvas.getContext('webgpu');
        // The engine's pipelines draw bgra8unorm, which every canvas takes.
        context.configure({ device: this.#device, format: 'bgra8unorm', alphaMode: 'opaque' });

        const [shaders, module, resources] = await Promise.all([
            fetch(new URL('shaders.json', base)).then((response) => {
                if (!response.ok) throw new Error(`The shader bundle did not load (HTTP ${response.status})`);
                return response.json();
            }),
            WebAssembly.compileStreaming(fetch(new URL('ImmersiveMapWebMap.wasm', base))),
            fetchResources(new URL('resources', base).href),
        ]);
        this.#map = await startMap({
            device: this.#device,
            module,
            shaders,
            resources,
            canvasTexture: () => context.getCurrentTexture(),
            archiveURL: archive,
            multisample,
            warn: (message) => this.#options.onWarning(message),
            wake: () => this.#wake(),
            downloadFailed: (downloads) => this.#options.onDownloadFailure({ ...downloads }),
        });
        if (camera) this.lookAt(camera);
        if (this.#options.interactive) this.#listen();
        this.#resizeObserver = new ResizeObserver(() => this.#wake());
        this.#resizeObserver.observe(this.#canvas);
        this.#wake();
        return this;
    }

    // MARK: - Camera

    /// Where the camera is: `{ latitude, longitude, zoom, bearing, pitch }`,
    /// the bearing and the pitch in radians.
    get camera() {
        return this.#map?.camera() ?? null;
    }

    /// Puts the camera over the point at the zoom, looking straight down.
    lookAt({ latitude, longitude, zoom }) {
        this.#map?.look(latitude, longitude, zoom ?? this.camera?.zoom ?? 2);
    }

    /// Moves the map as a drag of the points does.
    panBy(dx, dy) {
        this.#map?.pan(dx, dy, true);
    }

    /// Zooms by the levels, positive in.
    zoomBy(levels) {
        this.#map?.zoom(levels);
    }

    /// Turns the camera about the map's centre and tilts it, in radians.
    orbitBy(yaw, pitch = 0) {
        this.#map?.orbit(yaw, pitch);
    }

    // MARK: - Markers

    /// Keeps the element over the point, its `anchor` (`[x, y]`, from 0 to
    /// 1 across its box, the centre by default) on it. The element is put
    /// in the map's marker layer, faded near the globe's horizon and hidden
    /// beyond it. Returns the marker, to move or remove.
    addMarker({ latitude, longitude, element, anchor = [0.5, 0.5] }) {
        if (!(element instanceof HTMLElement)) throw new TypeError('A marker needs an element');
        const id = this.#nextMarkerID;
        this.#nextMarkerID = this.#nextMarkerID >= 0xFFFFFFFF ? 1 : this.#nextMarkerID + 1;
        const map = this;
        const entry = { element, anchor };
        Object.assign(element.style, { position: 'absolute', left: '0', top: '0', visibility: 'hidden', willChange: 'transform' });
        this.#markerLayer.append(element);
        this.#markers.set(id, entry);
        this.#map?.setMarker(id, latitude, longitude);
        return {
            element,
            /// Moves the marker to the point.
            setPosition({ latitude, longitude }) {
                if (map.#markers.has(id)) map.#map?.setMarker(id, latitude, longitude);
            },
            /// Takes the marker and its element away.
            remove() {
                if (!map.#markers.delete(id)) return;
                element.remove();
                map.#map?.removeMarker(id);
            },
        };
    }

    #placeMarkers() {
        const shown = new Set();
        for (const { id, x, y, alpha } of this.#map.markers()) {
            const entry = this.#markers.get(id);
            if (!entry) continue;
            shown.add(id);
            const [anchorX, anchorY] = entry.anchor;
            entry.element.style.visibility = 'visible';
            entry.element.style.opacity = String(alpha);
            entry.element.style.transform = `translate(${x}px, ${y}px) translate(${-anchorX * 100}%, ${-anchorY * 100}%)`;
        }
        for (const [id, entry] of this.#markers) {
            if (!shown.has(id)) entry.element.style.visibility = 'hidden';
        }
    }

    // MARK: - State

    /// The tile archive's requests: `{ answered, failed, firstFailure }`.
    get downloads() {
        return this.#map ? { ...this.#map.downloads } : { answered: 0, failed: 0, firstFailure: null };
    }

    /// Stops drawing, lets go of the input and the GPU device, and takes the
    /// canvas and the markers out of the element.
    destroy() {
        if (this.#destroyed) return;
        this.#destroyed = true;
        if (this.#frameRequest !== null) cancelAnimationFrame(this.#frameRequest);
        if (this.#idleTick !== null) clearTimeout(this.#idleTick);
        this.#listeners.abort();
        this.#resizeObserver?.disconnect();
        this.#canvas.remove();
        this.#markerLayer.remove();
        this.#markers.clear();
        this.#map = null;
        this.#device.destroy();
    }

    // MARK: - Frames

    /// Asks for an animation frame, at once: the map may have changed.
    #wake() {
        if (this.#destroyed || !this.#map) return;
        if (this.#idleTick !== null) {
            clearTimeout(this.#idleTick);
            this.#idleTick = null;
        }
        this.#frameRequest ??= requestAnimationFrame(() => this.#frame());
    }

    /// Draws when the map needs it, and keeps asking for animation frames
    /// while it does. A still map is asked again a few times a second, so
    /// the module's timers (a download's retry) still run.
    #frame() {
        this.#frameRequest = null;
        if (this.#destroyed) return;
        const scale = window.devicePixelRatio || 1;
        const width = Math.max(1, Math.round(this.#canvas.clientWidth * scale));
        const height = Math.max(1, Math.round(this.#canvas.clientHeight * scale));
        if (this.#canvas.width !== width || this.#canvas.height !== height) {
            this.#canvas.width = width;
            this.#canvas.height = height;
        }
        const { needsFrame, drew } = this.#map.frame(width, height, scale);
        if (drew) this.#placeMarkers();
        if (needsFrame) {
            this.#wake();
        } else if (this.#idleTick === null) {
            this.#idleTick = setTimeout(() => {
                this.#idleTick = null;
                this.#wake();
            }, this.#options.idleTickInterval);
        }
    }

    // MARK: - Input

    /// One pointer drags the map, or turns and tilts it with the secondary
    /// button or Shift. Two pointers (a pinch) zoom and drag it. The wheel
    /// zooms. All in points (CSS pixels).
    #listen() {
        const canvas = this.#canvas;
        const signal = this.#listeners.signal;
        const pointers = new Map();
        let orbiting = false;
        let panning = false;
        const endPan = () => {
            if (panning) this.#map?.pan(0, 0, true);
            panning = false;
        };
        const pinch = () => {
            const [a, b] = [...pointers.values()];
            return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, distance: Math.hypot(a.x - b.x, a.y - b.y) };
        };
        let lastPinch = null;

        canvas.addEventListener('contextmenu', (event) => event.preventDefault(), { signal });
        canvas.addEventListener('pointerdown', (event) => {
            canvas.setPointerCapture(event.pointerId);
            pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
            if (pointers.size === 1) {
                orbiting = event.button === 2 || event.shiftKey;
            } else if (pointers.size === 2) {
                // A second finger ends the one-finger drag and starts a pinch.
                endPan();
                orbiting = false;
                lastPinch = pinch();
            }
        }, { signal });
        canvas.addEventListener('pointermove', (event) => {
            const pointer = pointers.get(event.pointerId);
            if (!pointer || !this.#map) return;
            const dx = event.clientX - pointer.x;
            const dy = event.clientY - pointer.y;
            pointer.x = event.clientX;
            pointer.y = event.clientY;
            if (pointers.size === 1) {
                if (orbiting) {
                    this.#map.orbit((dx / canvas.clientWidth) * input.orbitYawPerWidth,
                                    (dy / canvas.clientHeight) * input.orbitPitchPerHeight);
                } else {
                    panning = true;
                    this.#map.pan(dx, dy);
                }
            } else if (pointers.size === 2 && lastPinch) {
                const now = pinch();
                if (lastPinch.distance > 0 && now.distance > 0) this.#map.zoom(Math.log2(now.distance / lastPinch.distance));
                panning = true;
                this.#map.pan(now.x - lastPinch.x, now.y - lastPinch.y);
                lastPinch = now;
            }
        }, { signal });
        const lift = (event) => {
            if (!pointers.delete(event.pointerId)) return;
            endPan();
            lastPinch = null;
            // The finger left on the screen after a pinch starts a drag of
            // its own.
            orbiting = false;
        };
        canvas.addEventListener('pointerup', lift, { signal });
        canvas.addEventListener('pointercancel', lift, { signal });
        canvas.addEventListener('wheel', (event) => {
            event.preventDefault();
            const pixels = event.deltaMode === 1 ? event.deltaY * input.wheelLinePixels
                : event.deltaMode === 2 ? event.deltaY * canvas.clientHeight
                : event.deltaY;
            this.#map?.zoom(-pixels / input.wheelPixelsPerLevel);
        }, { signal });
    }
}
