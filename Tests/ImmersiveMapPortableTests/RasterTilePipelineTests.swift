// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapGPUTestSupport
import XCTest
@testable import ImmersiveMap

/// The raster tiles' pipelines, recorded: the bake into the tile's texture,
/// the draws on each surface and the relief's caster. No picture: the
/// raster tiles are judged in the app.
final class RasterTilePipelineTests: XCTestCase {
    private func pipelines() -> [String: GPURenderPipelineDescriptor] {
        let device = RecordingGPUDevice()
        _ = RasterTilePipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4)
        return Dictionary(uniqueKeysWithValues: device.pipelines.map { ($0.label ?? "", $0) })
    }

    func testTheBakeBlendsTheFillsIntoTheTilesTextureFromTheTileVertices() throws {
        let bake = try XCTUnwrap(pipelines()["RasterTileBake"])
        XCTAssertEqual(bake.sampleCount, RasterTilePipeline.bakeSampleCount)
        XCTAssertNil(bake.depthStencilFormat)
        XCTAssertEqual(bake.colorTargets.first?.format, RasterTileTexture.format)
        XCTAssertEqual(bake.colorTargets.first?.blend?.color, GPUBlendComponent(source: .sourceAlpha, destination: .oneMinusSourceAlpha))
        XCTAssertEqual(bake.colorTargets.first?.blend?.alpha, GPUBlendComponent(source: .one, destination: .oneMinusSourceAlpha))
        let layout = try XCTUnwrap(bake.vertexLayout)
        XCTAssertEqual(layout, TileVertexIn.gpuVertexLayout)
        XCTAssertEqual(layout.strides[0], MemoryLayout<TileVertexIn>.stride)
        XCTAssertEqual(layout.attributes[0], GPUVertexAttribute(format: .float2, offset: 0, bufferIndex: 0))
        XCTAssertEqual(layout.attributes[2]?.format, .char, "The line's signed distance")
        XCTAssertEqual(layout.attributes[4], GPUVertexAttribute(format: .char2Normalized,
                                                                offset: MemoryLayout<TileVertexIn>.offset(of: \.normal)!,
                                                                bufferIndex: 0))
    }

    func testTheDrawsAreOpaqueAndOnlyThePlanesReliefRises() throws {
        let all = pipelines()
        for label in ["RasterTileFlat", "RasterTileFlatRelief", "RasterTileSpherePure", "RasterTileSphereMorph"] {
            let draw = try XCTUnwrap(all[label], label)
            XCTAssertEqual(draw.sampleCount, 4)
            XCTAssertEqual(draw.depthStencilFormat, .depth32FloatStencil8)
            XCTAssertEqual(draw.colorTargets.first?.format, .bgra8Unorm)
            XCTAssertNil(draw.colorTargets.first?.blend)
            let rises = label == "RasterTileFlatRelief"
            XCTAssertEqual(draw.vertexFunction.constants, [0: .bool(rises)], label)
            XCTAssertEqual(draw.fragmentFunction?.constants, [0: .bool(rises)], "The relief's fragment samples the shadows at its raised point")
        }
    }

    func testTheReliefCasterWritesTheShadowDepthAlone() throws {
        let caster = try XCTUnwrap(pipelines()["RasterTileReliefShadow"])
        XCTAssertNil(caster.fragmentFunction)
        XCTAssertTrue(caster.colorTargets.isEmpty)
        XCTAssertEqual(caster.depthStencilFormat, ShadowCascadeAtlas.depthFormat)
        XCTAssertEqual(caster.sampleCount, 1)
    }
}
