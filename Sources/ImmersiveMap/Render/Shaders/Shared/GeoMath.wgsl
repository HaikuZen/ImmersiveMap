// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// ported-from: GeoMath.metal fnv1a64=e473013aa018450b

// The map's small geographic helpers. Only what a ported shader reads is
// here so far.

const kPi = 3.14159265358979;
const kHalfPi = 1.5707963267948966;

/// x folded into the copy of the world nearest 0: [-size / 2, size / 2).
fn wrap(x: f32, size: f32) -> f32 {
    return x - size * floor((x + size * 0.5) / size);
}

/// The normalized Mercator y of a latitude, in [-1, 1], the latitude
/// clamped to the Mercator square's.
fn getYMercNorm(latitude: f32) -> f32 {
    let sinPan = sin(latitude);
    let maxSinPan = tanh(kPi);
    let clampedSinPan = max(-maxSinPan, min(maxSinPan, sinPan));
    let yPanMerc = 0.5 * log((1.0 + clampedSinPan) / (1.0 - clampedSinPan));
    return yPanMerc / kPi;
}
