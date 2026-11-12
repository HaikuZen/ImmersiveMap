// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

/// The texture a raster tile is drawn into (`RasterTileRenderSubsystem`):
/// a square of the ring rule's size, with its mip chain, private to the
/// GPU, kept from frame to frame and filled again only when what it shows
/// changes, copied from the frame's atlas pass and sampled by the frame's
/// draws. The texture itself is made on Metal (`RasterTileTexture+Metal.swift`)
/// until the raster tiles' passes move.
enum RasterTileTexture {
    /// The texture format: the colour the engine renders in, unconverted.
    /// The world pass draws into `bgra8Unorm` and blends there, so the
    /// texture keeps the same encoded values, and a raster tile shows the
    /// colours its geometry would.
    static let format: GPUPixelFormat = .rgba8Unorm
}
