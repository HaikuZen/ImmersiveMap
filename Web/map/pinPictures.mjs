// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// The pins' pictures the page draws, with a 2D canvas, where Apple's
// platforms draw them with Core Graphics: a shape's coverage, a merged
// pin's counter and the placeholder, each as `PinPictureDrawing` describes
// it (Sources/ImmersiveMap/Pins/PinPictureDrawing.swift), and a picture's
// pixels, of an element of the page's or loaded from a URL. Without a 2D
// canvas (Node) `makePinPictures` returns null and the map draws its pins
// without them.

/// A canvas of the size and its 2D context, or null where there is none.
function canvas2D(width, height) {
    if (typeof OffscreenCanvas === 'function') {
        const context = new OffscreenCanvas(width, height).getContext('2d', { willReadFrequently: true });
        if (context) return context;
    }
    if (typeof document === 'object' && document?.createElement) {
        const canvas = document.createElement('canvas');
        canvas.width = width;
        canvas.height = height;
        return canvas.getContext('2d', { willReadFrequently: true });
    }
    return null;
}

/// The canvas's pixels (straight RGBA) as the atlas's: premultiplied BGRA.
function premultipliedBGRA(rgba) {
    const out = new Uint8Array(rgba.length);
    for (let index = 0; index < rgba.length; index += 4) {
        const alpha = rgba[index + 3];
        out[index] = Math.round((rgba[index + 2] * alpha) / 255);
        out[index + 1] = Math.round((rgba[index + 1] * alpha) / 255);
        out[index + 2] = Math.round((rgba[index] * alpha) / 255);
        out[index + 3] = alpha;
    }
    return out;
}

/// The parts' JSON (BrowserPins.json(of:)) as one path per part.
function paths(json) {
    return JSON.parse(json).map((commands) => {
        const path = new Path2D();
        for (const [command, ...values] of commands) {
            if (command === 'M') path.moveTo(...values);
            else if (command === 'L') path.lineTo(...values);
            else if (command === 'Q') path.quadraticCurveTo(...values);
            else if (command === 'C') path.bezierCurveTo(...values);
            else if (command === 'Z') path.closePath();
        }
        return path;
    });
}

/// The page's drawer and loader of the pins' pictures, or null where the
/// page has no 2D canvas.
export function makePinPictures() {
    if (!canvas2D(1, 1)) return null;
    return {
        /// Whether each sample of a `side` square lies inside the shape's
        /// parts: 1 where it is at least half white, the parts filled white
        /// on black inside the margin.
        coverage(json, side, margin) {
            const context = canvas2D(side, side);
            context.fillStyle = '#000';
            context.fillRect(0, 0, side, side);
            context.translate(margin * side, margin * side);
            context.scale(side * (1 - 2 * margin), side * (1 - 2 * margin));
            context.beginPath();
            context.rect(0, 0, 1, 1);
            context.clip();
            context.fillStyle = '#fff';
            for (const path of paths(json)) context.fill(path, 'nonzero');
            const pixels = context.getImageData(0, 0, side, side).data;
            const inside = new Uint8Array(side * side);
            for (let index = 0; index < inside.length; index += 1) inside[index] = pixels[index * 4] >= 128 ? 1 : 0;
            return inside;
        },

        /// A merged pin's counter: a white disc, its edge darkened a little,
        /// and the number in bold, dark grey.
        badge(text, side) {
            const context = canvas2D(side, side);
            const inset = Math.max(side * 0.05, 1.5);
            const radius = side / 2 - inset;
            context.beginPath();
            context.arc(side / 2, side / 2, radius, 0, Math.PI * 2);
            context.fillStyle = '#fff';
            context.fill();
            context.lineWidth = Math.max(side * 0.03, 1);
            context.strokeStyle = 'rgba(0, 0, 0, 0.10)';
            context.stroke();
            const characters = [...text].length;
            const scale = characters <= 2 ? 1 : (characters === 3 ? 0.82 : 0.66);
            context.font = `bold ${side * 0.44 * scale}px system-ui, -apple-system, "Segoe UI", Roboto, sans-serif`;
            context.textAlign = 'center';
            context.textBaseline = 'middle';
            context.fillStyle = 'rgb(20, 20, 20)';
            context.fillText(text, side / 2, side / 2);
            return premultipliedBGRA(context.getImageData(0, 0, side, side).data);
        },

        /// The picture a pin shows while its own loads: a figure's head and
        /// shoulders on a dark square.
        placeholder(side) {
            const context = canvas2D(side, side);
            const unit = side / 64;
            context.fillStyle = 'rgb(46, 51, 61)';
            context.fillRect(0, 0, side, side);
            context.fillStyle = 'rgb(107, 117, 133)';
            for (const [x, y, width, height] of [[22, 14, 20, 20], [14, 38, 36, 22]]) {
                context.beginPath();
                context.ellipse((x + width / 2) * unit, (y + height / 2) * unit,
                                (width / 2) * unit, (height / 2) * unit, 0, 0, Math.PI * 2);
                context.fill();
            }
            return premultipliedBGRA(context.getImageData(0, 0, side, side).data);
        },

        /// The pixels of a picture of the page's: `{ width, height, rgba }`,
        /// straight RGBA. An `ImageData` is taken as it is.
        pixels(source) {
            if (typeof ImageData === 'function' && source instanceof ImageData) {
                return { width: source.width, height: source.height, rgba: source.data };
            }
            const width = source.naturalWidth ?? source.videoWidth ?? source.displayWidth ?? source.width;
            const height = source.naturalHeight ?? source.videoHeight ?? source.displayHeight ?? source.height;
            if (!(width > 0 && height > 0)) throw new TypeError('A pin\'s picture has no pixels (an image not loaded yet?)');
            const context = canvas2D(width, height);
            context.drawImage(source, 0, 0, width, height);
            return { width, height, rgba: context.getImageData(0, 0, width, height).data };
        },

        /// The picture at the URL, fetched and decoded: `{ width, height,
        /// rgba }`. A picture of another origin needs that origin to allow
        /// the page's (CORS).
        async load(url) {
            const response = await fetch(url);
            if (!response.ok) throw new Error(`HTTP ${response.status} for ${url}`);
            const bitmap = await createImageBitmap(await response.blob());
            try {
                return this.pixels(bitmap);
            } finally {
                bitmap.close();
            }
        },
    };
}
