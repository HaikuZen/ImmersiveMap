// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import simd

/// The two polar caps of the globe.
enum GlobeCapPole: CaseIterable {
    case north
    case south
}

/// One cap's constant colour; the layout mirrors `CapParams` in Globe.metal.
struct GlobeCapParams {
    var color: SIMD4<Float>
}

struct GlobeCapPalette {
    var north: GlobeCapParams
    var south: GlobeCapParams
}

final class GlobeCapRenderer {
    private let pipeline: GlobeCapPipeline
    private let northCapBuffers: MapSurfaceGridBuffers
    private let southCapBuffers: MapSurfaceGridBuffers
    private let palette: GlobeCapPalette

    /// The style-independent half of the renderer: the pipeline and the polar
    /// cap grids are pure functions of the device, so one set serves every map
    /// view in the process. Only the palette bakes style colors and stays per
    /// instance.
    struct SharedResources {
        let pipeline: GlobeCapPipeline
        let northCapBuffers: MapSurfaceGridBuffers
        let southCapBuffers: MapSurfaceGridBuffers

        static func make(device: any GPUDevice,
                         pixelFormat: GPUPixelFormat,
                         sampleCount: Int,
                         maxLatitude: Double,
                         stacks: Int = 12,
                         slices: Int = 48) -> SharedResources {
            let maxLatitude = Float(maxLatitude)
            let northCap = CapGeometry.createCapGrid(stacks: stacks,
                                                     slices: slices,
                                                     isNorth: true,
                                                     maxLatitude: maxLatitude)
            let southCap = CapGeometry.createCapGrid(stacks: stacks,
                                                     slices: slices,
                                                     isNorth: false,
                                                     maxLatitude: maxLatitude)
            return SharedResources(
                pipeline: GlobeCapPipeline(device: device,
                                           pixelFormat: pixelFormat,
                                           sampleCount: sampleCount),
                northCapBuffers: MapSurfaceGridBuffers.make(device: device,
                                                            vertices: northCap.vertices,
                                                            indices: northCap.indices),
                southCapBuffers: MapSurfaceGridBuffers.make(device: device,
                                                            vertices: southCap.vertices,
                                                            indices: southCap.indices)
            )
        }
    }

    init(sharedResources: SharedResources,
         maxLatitude: Double,
         baseColors: ImmersiveMapBaseColors) {
        pipeline = sharedResources.pipeline
        northCapBuffers = sharedResources.northCapBuffers
        southCapBuffers = sharedResources.southCapBuffers
        palette = Self.makePalette(baseColors: baseColors)
    }

    func draw(renderEncoder: any GPURenderEncoder,
              globeFrame: GlobeFrameConstantsUniform,
              globe: GlobeUniform,
              globeLight: GlobeLightUniform = .disabled) {
        pipeline.selectPipeline(renderEncoder: renderEncoder)
        // The sun on the globe: the caps are planet and shade with the tiles.
        GlobeLightUniform.bind(globeLight, encoder: renderEncoder)
        // Both caps carry the same winding seen from outside the sphere (the
        // generator flips the south fan), so back-face culling removes the
        // far half of each polar fan the way it removes the tiles' far side:
        // nothing writes surface depth on the sphere, and without the cull
        // the back of the fan would draw through the planet.
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setCullMode(.back)
        renderEncoder.setVertexValue(globe, index: 2)
        renderEncoder.setVertexValue(globeFrame, index: 10)

        for pole in GlobeCapPole.allCases {
            switch pole {
            case .north: drawNorthCap(renderEncoder: renderEncoder)
            case .south: drawSouthCap(renderEncoder: renderEncoder)
            }
        }
        // The world pass shares one encoder; restore the defaults the later
        // layers rely on, the way the tile drawer does.
        renderEncoder.setCullMode(.none)
        renderEncoder.setFrontFacing(.clockwise)
    }

    /// Constant cap colours from the style (`ImmersiveMapBaseColors`), each
    /// made opaque: the caps are the planet past the last tile row, with
    /// nothing under them to blend over.
    static func makePalette(baseColors: ImmersiveMapBaseColors) -> GlobeCapPalette {
        GlobeCapPalette(north: GlobeCapParams(color: opaque(baseColors.northCap)),
                        south: GlobeCapParams(color: opaque(baseColors.southCap)))
    }

    private static func opaque(_ color: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(color.x, color.y, color.z, 1)
    }

    private func drawNorthCap(renderEncoder: any GPURenderEncoder) {
        renderEncoder.setFragmentValue(palette.north, index: 0)
        renderEncoder.setVertexBuffer(northCapBuffers.verticesBuffer, offset: 0, index: 0)
        renderEncoder.drawIndexed(.triangle,
                                  indexCount: northCapBuffers.indicesCount,
                                  indexType: northCapBuffers.indexType,
                                  indexBuffer: northCapBuffers.indicesBuffer,
                                  indexBufferOffset: 0,
                                  instanceCount: 1,
                                  baseVertex: 0,
                                  baseInstance: 0)
    }

    private func drawSouthCap(renderEncoder: any GPURenderEncoder) {
        renderEncoder.setFragmentValue(palette.south, index: 0)
        renderEncoder.setVertexBuffer(southCapBuffers.verticesBuffer, offset: 0, index: 0)
        renderEncoder.drawIndexed(.triangle,
                                  indexCount: southCapBuffers.indicesCount,
                                  indexType: southCapBuffers.indexType,
                                  indexBuffer: southCapBuffers.indicesBuffer,
                                  indexBufferOffset: 0,
                                  instanceCount: 1,
                                  baseVertex: 0,
                                  baseInstance: 0)
    }
}
