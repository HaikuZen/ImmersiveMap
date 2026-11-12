// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd
import XCTest
@testable import ImmersiveMap

/// Each WGSL uniform struct has its Swift twin's fields at the twin's
/// offsets and is as long as the bytes the engine sends
/// (`setVertexValue` sends the value's stride). A field that moves on one
/// side alone reads another field's bytes on the GPU, which no picture
/// test would point to.
final class WGSLLayoutTests: XCTestCase {
    private func layouts(_ path: String) throws -> [String: WGSLSources.Layout] {
        let url = WGSLSources.engineSources.appendingPathComponent(path)
        return try WGSLSources.layouts(in: String(contentsOf: url, encoding: .utf8))
    }

    private func assertLayout<T>(_ name: String, in path: String, matches _: T.Type,
                                 offsets: [Int?], file: StaticString = #filePath, line: UInt = #line) throws {
        let layout = try XCTUnwrap(try layouts(path)[name], "\(name) in \(path)", file: file, line: line)
        XCTAssertEqual(layout.members.map(\.offset), offsets.map { $0 ?? -1 },
                       "\(name)'s fields at the Swift twin's offsets", file: file, line: line)
        XCTAssertEqual(layout.size, MemoryLayout<T>.stride,
                       "\(name) as long as the bytes the engine sends", file: file, line: line)
    }

    func testTheSharedUniformsMatchTheirSwiftTwins() throws {
        let shared = "Render/Shaders/Shared/RenderUniforms.wgsl"
        try assertLayout("Camera", in: shared, matches: CameraUniform.self, offsets: [
            MemoryLayout<CameraUniform>.offset(of: \.matrix),
            MemoryLayout<CameraUniform>.offset(of: \.eye),
            MemoryLayout<CameraUniform>.offset(of: \.padding),
        ])
        try assertLayout("Globe", in: shared, matches: GlobeUniform.self, offsets: [
            MemoryLayout<GlobeUniform>.offset(of: \.panX),
            MemoryLayout<GlobeUniform>.offset(of: \.panY),
            MemoryLayout<GlobeUniform>.offset(of: \.radius),
            MemoryLayout<GlobeUniform>.offset(of: \.transition),
        ])
        try assertLayout("GlobeFrameConstants", in: shared, matches: GlobeFrameConstantsUniform.self, offsets: [
            MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \.rotation),
            MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \.sphereClip),
            MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \.sphereWorld),
            MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \.mapSize),
            MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \.panMercatorY),
            MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \.panLatitude),
            MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \.panLongitude),
            MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \.curvature),
            MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \._padding),
        ])
    }

    func testTheGlobesLightAndCapsMatchTheirSwiftTwins() throws {
        try assertLayout("GlobeLight", in: "Globe/Shaders/GlobeLight.wgsl", matches: GlobeLightUniform.self, offsets: [
            MemoryLayout<GlobeLightUniform>.offset(of: \.lightAndStrength),
            MemoryLayout<GlobeLightUniform>.offset(of: \.nightColorAndSoftness),
        ])
        try assertLayout("CapParams", in: "Globe/Shaders/Globe.wgsl", matches: GlobeCapParams.self, offsets: [
            MemoryLayout<GlobeCapParams>.offset(of: \.color),
        ])
    }

    func testAPlainVec3MovesTheFieldAfterIt() throws {
        // The rule the shared structs' @size(16) is for: without it, WGSL
        // puts the next field at 12 bytes past a vec3f, Swift at 16.
        let plain = try WGSLSources.layouts(in: "struct A { e: vec3f, p: f32, }")["A"]
        XCTAssertEqual(plain?.members.map(\.offset), [0, 12])
        let sized = try WGSLSources.layouts(in: "struct A { @size(16) e: vec3f, p: f32, }")["A"]
        XCTAssertEqual(sized?.members.map(\.offset), [0, 16])
        XCTAssertEqual(sized?.size, 32, "Rounded to the vec3f's alignment of 16")
    }
}
