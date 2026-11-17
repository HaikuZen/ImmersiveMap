// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import PortableFoundation
import simd

enum ModelTileMeshError: Error, Equatable {
    case allocationFailed
}

/// A model tile on the GPU: one vertex buffer, one index buffer and one
/// texture array for every model of the tile. The vertices are in the
/// tile's space, so the frame binds each once, sets the tile's matrix, and
/// draws the tile in one call.
///
/// Immutable after creation, so it is shared between the load that makes it
/// and the frames that draw it (`@unchecked Sendable`: the GPU objects are
/// safe to use from any thread, as Metal's are, and nothing here changes).
final class ModelTileMesh: @unchecked Sendable {
    let tile: Tile
    /// Every index of the tile: what one draw of the tile takes.
    let indexCount: Int
    /// The tile feature ids of the map buildings the tile's models stand
    /// in for, the ones the map's schema can name, by the zoom of the map
    /// tiles each list is for.
    let replacedBuildingIDs: [Int: Set<UInt64>]
    /// The bounds of the whole tile, in tile space.
    let boundsMinimum: SIMD3<Float>
    let boundsMaximum: SIMD3<Float>
    let vertexBuffer: any GPUBuffer
    let indexBuffer: any GPUBuffer
    /// The array of the tile's textures, one layer per source atlas.
    let texture: any GPUTexture
    /// What the tile holds on the GPU, the cost the store budgets by.
    let costInBytes: Int

    /// Whether the device samples the textures a model tile carries. ASTC
    /// is on every Apple GPU, and absent from the Intel Macs' and from
    /// some simulators', and in WebGPU from most desktop GPUs'
    /// (`texture-compression-astc`).
    static func isSupported(device: any GPUDevice) -> Bool {
        device.features.contains(.astc)
    }

    /// A backend's way to load the vertex, index and texture blocks from
    /// the tile's file straight into the buffers and the texture, if it has
    /// one (Metal's IO queue, `metalFileLoader(device:)`). True when every
    /// block arrived.
    typealias FileLoader = @Sendable (_ contents: ModelTileContents,
                                      _ fileURL: URL,
                                      _ vertexBuffer: any GPUBuffer,
                                      _ indexBuffer: any GPUBuffer,
                                      _ texture: any GPUTexture) async -> Bool

    /// Puts a decoded tile on the GPU and checks its geometry there.
    /// `data` is the bytes `contents` was decoded from. `schema` names the
    /// tile features of the replaced buildings.
    ///
    /// A tile from the disk cache comes with its file (`fileURL`): the
    /// vertex, index and texture blocks lie in it uncompressed and aligned,
    /// in the form the GPU takes, and the backend's file loader, where
    /// there is one, loads them from the file straight into the buffers and
    /// the texture, so the bulk of a tile never passes through the
    /// process's memory. `data` is then a mapping read only as far as the
    /// tables. A tile fresh from the archive is in memory already and is
    /// copied from there, as is a tile on a device without a file loader
    /// (the simulator, a Mac without Metal 3, a browser), and one whose
    /// load from the file did not complete.
    static func make(contents: ModelTileContents,
                     data: Data,
                     fileURL: URL?,
                     device: any GPUDevice,
                     fileLoader: FileLoader? = nil,
                     schema: any ImmersiveMapTileSchema) async throws -> ModelTileMesh {
        guard let pixelFormat = Self.pixelFormat(blockEdge: contents.texture.blockEdge) else {
            throw ModelTileFormatError.malformed("the engine has no pixel format for ASTC \(contents.texture.blockEdge)x\(contents.texture.blockEdge)")
        }
        var descriptor = GPUTextureDescriptor(format: pixelFormat,
                                              width: contents.texture.width,
                                              height: contents.texture.height)
        descriptor.type = .type2DArray
        descriptor.arrayLength = contents.texture.layerCount
        descriptor.mipmapLevelCount = contents.texture.mipLevelCount
        descriptor.usage = .shaderRead
        // Shared memory is the GPU's own on the devices that have ASTC, so
        // the blocks are written once and no second copy is kept.
        descriptor.storage = .shared
        guard contents.vertexRange.isEmpty == false,
              contents.indexRange.isEmpty == false,
              let vertexBuffer = device.makeBuffer(length: contents.vertexRange.count, storage: .shared),
              let indexBuffer = device.makeBuffer(length: contents.indexRange.count, storage: .shared),
              let texture = device.makeTexture(descriptor) else {
            throw ModelTileMeshError.allocationFailed
        }
        let name = "ModelTile \(contents.tile.z)/\(contents.tile.x)/\(contents.tile.y)"
        vertexBuffer.label = "\(name) vertices"
        indexBuffer.label = "\(name) indices"

        var isLoaded = false
        if let fileURL, let fileLoader {
            isLoaded = await fileLoader(contents, fileURL, vertexBuffer, indexBuffer, texture)
        }
        if isLoaded == false {
            copy(contents: contents, from: data, vertexBuffer: vertexBuffer, indexBuffer: indexBuffer, texture: texture)
        }
        // Whichever way the blocks came, they are checked where the GPU
        // reads them.
        try contents.checkGeometry(vertices: UnsafeRawBufferPointer(start: vertexBuffer.contents(),
                                                                    count: contents.vertexRange.count),
                                   indices: UnsafeRawBufferPointer(start: indexBuffer.contents(),
                                                                   count: contents.indexRange.count))
        return ModelTileMesh(contents: contents,
                             vertexBuffer: vertexBuffer,
                             indexBuffer: indexBuffer,
                             texture: texture,
                             schema: schema)
    }

    private convenience init(contents: ModelTileContents,
                             vertexBuffer: any GPUBuffer,
                             indexBuffer: any GPUBuffer,
                             texture: any GPUTexture,
                             schema: any ImmersiveMapTileSchema) {
        var replaced: [Int: Set<UInt64>] = [:]
        for model in contents.models {
            for entry in model.replacedBuildings {
                if let featureID = schema.tileFeatureID(of: entry.element) {
                    replaced[entry.mapTileZoom, default: []].insert(featureID)
                }
            }
        }
        self.init(tile: contents.tile,
                  indexCount: contents.indexCount,
                  replacedBuildingIDs: replaced,
                  boundsMinimum: contents.boundsMinimum,
                  boundsMaximum: contents.boundsMaximum,
                  vertexBuffer: vertexBuffer,
                  indexBuffer: indexBuffer,
                  texture: texture,
                  costInBytes: contents.vertexRange.count + contents.indexRange.count + contents.textureRange.count)
    }

    /// A tile from its parts, as the GPU takes them: the vertices in the
    /// baker's layout (`ModelTileContents`), `UInt32` indices, and a 2D
    /// array texture. The probe scene builds its tile this way, with a
    /// texture of a format every backend samples.
    init(tile: Tile,
         indexCount: Int,
         replacedBuildingIDs: [Int: Set<UInt64>],
         boundsMinimum: SIMD3<Float>,
         boundsMaximum: SIMD3<Float>,
         vertexBuffer: any GPUBuffer,
         indexBuffer: any GPUBuffer,
         texture: any GPUTexture,
         costInBytes: Int) {
        self.tile = tile
        self.indexCount = indexCount
        self.replacedBuildingIDs = replacedBuildingIDs
        self.boundsMinimum = boundsMinimum
        self.boundsMaximum = boundsMaximum
        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        self.texture = texture
        self.costInBytes = costInBytes
    }

    /// Each texture layer of each mip level with its place in the tile's
    /// bytes, in the order the texture block keeps them.
    static func forEachTextureImage(of contents: ModelTileContents,
                                    _ body: (_ level: Int, _ layer: Int, _ width: Int, _ height: Int,
                                             _ byteOffset: Int, _ bytesPerRow: Int, _ byteCount: Int) -> Void) {
        var offset = contents.textureRange.lowerBound
        for level in 0..<contents.texture.mipLevelCount {
            let layerByteCount = contents.texture.layerByteCount(level: level)
            let width = max(1, contents.texture.width >> level)
            let height = max(1, contents.texture.height >> level)
            for layer in 0..<contents.texture.layerCount {
                body(level, layer, width, height, offset, contents.texture.bytesPerRow(level: level), layerByteCount)
                offset += layerByteCount
            }
        }
    }

    /// The blocks copied from the tile's bytes in memory.
    private static func copy(contents: ModelTileContents,
                             from data: Data,
                             vertexBuffer: any GPUBuffer,
                             indexBuffer: any GPUBuffer,
                             texture: any GPUTexture) {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            vertexBuffer.contents().copyMemory(from: base + contents.vertexRange.lowerBound,
                                               byteCount: contents.vertexRange.count)
            indexBuffer.contents().copyMemory(from: base + contents.indexRange.lowerBound,
                                              byteCount: contents.indexRange.count)
            forEachTextureImage(of: contents) { level, layer, width, height, byteOffset, bytesPerRow, _ in
                texture.replace(x: 0, y: 0, width: width, height: height,
                                mipmapLevel: level,
                                slice: layer,
                                bytes: base + byteOffset,
                                bytesPerRow: bytesPerRow)
            }
        }
    }

    private static func pixelFormat(blockEdge: Int) -> GPUPixelFormat? {
        switch blockEdge {
        case 4, 5, 6, 8, 10, 12: return .astc(blockWidth: blockEdge, blockHeight: blockEdge)
        default: return nil
        }
    }
}
