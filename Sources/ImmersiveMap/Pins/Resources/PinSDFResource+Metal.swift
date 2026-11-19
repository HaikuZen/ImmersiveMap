// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
import ImmersiveMapGPU
import ImmersiveMapMetal
import Metal
import MetalKit

extension PinSDFResource {
    /// The bubble read by Metal's texture loader on Apple's platforms.
    /// `bundle` is the engine's resource bundle (`ImmersiveMapResourceBundle`).
    static func load(device: MTLDevice, bundle: Bundle) throws -> PinSDFResource {
        let urls = try resourceURLs { bundle.url(forResource: $0, withExtension: $1) }
        let textureLoader = MTKTextureLoader(device: device)
        let texture: MTLTexture
        do {
            texture = try textureLoader.newTexture(URL: urls.texture,
                                                   options: [
                                                       .SRGB: false
                                                   ])
        } catch {
            throw PinSDFResourceError.failedToLoadTexture(urls.texture, error)
        }
        guard let format = GPUPixelFormat(metal: texture.pixelFormat) else {
            fatalError("The GPU interface has no name for the pin bubble's format \(texture.pixelFormat.rawValue)")
        }
        return try PinSDFResource(texture: MetalTexture(texture, format: format), metadataURL: urls.metadata)
    }
}
