// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapGPUTestSupport
import simd
import XCTest
@testable import ImmersiveMap

/// What the labels painted on the map ask of the GPU, recorded: a pipeline
/// per surface, every halo before every fill, each label in its tile's place
/// and atlas, and the encoder handed back neutral. No picture: the labels
/// are judged in the app.
final class SurfaceLabelDrawTests: XCTestCase {
    private func style(weight: LabelFontWeight, haloEm: Float = 0.15) -> LabelTextStyle {
        LabelTextStyle(key: 1,
                       fillColor: SIMD3<Float>(0.2, 0.3, 0.4),
                       strokeColor: SIMD3<Float>(1, 1, 1),
                       haloEm: haloEm,
                       sizePoints: 20,
                       weight: weight)
    }

    private func item(_ device: RecordingGPUDevice, tile: Tile, weight: LabelFontWeight,
                      haloEm: Float = 0.15, vertexStart: Int, vertexCount: Int) throws -> SurfaceLabelDrawing.Item {
        let buffer = try XCTUnwrap(device.makeBuffer(length: 64 * MemoryLayout<LabelVertex>.stride, storage: .shared))
        let record = SurfaceLabelRecord(key: UInt64(tile.x),
                                        style: style(weight: weight, haloEm: haloEm),
                                        placement: SurfaceLabelPlacement(referenceZoom: Double(tile.z)),
                                        vertexStart: vertexStart,
                                        vertexCount: vertexCount)
        return SurfaceLabelDrawing.Item(tile: tile, worldWrap: 0, record: record,
                                        vertices: TileBufferView(gpuBuffer: buffer, offset: 16, count: 64))
    }

    private func frame(surface: SurfaceLabelDrawing.Surface) -> SurfaceLabelDrawing.Frame {
        SurfaceLabelDrawing.Frame(cameraUniform: CameraUniform(matrix: matrix_identity_float4x4, eye: SIMD3<Float>(0, 0, 3), padding: 0),
                                  groundFog: .disabled,
                                  tileScreenPoints: 400,
                                  viewportSizePx: SIMD2<Float>(800, 600),
                                  pixelsPerPoint: 2,
                                  labelOpacity: .solid,
                                  surface: surface)
    }

    private struct Fixture {
        let device = RecordingGPUDevice()
        let pipeline: SurfaceLabelPipeline
        let textRenderer: TextRenderer
        let depth: any GPUDepthStencilState
        let disabled: any GPUDepthStencilState

        init() throws {
            pipeline = SurfaceLabelPipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4)
            textRenderer = TextRenderer(device: device, resource: TestResources.url)
            var descriptor = GPUDepthStencilDescriptor()
            descriptor.depthCompare = .lessEqual
            depth = try XCTUnwrap(device.makeDepthStencilState(descriptor))
            disabled = try XCTUnwrap(device.makeDepthStencilState(GPUDepthStencilDescriptor()))
        }

        func draw(_ items: [SurfaceLabelDrawing.Item], frame: SurfaceLabelDrawing.Frame) -> RecordingRenderEncoder {
            let encoder = RecordingRenderEncoder()
            SurfaceLabelDrawing.draw(items, frame: frame, pipeline: pipeline, textRenderer: textRenderer,
                                     depthState: depth, depthDisabledState: disabled, encoder: encoder)
            return encoder
        }
    }

    func testEachSurfaceHasItsVertexStageAndOneFragment() throws {
        let fixture = try Fixture()
        let surfacePipelines = fixture.device.pipelines.filter { $0.fragmentFunction?.name == "surfaceLabelFragment" }
        XCTAssertEqual(Set(surfacePipelines.map(\.vertexFunction.name)),
                       ["surfaceLabelFlatVertex", "surfaceLabelSphereVertex", "surfaceLabelMorphVertex"])
        for pipeline in surfacePipelines {
            XCTAssertEqual(pipeline.sampleCount, 4)
            XCTAssertEqual(pipeline.depthStencilFormat, .depth32FloatStencil8)
            XCTAssertEqual(pipeline.vertexLayout?.attributes.count, 3)
            XCTAssertEqual(pipeline.vertexLayout?.attributes[2]?.offset, MemoryLayout<LabelVertex>.offset(of: \.spriteUV))
        }
    }

    func testEveryHaloDrawsBeforeEveryFillInTheTilesPlace() throws {
        let fixture = try Fixture()
        let bold = try item(fixture.device, tile: Tile(x: 1, y: 1, z: 2), weight: .bold, vertexStart: 0, vertexCount: 12)
        let thin = try item(fixture.device, tile: Tile(x: 2, y: 1, z: 2), weight: .thin, vertexStart: 12, vertexCount: 6)
        let encoder = fixture.draw([bold, thin],
                                   frame: frame(surface: .flat(FlatRenderState(pan: .zero, renderMapSize: 4))))

        let haloPasses = encoder.commands.compactMap { command -> Float? in
            guard case let .setFragmentBytes(bytes, 0) = command else { return nil }
            return bytes.withUnsafeBytes { $0.loadUnaligned(as: SurfaceLabelDrawUniform.self) }.haloPass
        }
        XCTAssertEqual(haloPasses, [1, 1, 0, 0], "Both halos, then both fills")
        let draws = encoder.commands.compactMap { command -> Int? in
            if case let .draw(_, start, count, _, _) = command { return start * 100 + count }
            return nil
        }
        XCTAssertEqual(draws, [12, 1206, 12, 1206])
        let boldVertices = try XCTUnwrap(bold.vertices.gpuBuffer as? RecordingBuffer)
        XCTAssertTrue(encoder.commands.contains(.setVertexBuffer(boldVertices.name, offset: 16, index: 0)),
                      "The label's vertices are read from its tile's buffer, at the view's offset")
        XCTAssertNotNil(encoder.vertexValue(at: 3, as: matrix_float4x4.self), "The flat map places the tile by a matrix")
        XCTAssertTrue(encoder.commands.contains(.setFragmentTexture((fixture.textRenderer.thinTexture as! RecordingTexture).name,
                                                                    index: 0)))
        XCTAssertEqual(Array(encoder.commands.suffix(4)),
                       [.setCullMode(.none), .setFrontFacing(.clockwise),
                        .setDepthStencilState(GPUDepthStencilDescriptor()), .popDebugGroup])
    }

    func testALabelWithNoHaloDrawsOnlyItsFill() throws {
        let fixture = try Fixture()
        let bare = try item(fixture.device, tile: Tile(x: 0, y: 0, z: 1), weight: .bold, haloEm: 0,
                            vertexStart: 0, vertexCount: 6)
        let encoder = fixture.draw([bare], frame: frame(surface: .flat(FlatRenderState(pan: .zero, renderMapSize: 2))))
        let drawCount = encoder.commands.filter { if case .draw = $0 { return true } else { return false } }.count
        XCTAssertEqual(drawCount, 1)
    }

    func testTheGlobeBindsItsUniformsAndTheMorphPicksItsPipeline() throws {
        let fixture = try Fixture()
        let label = try item(fixture.device, tile: Tile(x: 0, y: 0, z: 1), weight: .bold, vertexStart: 0, vertexCount: 6)
        let globe = GlobeUniform(panX: 0, panY: 0, radius: 1, transition: 0.5)
        let encoder = fixture.draw([label], frame: frame(surface: .sphere(globe: globe, pureSphere: false, handover: 0.25)))
        let pipeline = try XCTUnwrap(encoder.commands.compactMap { command -> String? in
            if case let .setPipeline(descriptor) = command { return descriptor.vertexFunction.name }
            return nil
        }.first)
        XCTAssertEqual(pipeline, "surfaceLabelMorphVertex")
        XCTAssertEqual(encoder.vertexValue(at: 8, as: GlobeUniform.self)?.transition, 0.5)
        XCTAssertNotNil(encoder.vertexValue(at: 10, as: GlobeFrameConstantsUniform.self))
        XCTAssertNotNil(encoder.vertexValue(at: 9, as: GlobeSurfaceTileUniform.self), "The sphere places the tile by its uniform")
    }

    func testNoLabelsDrawNothing() throws {
        let fixture = try Fixture()
        XCTAssertTrue(fixture.draw([], frame: frame(surface: .flat(FlatRenderState(pan: .zero, renderMapSize: 2)))).commands.isEmpty)
    }
}
