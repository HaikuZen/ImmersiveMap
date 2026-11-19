// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
import ImmersiveMapGPU
import ImmersiveMapWebGPU
import simd
import XCTest
@testable import ImmersiveMap

/// Frames of moved features drawn through the WebGPU backend, their streams
/// held to `Web/test/frames/`, which `node Tools/WGSLCheck/frames.mjs` runs on
/// Dawn and fails on any WebGPU validation error: the pipelines, their
/// variants, the bindings the reflection finds and the placeholders, as a
/// browser would meet them. No picture. A change to what the features ask
/// of the GPU fails here: run this test once with
/// `IMMERSIVE_MAP_WRITE_WEBGPU_FRAMES=1` to write the streams anew, then the
/// Node run.
final class WebGPUFrameStreamTests: XCTestCase {
    private final class Sink: WebGPUCommandSink, @unchecked Sendable {
        var stream: [UInt8] = []

        func submit(_ bytes: UnsafeRawBufferPointer) {
            stream.append(contentsOf: bytes)
        }
    }

    private static let framesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Web/test/frames")

    /// The probe scene (`GPUProbeScene`), one frame of it at a fixed turn,
    /// into the canvas.
    private func probeSceneStream() throws -> [UInt8] {
        let sink = Sink()
        let device = WebGPUDevice(features: [.depthClamp], sink: sink)
        let scene = try XCTUnwrap(GPUProbeScene(device: device))
        scene.drawFrame(into: device.canvasTexture(format: .bgra8Unorm, width: 64, height: 64), width: 64, height: 64, turn: 0.1)
        withExtendedLifetime(scene) {}
        return sink.stream
    }

    func testTheFramesAreTheStreamsTheEngineWrites() throws {
        let frames = ["probe-scene.bin": try probeSceneStream()]
        if ProcessInfo.processInfo.environment["IMMERSIVE_MAP_WRITE_WEBGPU_FRAMES"] == "1" {
            try FileManager.default.createDirectory(at: Self.framesURL, withIntermediateDirectories: true)
            for (name, stream) in frames {
                try Data(stream).write(to: Self.framesURL.appendingPathComponent(name))
            }
            return
        }
        for (name, stream) in frames {
            let committed = try XCTUnwrap(FileManager.default.contents(atPath: Self.framesURL.appendingPathComponent(name).path),
                                          "No \(name): write it with IMMERSIVE_MAP_WRITE_WEBGPU_FRAMES=1")
            XCTAssertEqual(Array(committed), stream,
                           "\(name) changed: write it anew with IMMERSIVE_MAP_WRITE_WEBGPU_FRAMES=1, then run node Tools/WGSLCheck/frames.mjs")
        }
    }
}
