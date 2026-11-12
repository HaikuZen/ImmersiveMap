// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapGPUTestSupport
import simd
import XCTest
@testable import ImmersiveMap

/// Placed tiles for the drawing tests, made from interface types alone: an
/// empty tile, or one with `trees` trees in one buffer.
enum TestTiles {
    static func emptyLayer() -> TileBuffers.GeometryLayer {
        TileBuffers.GeometryLayer(vertices: nil, indices: nil, styles: nil, styleZoomFade: nil, lineStyles: nil, indexType: .uint16)
    }

    static func buffers(backing: (any GPUBuffer)?, extruded: TileBuffers.Extruded? = nil) -> TileBuffers {
        let ground = emptyLayer()
        let phases = RoadGeometryPhases(shadow: ground, casing: ground, fill: ground, detail: ground, overlay: ground)
        return TileBuffers(gpuBackingBuffer: backing,
                           ground: ground,
                           roads: RoadStructureBuckets(tunnel: phases, ground: phases, automobileGround: phases, bridge: phases),
                           bridgeOverlay: ground,
                           extruded: extruded ?? TileBuffers.Extruded(vertices: nil, indices: nil, styles: nil, gpuIndexType: .uint16),
                           textLabels: TileBuffers.TextLabelSet(placementInputs: [], labelsByStyleRuns: [], poiIconRuns: []),
                           roadLabels: TileBuffers.RoadLabels(pathInputs: [], pathRanges: [], pathLabels: [], labelStyle: nil,
                                                              localGlyphVertices: nil, glyphBounds: [], glyphBoundRanges: [],
                                                              sizes: [], anchorRanges: [], anchors: []))
    }

    /// `source` placed in `placeIn` (itself by default), with `trees` trees.
    static func placement(device: RecordingGPUDevice,
                          source: Tile,
                          placeIn: Tile? = nil,
                          trees: Int = 0) throws -> PlaceTile {
        var tileBuffers: TileBuffers
        if trees > 0 {
            let instances = (0 ..< trees).map { TreeInstance(position: SIMD2(Float($0) * 100, 50), height: 40, rotation: 0, tint: 0.5) }
            let buffer = try XCTUnwrap(device.makeBuffer(instances, storage: .shared))
            tileBuffers = buffers(backing: buffer)
            tileBuffers.trees = TileBufferView(gpuBuffer: buffer, offset: 0, count: trees)
        } else {
            tileBuffers = buffers(backing: nil)
        }
        return PlaceTile(metalTile: MetalTile(tile: source, tileBuffers: tileBuffers),
                         placeIn: VisibleTile(tile: placeIn ?? source))
    }
}
