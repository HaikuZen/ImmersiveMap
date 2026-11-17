// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import os
import PortableFoundation

extension RenderHost {
    private static let logger = Logger(subsystem: "ImmersiveMap", category: "Render")

    /// The host of a platform with nothing of its own to hand the core (a
    /// browser page): the engine's resources made on the device from the
    /// resources folder, no POI icons (a clear texel, as the icons are
    /// drawn with Apple's symbols), the tiles, the model tiles and the
    /// trees copied from memory, no scene model assets and no avatars.
    /// Without the resources folder the text has no atlases and no label
    /// draws a glyph, which is logged.
    static func portable(device: any GPUDevice,
                         commandQueue: any GPUCommandQueue,
                         sampleCount: Int) -> RenderHost {
        let location: ImmersiveMapResourceLocation?
        do {
            location = try ImmersiveMapResourceBundle.location()
        } catch {
            logger.warning("ImmersiveMap: \(String(describing: error), privacy: .public) The labels draw no text.")
            location = nil
        }
        let resources = RenderResources(device: device,
                                        colorFormat: .bgra8Unorm,
                                        sampleCount: sampleCount,
                                        resource: { location?.url(forResource: $0, withExtension: $1) })
        return RenderHost(resources: resources,
                          commandQueue: commandQueue,
                          poiSpriteTexture: clearTexel(device: device),
                          tileFileGeometry: nil,
                          modelTileFileLoader: nil,
                          treeFileLoader: nil,
                          loadSceneModelAsset: { _ in throw SceneModelAssetsUnavailable() },
                          makeAvatarSubsystem: nil)
    }

    /// A scene model's asset is read with Model I/O, on Apple's platforms
    /// alone.
    struct SceneModelAssetsUnavailable: Error, CustomStringConvertible {
        var description: String { "This platform reads no scene model asset." }
    }

    /// One transparent texel in the POI atlas's format: every icon samples
    /// nothing.
    private static func clearTexel(device: any GPUDevice) -> any GPUTexture {
        var descriptor = GPUTextureDescriptor(format: .bgra8Unorm, width: 1, height: 1)
        descriptor.storage = .shared
        guard let texture = device.makeTexture(descriptor) else {
            fatalError("The device made no 1x1 texture")
        }
        let clear: UInt32 = 0
        withUnsafeBytes(of: clear) { bytes in
            texture.replace(x: 0, y: 0, width: 1, height: 1, mipmapLevel: 0, slice: 0,
                            bytes: bytes.baseAddress!, bytesPerRow: 4)
        }
        return texture
    }
}
