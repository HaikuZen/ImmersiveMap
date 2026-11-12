// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapMetal
import Metal

extension RasterTileTexture {
    /// The texture format as Metal's, for the raster tiles' passes still on
    /// Metal. It goes when they move.
    static var pixelFormat: MTLPixelFormat { format.metal }

    static func make(device: MTLDevice, size: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
                                                                  width: size,
                                                                  height: size,
                                                                  mipmapped: true)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = "RasterTile.\(size)"
        return texture
    }
}
