// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import simd

/// The draws of the labels painted on the map, apart from the subsystem
/// that picks which copy of a label draws and reads the frame
/// (`SurfaceLabelRenderSubsystem`), so they build and are tested
/// everywhere.
enum SurfaceLabelDrawing {
    /// A label to draw: its tile, the copy of the world it draws in, its
    /// record and the tile's surface label vertices.
    struct Item {
        let tile: Tile
        let worldWrap: Int8
        let record: SurfaceLabelRecord
        let vertices: TileBufferView
    }

    enum Surface {
        case flat(FlatRenderState)
        /// The sphere or the surface unrolling from it (`pureSphere` false),
        /// with how far the globe's look has been handed over to the
        /// plane's (`FrameContext.groundHandover`).
        case sphere(globe: GlobeUniform, pureSphere: Bool, handover: Float)
    }

    /// What a frame draws the labels by.
    struct Frame {
        let cameraUniform: CameraUniform
        /// The ground fog over the labels painted on the plane, as over the
        /// ground they lie on. Nothing on the globe.
        let groundFog: GroundFogUniform
        /// Screen points one tile spans at the camera zoom equal to its own
        /// (`SurfaceLabelScale.tileScreenPoints`).
        let tileScreenPoints: Double
        let viewportSizePx: SIMD2<Float>
        let pixelsPerPoint: Float
        /// The frame's factor over the labels' own opacity
        /// (`FrameContextServices.labelOpacity`).
        let labelOpacity: LabelOpacityFrame
        let surface: Surface
    }

    /// Draws every halo and then every fill: where two names cross, the
    /// halo of one never covers the letters of the other. Leaves the
    /// encoder in its neutral state.
    static func draw(_ items: [Item],
                     frame: Frame,
                     pipeline: SurfaceLabelPipeline,
                     textRenderer: TextRenderer,
                     depthState: any GPUDepthStencilState,
                     depthDisabledState: any GPUDepthStencilState,
                     encoder: any GPURenderEncoder) {
        guard items.isEmpty == false else { return }
        encoder.pushDebugGroup("surfaceLabels")
        // Every glyph is counter-clockwise in render space, like the ground's
        // triangles, and neither surface's projection mirrors: culling the
        // back faces removes the far side of the planet, as for the ground.
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.back)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexValue(frame.cameraUniform, index: 1)
        GroundFogUniform.bind(frame.groundFog, encoder: encoder)

        switch frame.surface {
        case .flat:
            encoder.setPipeline(pipeline.flatPipelineState)
        case let .sphere(globe, pureSphere, _):
            encoder.setPipeline(pureSphere ? pipeline.spherePipelineState : pipeline.morphPipelineState)
            encoder.setVertexValue(globe, index: 8)
            encoder.setVertexValue(GlobeFrameConstantsUniform.make(globe: globe, cameraMatrix: frame.cameraUniform.matrix),
                                   index: 10)
        }

        for haloPass in [true, false] {
            for item in items {
                draw(item, haloPass: haloPass, frame: frame, textRenderer: textRenderer, encoder: encoder)
            }
        }

        encoder.setCullMode(.none)
        encoder.setFrontFacing(.clockwise)
        encoder.setDepthStencilState(depthDisabledState)
        encoder.popDebugGroup()
    }

    private static func draw(_ item: Item,
                             haloPass: Bool,
                             frame: Frame,
                             textRenderer: TextRenderer,
                             encoder: any GPURenderEncoder) {
        let record = item.record
        guard record.vertexCount > 0 else { return }
        let style = record.style
        let atlasEmTexels = Float(textRenderer.atlasEmTexels(for: style.weight))
        let haloAtlasTexels = style.haloEm * atlasEmTexels
        if haloPass, haloAtlasTexels <= 0 {
            return
        }

        let tile = item.tile
        // The globe's look of the name handed over to the plane's with the
        // air (LabelTextStyle.sphereFillColor), 1 on the plane.
        let handover: Float
        switch frame.surface {
        case .flat(let flatRenderState):
            let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x,
                                                                             y: tile.y,
                                                                             z: tile.z,
                                                                             worldWrap: item.worldWrap,
                                                                             flatRenderPan: flatRenderState.pan,
                                                                             renderMapSize: flatRenderState.renderMapSize)
            let scale = originAndSize.z / 4096.0
            let modelMatrix = Matrix.translationMatrix(x: originAndSize.x, y: originAndSize.y, z: 0)
                * Matrix.scaleMatrix(sx: scale, sy: scale, sz: 1)
            encoder.setVertexValue(modelMatrix, index: 3)
            handover = 1
        case let .sphere(_, _, globeHandover):
            encoder.setVertexValue(GlobeSurfaceTileUniform(tile: tile), index: 9)
            handover = globeHandover
        }

        // The label's own opacity under the frame's factor for its kind
        // (`FrameContextServices.labelOpacity`).
        let opacity = frame.labelOpacity.opacity(of: style)
        let drawUniform = SurfaceLabelDrawUniform(fillColor: SIMD4<Float>(style.fillColor(atHandover: handover), opacity),
                                                  strokeColor: SIMD4<Float>(style.strokeColor(atHandover: handover), opacity),
                                                  haloAtlasTexels: haloAtlasTexels,
                                                  depth: SurfaceLabelDepth.depth,
                                                  haloPass: haloPass ? 1 : 0,
                                                  tileUnitsPerPoint: SurfaceLabelScale.tileUnitsPerPoint(
                                                      tileZoom: tile.z,
                                                      referenceZoom: record.placement.referenceZoom,
                                                      tileScreenPoints: frame.tileScreenPoints),
                                                  viewportSizePx: frame.viewportSizePx,
                                                  pixelsPerPoint: frame.pixelsPerPoint,
                                                  haloSoftness: style.haloSoftness)
        encoder.setVertexValue(drawUniform, index: 4)
        encoder.setFragmentValue(drawUniform, index: 0)
        encoder.setFragmentTexture(style.weight == .thin ? textRenderer.thinTexture : textRenderer.texture, index: 0)
        encoder.setVertexBuffer(item.vertices.gpuBuffer, offset: item.vertices.offset, index: 0)
        encoder.draw(.triangle, vertexStart: record.vertexStart, vertexCount: record.vertexCount)
    }
}
