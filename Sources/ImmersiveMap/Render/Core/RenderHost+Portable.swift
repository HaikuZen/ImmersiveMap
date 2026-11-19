// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import os
import PortableFoundation

extension RenderHost {
    private static let logger = Logger(subsystem: "ImmersiveMap", category: "Render")

    /// The host of a platform with nothing of its own to hand the core (a
    /// browser page): the engine's resources made on the device from the
    /// resources folder, the POI icons' atlas the host drew (`poiAtlas`,
    /// the pixels of `PoiSpriteAtlasLayout.hostDescription`'s atlas, or no
    /// icons where it drew none, as Apple's symbols are drawn on Apple's
    /// platforms alone), the tiles, the model tiles and the trees copied
    /// from memory, no scene model assets, and the pins of `pins` when it
    /// is given, drawn with the bubble's field from the resources folder.
    /// Without the resources folder the text has no atlases and no label
    /// draws a glyph, and there are no pins, which is logged, as is an
    /// atlas of the wrong size.
    static func portable(device: any GPUDevice,
                         commandQueue: any GPUCommandQueue,
                         sampleCount: Int,
                         poiAtlas: [UInt8]? = nil,
                         pins: (source: any PinRenderSource, settings: ImmersiveMapSettings.PinSettings)? = nil) -> RenderHost {
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
                          poiSpriteTexture: poiAtlasTexture(device: device, pixels: poiAtlas),
                          tileFileGeometry: nil,
                          modelTileFileLoader: nil,
                          treeFileLoader: nil,
                          layerFileLoader: nil,
                          loadSceneModelAsset: { _ in throw SceneModelAssetsUnavailable() },
                          makePinSubsystem: pinSubsystemMaker(device: device,
                                                              resources: resources,
                                                              resource: { location?.url(forResource: $0, withExtension: $1) },
                                                              pins: pins))
    }

    /// The pins' subsystem, as Apple's host makes it: pipelines of one
    /// sample for the overlay pass, the bubble's field decoded from the
    /// resources folder. Nil without pins, or without the bubble's files.
    static func pinSubsystemMaker(device: any GPUDevice,
                                  resources: RenderResources,
                                  resource: (String, String) -> URL?,
                                          pins: (source: any PinRenderSource, settings: ImmersiveMapSettings.PinSettings)?)
        -> (() -> any RenderSubsystem & RenderPassAvailabilityProvider)? {
        guard let pins else { return nil }
        let pinSDF: PinSDFResource
        do {
            pinSDF = try PinSDFResource.load(device: device, resource: resource)
        } catch {
            logger.warning("ImmersiveMap: the pins' bubble did not load (\(String(describing: error), privacy: .public)). The map draws no pins.")
            return nil
        }
        let shared = PinsRenderer.SharedResources.make(device: device, pixelFormat: .bgra8Unorm, pinSDF: pinSDF, sampleCount: 1)
        let renderer = PinsRenderer(device: device, sharedResources: shared, config: pins.settings)
        let depthDisabledState = resources.depthDisabledState
        return {
            PinRenderSubsystem(pinsRenderer: renderer,
                               pinSource: pins.source,
                               depthDisabledState: depthDisabledState)
        }
    }

    /// A scene model's asset is read with Model I/O, on Apple's platforms
    /// alone.
    struct SceneModelAssetsUnavailable: Error, CustomStringConvertible {
        var description: String { "This platform reads no scene model asset." }
    }

    /// The POI atlas from the host's pixels, or a clear texel where it gave
    /// none that fit the layout.
    private static func poiAtlasTexture(device: any GPUDevice, pixels: [UInt8]?) -> any GPUTexture {
        guard let pixels else { return clearTexel(device: device) }
        let side = PoiSpriteAtlasLayout().pixelSize
        guard pixels.count == side * side * 4 else {
            logger.warning("ImmersiveMap: the POI icons' atlas has \(pixels.count, privacy: .public) bytes, not the \(side * side * 4, privacy: .public) of a \(side, privacy: .public) pixel square. The POIs draw no icons.")
            return clearTexel(device: device)
        }
        var descriptor = GPUTextureDescriptor(format: .bgra8Unorm, width: side, height: side)
        descriptor.storage = .shared
        guard let texture = device.makeTexture(descriptor) else {
            fatalError("The device made no POI atlas texture")
        }
        pixels.withUnsafeBytes { bytes in
            texture.replace(x: 0, y: 0, width: side, height: side, mipmapLevel: 0, slice: 0,
                            bytes: bytes.baseAddress!, bytesPerRow: side * 4)
        }
        return texture
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
