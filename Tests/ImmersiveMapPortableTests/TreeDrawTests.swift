// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import ImmersiveMapGPU
import ImmersiveMapGPUTestSupport
import simd
import XCTest
@testable import ImmersiveMap

/// What the trees ask of the GPU, recorded: the model in one buffer, its
/// pipelines, a draw of each tile's instances at the model's level, and the
/// shadow discs. No picture: the trees are judged in the app.
final class TreeDrawTests: XCTestCase {
    private static let modelURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ImmersiveMap/Tile/Trees/Resources/tree_broadleaf.immtree")

    private func makeMesh(device: RecordingGPUDevice) async throws -> TreeModelMesh {
        let data = try Data(contentsOf: Self.modelURL)
        let contents = try TreeModelContents.read(data)
        return try await TreeModelMesh.make(contents: contents, data: data, fileURL: Self.modelURL, device: device)
    }

    private static func emptyLayer() -> TileBuffers.GeometryLayer {
        TileBuffers.GeometryLayer(vertices: nil, indices: nil, styles: nil, styleZoomFade: nil, lineStyles: nil, indexType: .uint16)
    }

    /// A tile with `count` trees in one buffer.
    private func makePlacement(device: RecordingGPUDevice, tile: Tile, count: Int) throws -> PlaceTile {
        let instances = (0 ..< count).map { TreeInstance(position: SIMD2(Float($0) * 100, 50), height: 40, rotation: 0, tint: 0.5) }
        let buffer = try XCTUnwrap(device.makeBuffer(instances, storage: .shared))
        let ground = Self.emptyLayer()
        let phases = RoadGeometryPhases(shadow: ground, casing: ground, fill: ground, detail: ground, overlay: ground)
        var buffers = TileBuffers(gpuBackingBuffer: buffer,
                                  ground: ground,
                                  roads: RoadStructureBuckets(tunnel: phases, ground: phases, automobileGround: phases, bridge: phases),
                                  bridgeOverlay: ground,
                                  extruded: TileBuffers.Extruded(vertices: nil, indices: nil, styles: nil, gpuIndexType: .uint16),
                                  textLabels: TileBuffers.TextLabelSet(placementInputs: [], labelsByStyleRuns: [], poiIconRuns: []),
                                  roadLabels: TileBuffers.RoadLabels(pathInputs: [], pathRanges: [], pathLabels: [], labelStyle: nil,
                                                                     localGlyphVertices: nil, glyphBounds: [], glyphBoundRanges: [],
                                                                     sizes: [], anchorRanges: [], anchors: []))
        buffers.trees = TileBufferView(gpuBuffer: buffer, offset: 0, count: count)
        return PlaceTile(metalTile: MetalTile(tile: tile, tileBuffers: buffers), placeIn: VisibleTile(tile: tile))
    }

    private func states(_ device: RecordingGPUDevice) throws -> (test: any GPUDepthStencilState, disabled: any GPUDepthStencilState) {
        var test = GPUDepthStencilDescriptor()
        test.depthCompare = .less
        return (try XCTUnwrap(device.makeDepthStencilState(test)),
                try XCTUnwrap(device.makeDepthStencilState(GPUDepthStencilDescriptor())))
    }

    func testThePipelinesReadTheModelVertexAndMultiplyTheShadowsIn() throws {
        let device = RecordingGPUDevice(shaderFunctions: ["treeVertexShader", "treeFragmentShader",
                                                          "treeShadowVertexShader", "treeShadowFragmentShader"])
        _ = TreePipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4)
        let trees = try XCTUnwrap(device.pipelines.first { $0.label == "Trees" })
        let layout = try XCTUnwrap(trees.vertexLayout)
        XCTAssertEqual(layout.attributes[1], GPUVertexAttribute(format: .char4Normalized, offset: 12, bufferIndex: 0))
        XCTAssertEqual(layout.attributes[2], GPUVertexAttribute(format: .uchar4Normalized, offset: 16, bufferIndex: 0))
        XCTAssertEqual(layout.strides[0], TreeModelContents.vertexStride)
        XCTAssertNil(trees.colorTargets.first?.blend, "The trees are opaque")
        let shadows = try XCTUnwrap(device.pipelines.first { $0.label == "TreeShadows" })
        XCTAssertNil(shadows.vertexLayout, "The discs are made from the vertex index")
        XCTAssertEqual(shadows.colorTargets.first?.blend?.color, GPUBlendComponent(source: .destinationColor, destination: .zero))
        XCTAssertEqual(shadows.colorTargets.first?.blend?.alpha, GPUBlendComponent(source: .zero, destination: .one))
        XCTAssertEqual(shadows.sampleCount, 4)
    }

    func testTheModelIsCopiedWholeWithoutAFileLoader() async throws {
        let device = RecordingGPUDevice()
        let mesh = try await makeMesh(device: device)
        let buffer = try XCTUnwrap(mesh.buffer as? RecordingBuffer)
        XCTAssertEqual(buffer.length, mesh.contents.byteCount)
        XCTAssertEqual(buffer.label, "TreeModel")
        let file = try Data(contentsOf: Self.modelURL)
        XCTAssertEqual(Data(bytes: buffer.contents(), count: 16), file.prefix(16))
    }

    func testAFileLoaderThatFillsTheBufferIsTrusted() async throws {
        let device = RecordingGPUDevice()
        let data = try Data(contentsOf: Self.modelURL)
        let contents = try TreeModelContents.read(data)
        let mesh = try await TreeModelMesh.make(contents: contents, data: data, fileURL: Self.modelURL, device: device,
                                                fileLoader: { buffer, _, length in
                                                    buffer.contents().initializeMemory(as: UInt8.self, repeating: 7, count: length)
                                                    return true
                                                })
        XCTAssertEqual(mesh.buffer.contents().load(as: UInt8.self), 7, "The loader's bytes are kept, not copied over")
    }

    func testEachTileDrawsItsInstancesAtTheModelsLevel() async throws {
        let device = RecordingGPUDevice()
        let pipeline = TreePipeline(device: device, pixelFormat: .bgra8Unorm)
        let mesh = try await makeMesh(device: device)
        let (test, disabled) = try states(device)
        let placement = try makePlacement(device: device, tile: Tile(x: 3, y: 2, z: 14), count: 10)
        let item = TreeDrawer.Item(placement: placement, instanceRanges: [0 ..< 4, 6 ..< 10], riseScale: 1)
        let encoder = RecordingRenderEncoder()

        TreeDrawer.draw(renderEncoder: encoder,
                        cameraUniform: CameraUniform(matrix: matrix_identity_float4x4, eye: SIMD3(0, 0, 3), padding: 0),
                        items: [item],
                        mesh: mesh,
                        level: 1,
                        palette: ImmersiveMapTreePalette.default,
                        flatRenderState: FlatRenderState(pan: .zero, renderMapSize: 4),
                        lightDirection: SIMD3(0, 0, 1),
                        pipeline: pipeline,
                        stencilTestState: test,
                        depthDisabledState: disabled)

        let level = mesh.contents.levels[1]
        let draws = encoder.commands.compactMap { command -> Int? in
            guard case let .drawIndexed(_, indexCount, indexType, _, offset, instanceCount, _, _) = command else { return nil }
            XCTAssertEqual(indexCount, level.indexCount)
            XCTAssertEqual(indexType, .uint16)
            XCTAssertEqual(offset, level.indexOffset)
            return instanceCount
        }
        XCTAssertEqual(draws, [4, 4], "One draw per run of instances")
        let treesBuffer = try XCTUnwrap(placement.metalTile.tileBuffers.trees?.gpuBuffer as? RecordingBuffer)
        XCTAssertTrue(encoder.commands.contains(.setVertexBuffer(treesBuffer.name, offset: 6 * MemoryLayout<TreeInstance>.stride, index: 4)))
        XCTAssertTrue(encoder.commands.contains(.setStencilReference(TileSourceStencilPriority.reference(sourceZoom: 14)
                                                                         | TileSourceStencilPriority.surfaceMaskBit)))
        XCTAssertNotNil(encoder.vertexValue(at: 7, as: TreeFrameUniform.self))
        XCTAssertEqual(Array(encoder.commands.suffix(2)), [.setCullMode(.none), .setDepthStencilState(GPUDepthStencilDescriptor())])
    }

    func testShadowsDrawAQuadPerTreeAndNothingWithoutStrength() async throws {
        let device = RecordingGPUDevice()
        let pipeline = TreePipeline(device: device, pixelFormat: .bgra8Unorm)
        let mesh = try await makeMesh(device: device)
        let (test, disabled) = try states(device)
        let placement = try makePlacement(device: device, tile: Tile(x: 3, y: 2, z: 14), count: 5)
        let item = TreeDrawer.Item(placement: placement, instanceRanges: [0 ..< 5], riseScale: 1)
        func drawShadows(strength: Float) -> RecordingRenderEncoder {
            var shadow = ShadowUniform.disabled
            shadow.strength = strength
            let encoder = RecordingRenderEncoder()
            TreeDrawer.drawShadows(renderEncoder: encoder,
                                   cameraUniform: CameraUniform(matrix: matrix_identity_float4x4, eye: .zero, padding: 0),
                                   shadowUniform: shadow,
                                   items: [item],
                                   mesh: mesh,
                                   palette: ImmersiveMapTreePalette.default,
                                   flatRenderState: FlatRenderState(pan: .zero, renderMapSize: 4),
                                   lightDirection: SIMD3(0, 0, 1),
                                   pipeline: pipeline,
                                   groundDepthState: test,
                                   depthDisabledState: disabled)
            return encoder
        }
        let encoder = drawShadows(strength: 0.5)
        XCTAssertTrue(encoder.commands.contains(.draw(.triangle, vertexStart: 0, vertexCount: 6, instanceCount: 5, baseInstance: 0)))
        XCTAssertEqual(encoder.fragmentValue(at: 5, as: ShadowUniform.self)?.strength, 0.5)
        XCTAssertTrue(drawShadows(strength: 0).commands.isEmpty, "No sun, no discs")
    }
}
