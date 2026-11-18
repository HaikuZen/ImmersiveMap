// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// The types of ImmersiveMap.mjs, the map for a page.

/** A point on the Earth, in degrees. */
export interface Coordinate {
    latitude: number;
    longitude: number;
}

/** Where the camera is. The bearing and the pitch are in radians. */
export interface CameraPosition extends Coordinate {
    zoom: number;
    bearing: number;
    pitch: number;
}

/** The tile archive's requests so far. */
export interface Downloads {
    /** From the browser's storage or the network. */
    answered: number;
    /** Answered from the browser's storage (the tile cache). */
    cached: number;
    /** `fetch` threw (as it does when the archive's host refuses the page's origin) or an HTTP error came back. */
    failed: number;
    /** The first failure's text, null while there is none. */
    firstFailure: string | null;
}

export interface ImmersiveMapOptions {
    /**
     * The folder Web/map/build.sh writes: the module, the shader bundle and
     * the resources. `build/` beside ImmersiveMap.mjs by default.
     */
    assets?: string | URL;
    /**
     * The PMTiles archive of the tiles, the engine's own when empty. Its host
     * must allow the page's origin (CORS), or serve it from the page's site.
     */
    archive?: string;
    /**
     * Keeps the archives' ranges in the browser's storage (OPFS), so a page
     * loaded again reads them from there. On by default where the browser
     * lets the page write it, at most 256 MB unless `maxBytes` says, the
     * oldest dropped past it. An archive replaced on its host (a new ETag,
     * or a new Last-Modified where the ETag is not exposed) is read anew.
     * False turns it off.
     */
    tileCache?: boolean | { maxBytes?: number };
    /** MSAA 4x. True by default. */
    multisample?: boolean;
    /** Where the camera starts, looking straight down. */
    camera?: Coordinate & { zoom?: number };
    /**
     * Whether the pointer, the wheel and touch move the camera. True by
     * default. A fast release of a drag lets the globe glide on, by the
     * engine's pan inertia settings.
     */
    interactive?: boolean;
    /** How often a still map runs the module's due work, in milliseconds. 250 by default. */
    idleTickInterval?: number;
    /** A WebGPU error or the device lost. `console.error` by default. */
    onError?: (message: string) => void;
    /** A warning of the WebGPU host. `console.warn` by default. */
    onWarning?: (message: string) => void;
    /** After each failed request of the tile archive. The engine only logs them. */
    onDownloadFailure?: (downloads: Downloads) => void;
}

export interface MarkerOptions extends Coordinate {
    /**
     * The page's element kept over the point. It inherits
     * `pointer-events: none`, so a drag over it moves the map; set
     * `pointer-events: auto` on it to make it clickable.
     */
    element: HTMLElement;
    /** The point of the element's box put on the coordinate, from 0 to 1 across it. The centre by default. */
    anchor?: [number, number];
}

export interface Marker {
    readonly element: HTMLElement;
    /** Moves the marker to the point. */
    setPosition(coordinate: Coordinate): void;
    /** Takes the marker and its element away. */
    remove(): void;
}

export declare class ImmersiveMap {
    /**
     * Makes the map in the element, which it fills: a canvas and a layer of
     * markers over it. Rejects when the browser has no WebGPU or the module
     * does not load.
     */
    static create(container: HTMLElement, options?: ImmersiveMapOptions): Promise<ImmersiveMap>;

    private constructor();

    /** Where the camera is, null once destroyed. */
    readonly camera: CameraPosition | null;
    /** The tile archive's requests so far. */
    readonly downloads: Downloads;

    /** Puts the camera over the point at the zoom (the current one if left out), looking straight down. */
    lookAt(position: Coordinate & { zoom?: number }): void;
    /** Moves the map as a drag of the points does, with no glide after. */
    panBy(dx: number, dy: number): void;
    /** Zooms by the levels, positive in. */
    zoomBy(levels: number): void;
    /** Turns the camera about the map's centre and tilts it, in radians. */
    orbitBy(yaw: number, pitch?: number): void;

    /**
     * Keeps the element over the point. It is faded near the globe's horizon
     * and hidden beyond it.
     */
    addMarker(options: MarkerOptions): Marker;

    /** Stops drawing, lets go of the input and the GPU device, and takes the canvas and the markers out of the element. */
    destroy(): void;
}
