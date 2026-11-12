// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import PortableFoundation

/// The pipelines of the labels painted on the map (SurfaceLabel.metal): one
/// per surface the ground is drawn on, all in the world pass's formats and
/// sample count, blended like the ground.
final class SurfaceLabelPipeline {
    let flatPipelineState: any GPURenderPipeline
    let spherePipelineState: any GPURenderPipeline
    let morphPipelineState: any GPURenderPipeline

    init(device: any GPUDevice,
         pixelFormat: GPUPixelFormat,
         sampleCount: Int) {
        // The baked vertices are `LabelVertex`: the anchor, the atlas uv and
        // the offset are all the stages read.
        var layout = GPUVertexLayout()
        layout.attributes[0] = GPUVertexAttribute(format: .float2,
                                                  offset: MemoryLayout<LabelVertex>.offset(of: \.position)!,
                                                  bufferIndex: 0)
        layout.attributes[1] = GPUVertexAttribute(format: .float2,
                                                  offset: MemoryLayout<LabelVertex>.offset(of: \.uv)!,
                                                  bufferIndex: 0)
        // The glyph's offset from the anchor in points (`TileSurfaceLabelsBuilder`).
        layout.attributes[2] = GPUVertexAttribute(format: .float2,
                                                  offset: MemoryLayout<LabelVertex>.offset(of: \.spriteUV)!,
                                                  bufferIndex: 0)
        layout.strides[0] = MemoryLayout<LabelVertex>.stride

        var color = GPUColorTarget(format: pixelFormat)
        color.blend = (color: GPUBlendComponent(source: .sourceAlpha, destination: .oneMinusSourceAlpha),
                       alpha: GPUBlendComponent(source: .one, destination: .oneMinusSourceAlpha))

        func makeState(vertexFunction name: String) -> any GPURenderPipeline {
            var descriptor = GPURenderPipelineDescriptor(vertexFunction: GPUShaderFunction(name: name),
                                                         fragmentFunction: GPUShaderFunction(name: "surfaceLabelFragment"),
                                                         colorTargets: [color])
            descriptor.label = name
            descriptor.vertexLayout = layout
            descriptor.depthStencilFormat = .depth32FloatStencil8
            descriptor.sampleCount = sampleCount
            do {
                return try device.makeRenderPipeline(descriptor)
            } catch {
                fatalError("Failed to create the surface label pipeline: \(error)")
            }
        }
        self.flatPipelineState = makeState(vertexFunction: "surfaceLabelFlatVertex")
        self.spherePipelineState = makeState(vertexFunction: "surfaceLabelSphereVertex")
        self.morphPipelineState = makeState(vertexFunction: "surfaceLabelMorphVertex")
    }
}

/// Mirror of `SurfaceLabelDraw` in SurfaceLabel.metal.
struct SurfaceLabelDrawUniform {
    var fillColor: SIMD4<Float>
    var strokeColor: SIMD4<Float>
    var haloAtlasTexels: Float
    var depth: Float
    var haloPass: Float
    var tileUnitsPerPoint: Float
    var viewportSizePx: SIMD2<Float>
    var pixelsPerPoint: Float
    /// The share of the halo's width over which it fades out
    /// (`LabelTextStyle.haloSoftness`).
    var haloSoftness: Float
}

/// How large a label painted on the map is on screen. The map's own scale
/// follows the viewport: at the camera zoom equal to a tile's own, the
/// render camera (vertical fov pi/4, at distance 1, `RenderCamera`) shows
/// the tile's world size over the viewport's height, so a tile spans the
/// same share of the height in any window. The text keeps to that scale:
/// its point size at the reference zoom, twice that one zoom deeper. The
/// vertex stage never lets it draw smaller than its point size where the
/// ground itself is small on screen (SurfaceLabel.metal).
enum SurfaceLabelScale {
    /// Screen points one tile spans at the camera zoom equal to its own.
    static func tileScreenPoints(viewportHeightPoints: Double, tileWorldSize: Double) -> Double {
        viewportHeightPoints * tileWorldSize / (2 * tan(Double.pi / 8))
    }

    /// Tile units per point of a label drawn from a tile of `tileZoom` that
    /// spans its point size at `referenceZoom`.
    static func tileUnitsPerPoint(tileZoom: Int,
                                  referenceZoom: Double,
                                  tileScreenPoints: Double) -> Float {
        let points = tileScreenPoints * pow(2, referenceZoom - Double(tileZoom))
        guard points > 0, points.isFinite else { return 0 }
        return Float(TileCoordinateSpace.tileExtentDouble / points)
    }
}

/// Where the labels painted on the map sit in the ground's far-plane depth
/// band: nearer than the ground's layers and every road rank (whose bands
/// end about 3 700 steps of 2^-23 under one even for a layer of 256 styles,
/// `RoadRankDepth`), so the text lies over them, and still farther than the
/// buildings and the models, which hide it.
enum SurfaceLabelDepth {
    static let depth: Float = 1 - GlobeSurfaceDepthRank.surfaceLabelsRank * GlobeSurfaceDepthRank.layerDepthStep
}
