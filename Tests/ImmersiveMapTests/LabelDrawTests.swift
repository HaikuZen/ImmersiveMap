// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapGPUTestSupport
import simd
import XCTest
@testable import ImmersiveMap

/// What the screen labels ask of the GPU, recorded: the text pipelines, the
/// atlas textures, and the draws of the base and the road labels. No
/// picture: the labels are judged in the app.
final class LabelDrawTests: XCTestCase {
    private func makeTextRenderer(device: RecordingGPUDevice) throws -> TextRenderer {
        let location = try ImmersiveMapResourceBundle.location()
        return TextRenderer(device: device,
                            resource: { location.url(forResource: $0, withExtension: $1) },
                            sampleCount: 4)
    }

    private func style(weight: LabelFontWeight) -> LabelTextStyle {
        LabelTextStyle(key: 1,
                       fillColor: SIMD3<Float>(0.2, 0.3, 0.4),
                       strokeColor: SIMD3<Float>(1, 1, 1),
                       haloEm: 0.15,
                       sizePoints: 20,
                       weight: weight)
    }

    private func view(_ device: RecordingGPUDevice, count: Int, offset: Int = 0) throws -> TileBufferView {
        let buffer = try XCTUnwrap(device.makeBuffer(length: offset + count * MemoryLayout<LabelVertex>.stride, storage: .shared))
        return TileBufferView(gpuBuffer: buffer, offset: offset, count: count)
    }

    private func name(_ texture: any GPUTexture) -> String {
        (texture as? RecordingTexture)?.name ?? "?"
    }

    private func draws(_ encoder: RecordingRenderEncoder) -> [Int] {
        encoder.commands.compactMap { command in
            if case let .draw(_, _, vertexCount, _, _) = command { return vertexCount }
            return nil
        }
    }

    func testTheTextPipelinesShareTheBlendAndTheLabelVertexLayout() throws {
        let device = RecordingGPUDevice(shaderFunctions: ["textVertex", "labelTextVertex", "roadLabelTextVertex",
                                                          "poiSpriteVertex", "poiSpriteFragment", "routeShieldFragment",
                                                          "textFragment", "roadTextFragment"])
        let renderer = try makeTextRenderer(device: device)
        XCTAssertEqual(device.pipelines.count, 5)
        for pipeline in device.pipelines {
            XCTAssertEqual(pipeline.sampleCount, 4)
            XCTAssertEqual(pipeline.depthStencilFormat, .depth32FloatStencil8)
            XCTAssertEqual(pipeline.colorTargets.first?.format, .bgra8Unorm)
            XCTAssertEqual(pipeline.colorTargets.first?.blend?.color,
                           GPUBlendComponent(source: .sourceAlpha, destination: .oneMinusSourceAlpha))
            XCTAssertEqual(pipeline.colorTargets.first?.blend?.alpha,
                           GPUBlendComponent(source: .one, destination: .oneMinusSourceAlpha))
        }
        let label = try XCTUnwrap((renderer.labelPipelineState as? RecordingRenderPipeline)?.descriptor)
        let layout = try XCTUnwrap(label.vertexLayout)
        XCTAssertEqual(layout.attributes[2]?.format, .int, "The label index")
        XCTAssertEqual(layout.attributes[2]?.offset, MemoryLayout<LabelVertex>.offset(of: \LabelVertex.labelIndex))
        XCTAssertEqual(layout.strides[0], MemoryLayout<LabelVertex>.stride)
        let road = try XCTUnwrap((renderer.roadLabelPipelineState as? RecordingRenderPipeline)?.descriptor)
        XCTAssertEqual(road.fragmentFunction?.name, "roadTextFragment")
        XCTAssertEqual(road.vertexLayout, label.vertexLayout)
        let shield = try XCTUnwrap((renderer.routeShieldPipelineState as? RecordingRenderPipeline)?.descriptor)
        XCTAssertEqual(shield.vertexFunction.name, "poiSpriteVertex", "The plates use the POI quad")
    }

    func testTheAtlasesAreUploadedIntoPrivateTexturesOfTheirSize() throws {
        let device = RecordingGPUDevice()
        let renderer = try makeTextRenderer(device: device)
        let bold = try XCTUnwrap(renderer.texture as? RecordingTexture)
        let thin = try XCTUnwrap(renderer.thinTexture as? RecordingTexture)
        XCTAssertFalse(bold === thin)
        XCTAssertEqual(bold.width, renderer.atlasData.atlas.width)
        XCTAssertEqual(thin.height, renderer.thinAtlasData.atlas.height)
        XCTAssertEqual(bold.descriptor.storage, .private, "The atlas keeps no CPU copy")
        XCTAssertEqual(bold.format, .bgra8Unorm)
    }

    func testMissingAtlasesFallBackToOneBlankTexel() {
        let device = RecordingGPUDevice()
        let renderer = TextRenderer(device: device, resource: { _, _ in nil })
        XCTAssertTrue(renderer.texture === renderer.thinTexture)
        XCTAssertEqual(renderer.texture.width, 1)
    }

    func testBaseLabelsDrawPOIsThenPlatesThenTextBindingEachStateOnce() throws {
        let device = RecordingGPUDevice()
        let renderer = try makeTextRenderer(device: device)
        let poiTexture = try XCTUnwrap(device.makeTexture(GPUTextureDescriptor(format: .bgra8Unorm, width: 64, height: 64)))
        let screenPositions = try XCTUnwrap(device.makeBuffer(length: 64, storage: .shared))
        let runtimeMeta = try XCTUnwrap(device.makeBuffer(length: 64, storage: .shared))
        let tileVertices = try view(device, count: 12)
        let batch = BaseLabelDrawBatch(
            labelsByStyleRuns: [LabelsByStyleRun(style: style(weight: .bold), localGlyphVertices: tileVertices),
                                LabelsByStyleRun(style: style(weight: .thin), localGlyphVertices: tileVertices)],
            poiIconRuns: [PoiIconRunBuffer(style: style(weight: .bold), localVertices: try view(device, count: 6))],
            routeShieldRuns: [],
            globalLabelStart: 5,
            labelInstanceCount: 2)
        let encoder = RecordingRenderEncoder()

        RendererLabelDrawer.drawBaseLabels(renderEncoder: encoder,
                                           screenMatrix: matrix_identity_float4x4,
                                           screenScale: .reference,
                                           textRenderer: renderer,
                                           poiSpriteTexture: poiTexture,
                                           screenPositionsBuffer: screenPositions,
                                           labelRuntimeMetaBuffer: runtimeMeta,
                                           baseLabelsDrawBatches: [batch])

        let pipelines = encoder.commands.compactMap { command -> String? in
            if case let .setPipeline(descriptor) = command { return descriptor.fragmentFunction?.name }
            return nil
        }
        XCTAssertEqual(pipelines, ["poiSpriteFragment", "textFragment"])
        XCTAssertEqual(draws(encoder), [6, 12, 12], "The POI quads, then one draw per text run")
        XCTAssertEqual(encoder.vertexValue(at: 7, as: Float.self), ScreenScale.reference.pixelsPerPoint)
        XCTAssertEqual(encoder.vertexValue(at: 3, as: simd_int1.self), 5, "Every run of the tile shifts by its first label")
        let textures = encoder.commands.compactMap { command -> String? in
            if case let .setFragmentTexture(name, 0) = command { return name }
            return nil
        }
        XCTAssertEqual(textures, [name(poiTexture), name(renderer.texture), name(renderer.thinTexture)])
        let shifts = encoder.commands.filter { if case .setVertexBytes(_, 3) = $0 { return true } else { return false } }
        XCTAssertEqual(shifts.count, 1, "The shift is bound once for the tile's runs")
    }

    func testRoadLabelsBindTheSceneDepthAndEachLabelsBuffers() throws {
        let device = RecordingGPUDevice()
        let renderer = try makeTextRenderer(device: device)
        let sceneDepth = try XCTUnwrap(device.makeTexture(GPUTextureDescriptor(format: .depth32FloatStencil8, width: 4, height: 4)))
        func buffer() throws -> any GPUBuffer { try XCTUnwrap(device.makeBuffer(length: 16, storage: .shared)) }
        let thinLabel = DrawRoadLabels(placementBuffer: try buffer(),
                                       glyphInputBuffer: try buffer(),
                                       runtimeMetaBuffer: try buffer(),
                                       localGlyphVertices: try view(device, count: 18),
                                       labelStyle: style(weight: .thin))
        let uniforms = RoadLabelSceneDepthUniforms(projectionView: matrix_identity_float4x4,
                                                   inverseProjectionView: matrix_identity_float4x4,
                                                   eye: SIMD3<Float>(0, 0, 5),
                                                   viewportSize: SIMD2<Float>(400, 300),
                                                   enabled: 1)
        let encoder = RecordingRenderEncoder()

        RendererLabelDrawer.drawRoadLabels(renderEncoder: encoder,
                                           screenMatrix: matrix_identity_float4x4,
                                           screenScale: .reference,
                                           textRenderer: renderer,
                                           roadDrawLabels: [thinLabel],
                                           sceneDepth: sceneDepth,
                                           sceneDepthUniforms: uniforms)

        let commands = encoder.commands
        XCTAssertTrue(commands.contains(.setFragmentTexture(name(sceneDepth), index: 1)))
        XCTAssertEqual(encoder.vertexValue(at: 8, as: RoadLabelSceneDepthUniforms.self)?.viewportSize, SIMD2<Float>(400, 300))
        XCTAssertEqual(encoder.fragmentValue(at: 1, as: RoadLabelSceneDepthUniforms.self)?.enabled, 1)
        for index in 2 ... 4 {
            XCTAssertTrue(commands.contains { command in
                if case let .setVertexBuffer(_, 0, at) = command { return at == index }
                return false
            }, "Buffer \(index) of the label is bound")
        }
        XCTAssertTrue(commands.contains(.setFragmentTexture(name(renderer.thinTexture), index: 0)), "A thin name reads the thin atlas")
        XCTAssertEqual(draws(encoder), [18])
    }

    func testNoRoadLabelsDrawNothing() throws {
        let device = RecordingGPUDevice()
        let renderer = TextRenderer(device: device, resource: { _, _ in nil })
        let encoder = RecordingRenderEncoder()
        RendererLabelDrawer.drawRoadLabels(renderEncoder: encoder,
                                           screenMatrix: matrix_identity_float4x4,
                                           screenScale: .reference,
                                           textRenderer: renderer,
                                           roadDrawLabels: [],
                                           sceneDepth: renderer.texture,
                                           sceneDepthUniforms: RoadLabelSceneDepthUniforms(projectionView: matrix_identity_float4x4,
                                                                                           inverseProjectionView: matrix_identity_float4x4,
                                                                                           eye: .zero,
                                                                                           viewportSize: .zero,
                                                                                           enabled: 0))
        XCTAssertTrue(encoder.commands.isEmpty)
    }
}
