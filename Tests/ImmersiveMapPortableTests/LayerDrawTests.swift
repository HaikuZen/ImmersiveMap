// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapGPUTestSupport
import simd
import XCTest
@testable import ImmersiveMap

/// What the layers ask of the GPU, recorded: the pipelines of each surface,
/// the depth tests, the buffers of a layer, and the draws of a frame. No
/// picture: the layers are judged in the app.
final class LayerDrawTests: XCTestCase {
    private let zone = ImmersiveMapPolygon(exterior: [GeoCoordinate(latitude: 0, longitude: 0),
                                                      GeoCoordinate(latitude: 0, longitude: 10),
                                                      GeoCoordinate(latitude: 10, longitude: 10),
                                                      GeoCoordinate(latitude: 10, longitude: 0)])
    private let path = ImmersiveMapPolyline(coordinates: [GeoCoordinate(latitude: 1, longitude: 1),
                                                          GeoCoordinate(latitude: 5, longitude: 3),
                                                          GeoCoordinate(latitude: 8, longitude: 2)])
    private let spot = ImmersiveMapPoint(coordinate: GeoCoordinate(latitude: 4, longitude: 4))

    private func makeMesh(device: RecordingGPUDevice,
                          polygons: [ImmersiveMapPolygon]? = nil,
                          polylines: [ImmersiveMapPolyline]? = nil,
                          points: [ImmersiveMapPoint]? = nil) throws -> LayerMesh {
        let layer = ImmersiveMapLayer(id: "layer",
                                      polygons: polygons ?? [zone],
                                      polylines: polylines ?? [path],
                                      points: points ?? [spot])
        return try XCTUnwrap(LayerMesh(key: layer.meshKey, data: LayerMeshBuilder.build(layer: layer), device: device))
    }

    private func draw(_ value: Float) -> LayerDrawUniform {
        LayerDrawUniform(modelMatrix: matrix_identity_float4x4,
                         uvOrigin: .zero,
                         uvScale: 0,
                         referenceWorldX: value,
                         viewportSizePx: SIMD2<Float>(800, 600),
                         pixelsPerPoint: 2,
                         depth: LayerDepth.depth)
    }

    func testEachSurfaceHasItsZoneLineAndPointPipelines() throws {
        let device = RecordingGPUDevice(shaderFunctions: ["layerFillVertex", "layerFillFragment",
                                                          "layerLineVertex", "layerLineFragment",
                                                          "layerPointVertex", "layerPointFragment"])
        _ = LayerPipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4)
        XCTAssertEqual(device.pipelines.count, 9)
        for surface in LayerPipeline.Surface.allCases {
            let ofSurface = device.pipelines.filter {
                $0.vertexFunction.constants == [0: .int32(Int32(surface.rawValue))]
            }
            XCTAssertEqual(Set(ofSurface.map(\.vertexFunction.name)),
                           ["layerFillVertex", "layerLineVertex", "layerPointVertex"])
            for pipeline in ofSurface {
                XCTAssertEqual(pipeline.fragmentFunction?.constants, pipeline.vertexFunction.constants,
                               "The two functions of a pipeline are specialized for the same surface")
            }
        }
        let pipeline = try XCTUnwrap(device.pipelines.first)
        XCTAssertNil(pipeline.vertexLayout, "The shaders read their vertices by index")
        XCTAssertEqual(pipeline.sampleCount, 4)
        XCTAssertEqual(pipeline.depthStencilFormat, .depth32FloatStencil8)
        XCTAssertEqual(pipeline.colorTargets.first?.blend?.color,
                       GPUBlendComponent(source: .sourceAlpha, destination: .oneMinusSourceAlpha))
        XCTAssertEqual(pipeline.colorTargets.first?.blend?.alpha,
                       GPUBlendComponent(source: .one, destination: .oneMinusSourceAlpha))
    }

    func testTheDepthTestsDifferOnlyInTheGroundsDepthAndKeepTheStencil() throws {
        let pipeline = LayerPipeline(device: RecordingGPUDevice(), pixelFormat: .bgra8Unorm, sampleCount: 1)
        let overGround = try XCTUnwrap(pipeline.overGroundState as? RecordingDepthStencilState).descriptor
        let behindTerrain = try XCTUnwrap(pipeline.behindTerrainState as? RecordingDepthStencilState).descriptor
        XCTAssertEqual(overGround.depthCompare, .always)
        XCTAssertEqual(behindTerrain.depthCompare, .less)
        for descriptor in [overGround, behindTerrain] {
            XCTAssertFalse(descriptor.depthWriteEnabled)
            let stencil = try XCTUnwrap(descriptor.frontStencil)
            XCTAssertEqual(descriptor.backStencil, stencil)
            XCTAssertEqual(stencil.compare, .equal)
            XCTAssertEqual(stencil.readMask, TileSourceStencilPriority.surfaceMaskBit)
            XCTAssertEqual(stencil.writeMask, 0)
            XCTAssertEqual([stencil.stencilFailure, stencil.depthFailure, stencil.pass], [.keep, .keep, .keep])
        }
    }

    func testAMeshMakesABufferForEachPartItHas() throws {
        let device = RecordingGPUDevice()
        let full = try makeMesh(device: device)
        XCTAssertEqual(full.fillVertices?.label, "Layer fill vertices")
        XCTAssertEqual(full.fillIndices?.label, "Layer fill indices")
        XCTAssertEqual(full.lineVertices?.label, "Layer line vertices")
        XCTAssertEqual(full.lineIndices?.label, "Layer line indices")
        XCTAssertEqual(full.discs?.label, "Layer discs")
        XCTAssertTrue(device.buffers.allSatisfy { $0.storage == .shared })

        let pointsOnly = try makeMesh(device: device, polygons: [], polylines: [])
        XCTAssertNil(pointsOnly.fillVertices)
        XCTAssertNil(pointsOnly.lineIndices)
        XCTAssertNotNil(pointsOnly.discs)
    }

    func testAFrameDrawsZonesThenLinesThenJoinsAndPointsForEveryPlacement() throws {
        let device = RecordingGPUDevice()
        let pipeline = LayerPipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 1)
        let mesh = try makeMesh(device: device)
        let disabled = try XCTUnwrap(device.makeDepthStencilState(GPUDepthStencilDescriptor()))
        let encoder = RecordingRenderEncoder()
        LayerDrawing.drawLayers([(mesh, false)],
                                        pipeline: pipeline,
                                        surface: .flat,
                                        placements: { _ in [self.draw(1), self.draw(2)] },
                                        depthDisabledState: disabled,
                                        encoder: encoder)

        let commands = encoder.commands
        let states = pipeline.states(for: .flat)
        let pipelinesSet = commands.compactMap { command -> GPURenderPipelineDescriptor? in
            if case let .setPipeline(descriptor) = command { return descriptor }
            return nil
        }
        XCTAssertEqual(pipelinesSet, [states.fill, states.line, states.point].map {
            ($0 as! RecordingRenderPipeline).descriptor
        })
        XCTAssertTrue(commands.contains(.setDepthStencilState((pipeline.overGroundState as! RecordingDepthStencilState).descriptor)))

        let chunks = mesh.chunks
        let indexedDraws = commands.filter { if case .drawIndexed = $0 { return true } else { return false } }
        let fillChunks = chunks.filter { $0.fillIndexCount > 0 }.count
        let lineChunks = chunks.filter { $0.lineIndexCount > 0 }.count
        XCTAssertGreaterThan(fillChunks, 0)
        XCTAssertGreaterThan(lineChunks, 0)
        XCTAssertEqual(indexedDraws.count, 2 * (fillChunks + lineChunks), "Every chunk draws once per placement")
        let instancedDraws = commands.filter { if case .draw = $0 { return true } else { return false } }
        let discRuns = chunks.filter { $0.joinCount > 0 }.count + chunks.filter { $0.pointCount > 0 }.count
        XCTAssertEqual(instancedDraws.count, 2 * discRuns)
        let firstChunk = try XCTUnwrap(chunks.first { $0.pointCount > 0 })
        XCTAssertTrue(commands.contains(.draw(.triangle, vertexStart: 0, vertexCount: 6,
                                              instanceCount: firstChunk.pointCount, baseInstance: firstChunk.pointStart)))
        XCTAssertEqual(encoder.vertexValue(at: 2, as: LayerDrawUniform.self)?.referenceWorldX, 2,
                       "The last draw carries the last placement")

        XCTAssertEqual(Array(commands.suffix(3)),
                       [.setCullMode(.none), .setFrontFacing(.clockwise), .setDepthStencilState(GPUDepthStencilDescriptor())],
                       "The encoder is left in its neutral state")
    }

    func testALayerTheTerrainHidesIsTestedAgainstTheGround() throws {
        let device = RecordingGPUDevice()
        let pipeline = LayerPipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 1)
        let encoder = RecordingRenderEncoder()
        LayerDrawing.drawLayers([(try makeMesh(device: device), true)],
                                        pipeline: pipeline,
                                        surface: .sphere,
                                        placements: { _ in [self.draw(0)] },
                                        depthDisabledState: try XCTUnwrap(device.makeDepthStencilState(GPUDepthStencilDescriptor())),
                                        encoder: encoder)
        let behind = (pipeline.behindTerrainState as! RecordingDepthStencilState).descriptor
        XCTAssertTrue(encoder.commands.contains(.setDepthStencilState(behind)))
        XCTAssertTrue(encoder.commands.contains(.setPipeline((pipeline.states(for: .sphere).fill as! RecordingRenderPipeline).descriptor)))
    }

    func testAChunkOutOfViewDrawsNothing() throws {
        let device = RecordingGPUDevice()
        let pipeline = LayerPipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 1)
        let encoder = RecordingRenderEncoder()
        LayerDrawing.drawLayers([(try makeMesh(device: device), false)],
                                        pipeline: pipeline,
                                        surface: .flat,
                                        placements: { _ in [] },
                                        depthDisabledState: try XCTUnwrap(device.makeDepthStencilState(GPUDepthStencilDescriptor())),
                                        encoder: encoder)
        XCTAssertFalse(encoder.commands.contains { command in
            switch command {
            case .draw, .drawIndexed, .setPipeline: true
            default: false
            }
        })
    }
}
