// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapGPUTestSupport
import simd
import XCTest
@testable import ImmersiveMap

/// What the pins ask of the GPU, recorded: their three pipelines, the
/// bubble's field, the instanced quads of a frame, and what a frame draws
/// where the host gives no drawer. No picture: the pins are judged in the
/// app.
final class PinDrawTests: XCTestCase {
    private let device = RecordingGPUDevice()

    private func makeShared() throws -> PinsRenderer.SharedResources {
        let pinSDF = try PinSDFResource.load(device: device, resource: TestResources.url)
        return PinsRenderer.SharedResources.make(device: device, pixelFormat: .bgra8Unorm, pinSDF: pinSDF)
    }

    func testThePipelinesAreTheBodiesTheCountersAndTheBeams() throws {
        _ = try makeShared()
        let pipelines = device.pipelines
        XCTAssertEqual(pipelines.map(\.vertexFunction.name), ["pinVertex", "pinBeamVertex", "pinCountBadgeVertex"])
        XCTAssertEqual(pipelines.map { $0.fragmentFunction?.name }, ["pinFragment", "pinBeamFragment", "pinCountBadgeFragment"])
        for pipeline in pipelines {
            XCTAssertEqual(pipeline.sampleCount, 1, "the pins draw in the overlay pass")
            XCTAssertEqual(pipeline.depthStencilFormat, .depth32FloatStencil8)
            let blend = try XCTUnwrap(pipeline.colorTargets.first?.blend)
            XCTAssertEqual(blend.color, GPUBlendComponent(source: .sourceAlpha, destination: .oneMinusSourceAlpha))
            XCTAssertEqual(blend.alpha, GPUBlendComponent(source: .one, destination: .oneMinusSourceAlpha))
        }
    }

    func testTheBubblesFieldIsItsPictureCheckedAgainstItsMetadata() throws {
        let pinSDF = try PinSDFResource.load(device: device, resource: TestResources.url)
        XCTAssertEqual(pinSDF.texture.format, .rgba8Unorm)
        XCTAssertEqual(pinSDF.texture.width, 256)
        XCTAssertEqual(pinSDF.texture.height, 256)
        XCTAssertEqual(pinSDF.params.distanceRangeTexels, 32)
        XCTAssertEqual(pinSDF.shapeMetrics.pointerHeightRatio, 0.046875)
    }

    func testAFrameDrawsOneInstancedQuadAPin() throws {
        let renderer = PinsRenderer(device: device, sharedResources: try makeShared(),
                                    config: ImmersiveMapSettings.default.pins)
        let encoder = try drawFrame(renderer: renderer, pins: [
            Self.pin(id: 1, latitude: 0.0, longitude: 0.0),
            Self.pin(id: 2, latitude: 0.001, longitude: 0.001)
        ])
        let draws = encoder.commands.compactMap { command -> Int? in
            if case let .draw(.triangle, 0, 6, instanceCount, 0) = command { return instanceCount }
            return nil
        }
        XCTAssertEqual(draws.last, 2, "both pins in one instanced draw")
        let pipelines = encoder.commands.compactMap { command -> String? in
            if case let .setPipeline(descriptor) = command { return descriptor.vertexFunction.name }
            return nil
        }
        XCTAssertTrue(pipelines.contains("pinVertex"))
        // The atlas and the shape's field are bound to the fragment stage.
        let fragmentTextures = encoder.commands.compactMap { command -> Int? in
            if case let .setFragmentTexture(name, index) = command, name != nil { return index }
            return nil
        }
        XCTAssertEqual(Set(fragmentTextures), [0, 1])
    }

    func testAMapWithoutPinsDrawsNothingAndMakesNoAtlas() throws {
        let renderer = PinsRenderer(device: device, sharedResources: try makeShared(),
                                    config: ImmersiveMapSettings.default.pins)
        let texturesBefore = device.textures.count
        let encoder = try drawFrame(renderer: renderer, pins: [])
        XCTAssertTrue(encoder.commands.isEmpty)
        XCTAssertEqual(device.textures.count, texturesBefore)
    }

    func testTheHalfOfAFractionIsTheNearestHalf() {
        XCTAssertEqual(PinShapeDistanceField.halfBits(ofUnorm: 0), 0)
        XCTAssertEqual(PinShapeDistanceField.halfBits(ofUnorm: 65535), 0x3C00, "1.0")
        XCTAssertEqual(PinShapeDistanceField.halfBits(ofUnorm: 32768), 0x3800, "0.500008 rounds to 0.5")
        // Every value comes back within half a step of its half.
        for value in stride(from: 1, through: 65535, by: 97) {
            let unorm = UInt16(value)
            let fraction = Float(unorm) / 65535
            let half = Float(Float16(bitPattern: PinShapeDistanceField.halfBits(ofUnorm: unorm)))
            XCTAssertEqual(half, fraction, accuracy: max(fraction / 2048, 1.0 / 16_777_216), "\(unorm)")
        }
    }

    func testAFieldIsAFloatTextureWhereTheDeviceHasNoUnorm16() throws {
        let webGPU = RecordingGPUDevice(features: [.depthClamp])
        let texture = try XCTUnwrap(PinShapeDistanceField.makeTexture(device: webGPU, shape: .picture()))
        XCTAssertEqual(texture.format, .r16Float)
        let metal = try XCTUnwrap(PinShapeDistanceField.makeTexture(device: device, shape: .picture()))
        XCTAssertEqual(metal.format, .r16Unorm)
    }

    #if !canImport(CoreGraphics)
    func testWithoutADrawerAPathShapeIsDrawnAsTheBubbleAndACounterIsLeftOut() throws {
        let previous = PinPictureHost.drawer
        PinPictureHost.drawer = nil
        defer { PinPictureHost.drawer = previous }
        var config = ImmersiveMapSettings.default.pins
        config.shape = .circle
        let shared = try makeShared()
        let renderer = PinsRenderer(device: device, sharedResources: shared, config: config)
        var pin = Self.pin(id: 1, latitude: 0, longitude: 0)
        pin.countBadge = PinCountBadge(count: 4)
        let encoder = try drawFrame(renderer: renderer, pins: [pin])

        let bubble = try XCTUnwrap(shared.pinSDF.texture as? RecordingTexture)
        XCTAssertTrue(encoder.commands.contains { command in
            if case let .setFragmentTexture(name, 1) = command { return name == bubble.name }
            return false
        }, "the bubble's field stands in for the circle")
        let pipelines = encoder.commands.compactMap { command -> String? in
            if case let .setPipeline(descriptor) = command { return descriptor.vertexFunction.name }
            return nil
        }
        XCTAssertFalse(pipelines.contains("pinCountBadgeVertex"), "no counter picture, no counter pass")
    }
    #endif

    // MARK: - A frame

    private func drawFrame(renderer: PinsRenderer, pins: [ImmersiveMapPin]) throws -> RecordingRenderEncoder {
        let controller = ImmersiveMapPinsController()
        for pin in pins {
            controller.add(pin)
        }
        renderer.update(controller: controller, time: 0)
        renderer.compute(drawSize: CGSize(width: 800, height: 600),
                         cameraUniform: Self.orthographicCamera(width: 800, height: 600),
                         resolvedPresentation: Self.flatPresentation(renderMapSize: 1_000_000),
                         time: 1,
                         frameSlotIndex: 0)
        let encoder = RecordingRenderEncoder()
        renderer.drawPins(renderEncoder: encoder,
                          screenMatrix: matrix_identity_float4x4,
                          time: 1,
                          frameSlotIndex: 0)
        return encoder
    }

    private static let picture = PinImage(width: 2, height: 2, premultipliedBGRA: [UInt8](repeating: 255, count: 16))

    private static func pin(id: UInt64, latitude: Double, longitude: Double) -> ImmersiveMapPin {
        ImmersiveMapPin(id: id,
                        coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                        image: picture)
    }

    /// The map's center at the screen's: the flat map's pan puts latitude
    /// 0, longitude 0 in the middle.
    private static func flatPresentation(renderMapSize: Double) -> ResolvedPresentationState {
        ResolvedPresentationState(
            semanticWorldState: SemanticWorldState(cameraState: .default),
            presentationState: ImmersiveMapPresentationState(transition: 1),
            renderNormalizationState: RenderNormalizationState(zoomScale: 1,
                                                               globeRenderRadius: 1,
                                                               flatRenderMapSize: renderMapSize),
            renderSurfaceMode: .flat,
            screenSpaceProjectionMode: .flat,
            globeRenderState: GlobeRenderState(pan: SIMD2<Double>(0, 0),
                                               renderRadius: 1,
                                               globeUniform: GlobeUniform(panX: 0,
                                                                          panY: 0,
                                                                          radius: 1,
                                                                          transition: 1)),
            flatRenderState: FlatRenderState(pan: SIMD2<Double>(0, 0),
                                             renderMapSize: renderMapSize)
        )
    }

    private static func orthographicCamera(width: Float, height: Float) -> CameraUniform {
        var matrix = matrix_identity_float4x4
        matrix.columns.0.x = 2.0 / width
        matrix.columns.1.y = 2.0 / height
        matrix.columns.2.z = 0.0
        return CameraUniform(matrix: matrix, eye: SIMD3<Float>(0, 0, 1), padding: 0)
    }
}
