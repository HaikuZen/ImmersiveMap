// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapGPUTestSupport
import simd
import XCTest
@testable import ImmersiveMap

/// What the polar caps ask of the GPU, recorded: their pipeline, the two
/// fan grids, and one draw per pole in its own colour, with the far half
/// culled. No picture: the caps are judged in the app.
final class GlobeCapDrawTests: XCTestCase {
    private let baseColors = ImmersiveMapBaseColors(map: SIMD4<Float>(0.09, 0.10, 0.13, 1),
                                                    northCap: SIMD4<Float>(0.04, 0.09, 0.20, 1),
                                                    southCap: SIMD4<Float>(0.30, 0.32, 0.36, 1))

    private func makeShared(device: RecordingGPUDevice) -> GlobeCapRenderer.SharedResources {
        GlobeCapRenderer.SharedResources.make(device: device,
                                              pixelFormat: .bgra8Unorm,
                                              sampleCount: 4,
                                              maxLatitude: WebMercatorMath.maxLatitudeRadians)
    }

    func testThePipelineBlendsLatitudeLongitudeVertices() throws {
        let device = RecordingGPUDevice(shaderFunctions: ["globeCapVertexShader", "globeCapFragmentShader"])
        _ = makeShared(device: device)
        let pipeline = try XCTUnwrap(device.pipelines.first)
        XCTAssertEqual(device.pipelines.count, 1)
        XCTAssertEqual(pipeline.sampleCount, 4)
        XCTAssertEqual(pipeline.depthStencilFormat, .depth32FloatStencil8)
        XCTAssertEqual(pipeline.colorTargets.first?.blend?.color,
                       GPUBlendComponent(source: .sourceAlpha, destination: .oneMinusSourceAlpha))
        XCTAssertEqual(pipeline.colorTargets.first?.blend?.alpha,
                       GPUBlendComponent(source: .one, destination: .oneMinusSourceAlpha))
        let layout = try XCTUnwrap(pipeline.vertexLayout)
        XCTAssertEqual(layout.attributes, [0: GPUVertexAttribute(format: .float2, offset: 0, bufferIndex: 0)])
        XCTAssertEqual(layout.strides[0], MemoryLayout<CapGeometry.Vertex>.stride)
    }

    func testEachCapGridIsUploadedWithNarrowedIndices() throws {
        let device = RecordingGPUDevice()
        let shared = makeShared(device: device)
        let maxLatitude = Float(WebMercatorMath.maxLatitudeRadians)
        for (buffers, isNorth) in [(shared.northCapBuffers, true), (shared.southCapBuffers, false)] {
            let grid = CapGeometry.createCapGrid(stacks: 12, slices: 48, isNorth: isNorth, maxLatitude: maxLatitude)
            XCTAssertEqual(buffers.indexType, .uint16, "A cap grid is small enough for 16-bit indices")
            XCTAssertEqual(buffers.indicesCount, grid.indices.count)
            let indices = try XCTUnwrap(buffers.indicesBuffer as? RecordingBuffer).values(as: UInt16.self)
            XCTAssertEqual(indices.map(UInt32.init), grid.indices)
            let vertices = try XCTUnwrap(buffers.verticesBuffer as? RecordingBuffer).values(as: CapGeometry.Vertex.self)
            XCTAssertEqual(vertices.map(\.latLon), grid.vertices.map(\.latLon))
        }
    }

    func testAFrameDrawsEachPoleInItsColourWithTheFarHalfCulled() throws {
        let device = RecordingGPUDevice()
        let renderer = GlobeCapRenderer(sharedResources: makeShared(device: device),
                                        maxLatitude: WebMercatorMath.maxLatitudeRadians,
                                        baseColors: baseColors)
        let encoder = RecordingRenderEncoder()
        let globe = GlobeUniform(panX: 0.1, panY: -0.2, radius: 0.7, transition: 0)
        renderer.draw(renderEncoder: encoder,
                      globeFrame: GlobeFrameConstantsUniform.make(globe: globe, cameraMatrix: matrix_identity_float4x4),
                      globe: globe)

        let commands = encoder.commands
        XCTAssertEqual(commands.first, .setPipeline(try XCTUnwrap(device.pipelines.first)))
        XCTAssertTrue(commands.contains(.setFrontFacing(.counterClockwise)))
        XCTAssertTrue(commands.contains(.setCullMode(.back)))
        XCTAssertEqual(encoder.vertexValue(at: 2, as: GlobeUniform.self)?.radius, 0.7)
        XCTAssertNotNil(encoder.vertexValue(at: 10, as: GlobeFrameConstantsUniform.self))
        XCTAssertEqual(encoder.fragmentValue(at: GlobeLightUniform.bufferIndex, as: GlobeLightUniform.self)?.lightAndStrength,
                       GlobeLightUniform.disabled.lightAndStrength)

        // The colour set before each draw, in draw order.
        var colours: [SIMD4<Float>] = []
        var drawnColours: [SIMD4<Float>] = []
        var drawnBuffers: [String] = []
        for command in commands {
            switch command {
            case let .setFragmentBytes(bytes, index) where index == 0:
                colours.append(bytes.withUnsafeBytes { $0.loadUnaligned(as: GlobeCapParams.self) }.color)
            case let .drawIndexed(topology, _, indexType, indexBuffer, _, instanceCount, _, _):
                XCTAssertEqual(topology, .triangle)
                XCTAssertEqual(indexType, .uint16)
                XCTAssertEqual(instanceCount, 1)
                drawnColours.append(try XCTUnwrap(colours.last))
                drawnBuffers.append(indexBuffer)
            default:
                break
            }
        }
        XCTAssertEqual(drawnColours, [SIMD4<Float>(0.04, 0.09, 0.20, 1), SIMD4<Float>(0.30, 0.32, 0.36, 1)])
        XCTAssertEqual(drawnBuffers, ["buffer 1", "buffer 3"], "The north grid's indices, then the south's")
        XCTAssertEqual(Array(commands.suffix(2)), [.setCullMode(.none), .setFrontFacing(.clockwise)],
                       "The shared encoder is handed back in its defaults")
    }
}
