// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  PinSDFResource.swift
//  ImmersiveMap
//

import ImmersiveMapGPU
import PortableFoundation
import PortableImage

struct PinSDFParams {
    var distanceRangeTexels: Float
}

struct PinSDFShapeMetrics {
    var pointerHeightRatio: Float
}

struct PinSDFMetadata: Decodable {
    let schemaVersion: Int
    let distanceRangeTexels: Float
    let imageWidth: Int
    let imageHeight: Int
    let pointerHeightRatio: Float
}

enum PinSDFResourceError: Error {
    case missingTextureResource(String)
    case missingMetadataResource(String)
    case failedToLoadTexture(URL, Error)
    case failedToDecodeMetadata(URL, Error)
    case incompatibleMetadataSchema(Int)
    case metadataTextureSizeMismatch(expectedWidth: Int, expectedHeight: Int, actualWidth: Int, actualHeight: Int)
}

/// The built-in bubble: its distance field, kept in the alpha of an RGBA
/// picture in the resources (`pin_sdf.png`), and what its metadata
/// (`pin_sdf.json`) says of it. Metal's texture loader reads the picture on
/// Apple's platforms (`PinSDFResource+Metal.swift`), the engine's PNG
/// decoder elsewhere (`load(device:resource:)`).
final class PinSDFResource {
    static let baseName = "pin_sdf"
    static let supportedSchemaVersion = 1

    let texture: any GPUTexture
    let params: PinSDFParams
    let shapeMetrics: PinSDFShapeMetrics

    /// The bubble of a texture already loaded, checked against its metadata.
    init(texture: any GPUTexture, metadataURL: URL) throws {
        let metadata: PinSDFMetadata
        do {
            let data = try Data(contentsOf: metadataURL)
            metadata = try JSONDecoder().decode(PinSDFMetadata.self, from: data)
        } catch {
            throw PinSDFResourceError.failedToDecodeMetadata(metadataURL, error)
        }

        guard metadata.schemaVersion == Self.supportedSchemaVersion else {
            throw PinSDFResourceError.incompatibleMetadataSchema(metadata.schemaVersion)
        }
        guard metadata.imageWidth == texture.width,
              metadata.imageHeight == texture.height else {
            throw PinSDFResourceError.metadataTextureSizeMismatch(expectedWidth: metadata.imageWidth,
                                                                  expectedHeight: metadata.imageHeight,
                                                                  actualWidth: texture.width,
                                                                  actualHeight: texture.height)
        }

        self.texture = texture
        self.params = PinSDFParams(distanceRangeTexels: metadata.distanceRangeTexels)
        self.shapeMetrics = PinSDFShapeMetrics(pointerHeightRatio: metadata.pointerHeightRatio)
    }

    /// The URLs of the picture and the metadata through the engine's
    /// resource lookup.
    static func resourceURLs(_ resource: (String, String) -> URL?) throws -> (texture: URL, metadata: URL) {
        guard let texture = resource(baseName, "png") else {
            throw PinSDFResourceError.missingTextureResource("\(baseName).png")
        }
        guard let metadata = resource(baseName, "json") else {
            throw PinSDFResourceError.missingMetadataResource("\(baseName).json")
        }
        return (texture, metadata)
    }

    /// The bubble decoded by the engine's PNG decoder into an `rgba8Unorm`
    /// texture, as Metal's texture loader reads it on Apple's platforms:
    /// the platforms without one, and the tests on every platform.
    static func load(device: any GPUDevice,
                     resource: (String, String) -> URL?) throws -> PinSDFResource {
        let urls = try resourceURLs(resource)
        let image: RGBAImage
        do {
            image = try PNGDecoder.decode(try Data(contentsOf: urls.texture))
        } catch {
            throw PinSDFResourceError.failedToLoadTexture(urls.texture, error)
        }
        var descriptor = GPUTextureDescriptor(format: .rgba8Unorm, width: image.width, height: image.height)
        descriptor.storage = .shared
        descriptor.label = "Pin bubble distance field"
        guard let texture = device.makeTexture(descriptor) else {
            fatalError("The device made no texture for the pins' bubble")
        }
        image.pixels.withUnsafeBytes { bytes in
            texture.replace(x: 0, y: 0, width: image.width, height: image.height, mipmapLevel: 0, slice: 0,
                            bytes: bytes.baseAddress!, bytesPerRow: image.width * 4)
        }
        return try PinSDFResource(texture: texture, metadataURL: urls.metadata)
    }
}
