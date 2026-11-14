// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import ImmersiveMapGPU
import ImmersiveMapGPUTestSupport
import XCTest
@testable import ImmersiveMap

/// The pipelines of the features whose shaders are ported to WGSL, as the
/// engine describes them and as WebGPU names their values
/// (`WebGPUConversions.swift`), held to `Tools/WGSLCheck/pipelines.json`,
/// which the WGSL check builds with Dawn against the WGSL entry points. A
/// pipeline that changes on the Swift side alone fails here: run this test
/// once with `IMMERSIVE_MAP_WRITE_PIPELINE_MANIFEST=1` to write the file
/// anew, then `node Tools/WGSLCheck/check.mjs`.
final class WGSLPipelineManifestTests: XCTestCase {
    struct Manifest: Codable, Equatable {
        var pipelines: [Pipeline]
    }

    struct Pipeline: Codable, Equatable {
        struct Stage: Codable, Equatable {
            var entryPoint: String
            var constants: [String: Double]
        }

        struct Buffer: Codable, Equatable {
            struct Attribute: Codable, Equatable {
                var format: String
                var offset: Int
                var shaderLocation: Int
            }

            var arrayStride: Int
            var attributes: [Attribute]
        }

        struct Target: Codable, Equatable {
            struct Component: Codable, Equatable {
                var srcFactor: String
                var dstFactor: String
                var operation: String
            }

            struct Blend: Codable, Equatable {
                var color: Component
                var alpha: Component
            }

            var format: String
            var blend: Blend?
            var writesColor: Bool
        }

        var label: String
        var vertex: Stage
        var buffers: [Buffer?]
        var fragment: Stage?
        var targets: [Target]
        var depthStencilFormat: String?
        var sampleCount: Int
        var topology: String
    }

    private static let manifestURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tools/WGSLCheck/pipelines.json")

    /// The ported features' pipelines, made as the engine makes them, with
    /// the world pass's multisampling.
    private func recordedPipelines() -> [GPURenderPipelineDescriptor] {
        let device = RecordingGPUDevice()
        _ = GlobeCapPipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4)
        _ = GroundShadowMaskPipeline(device: device)
        _ = ExtrudedTilePipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4)
        _ = TextRenderer(device: device, resource: TestResources.url, sampleCount: 4)
        _ = SurfaceLabelPipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4)
        return device.pipelines
    }

    private static func stage(_ function: GPUShaderFunction) -> Pipeline.Stage {
        Pipeline.Stage(entryPoint: function.name,
                       constants: Dictionary(uniqueKeysWithValues: function.constants.map { (String($0.key), $0.value.webGPU) }))
    }

    private static func pipeline(_ descriptor: GPURenderPipelineDescriptor) -> Pipeline {
        let buffers = (descriptor.vertexLayout?.webGPUBuffers ?? []).map { buffer in
            buffer.map { buffer in
                Pipeline.Buffer(arrayStride: buffer.arrayStride,
                                attributes: buffer.attributes.map {
                                    Pipeline.Buffer.Attribute(format: $0.format, offset: $0.offset, shaderLocation: $0.shaderLocation)
                                })
            }
        }
        let targets = descriptor.colorTargets.map { target in
            Pipeline.Target(format: target.format.webGPU,
                            blend: target.blend.map { blend in
                                func component(_ component: GPUBlendComponent) -> Pipeline.Target.Component {
                                    Pipeline.Target.Component(srcFactor: component.source.webGPU,
                                                              dstFactor: component.destination.webGPU,
                                                              operation: component.operation.webGPU)
                                }
                                return Pipeline.Target.Blend(color: component(blend.color), alpha: component(blend.alpha))
                            },
                            writesColor: target.writesColor)
        }
        return Pipeline(label: descriptor.label ?? descriptor.vertexFunction.name,
                        vertex: stage(descriptor.vertexFunction),
                        buffers: buffers,
                        fragment: descriptor.fragmentFunction.map(stage),
                        targets: targets,
                        depthStencilFormat: descriptor.depthStencilFormat?.webGPU,
                        sampleCount: descriptor.sampleCount,
                        topology: descriptor.topology.webGPU)
    }

    func testTheManifestIsThePipelinesTheEngineMakes() throws {
        let manifest = Manifest(pipelines: recordedPipelines().map(Self.pipeline).sorted { $0.label < $1.label })
        if ProcessInfo.processInfo.environment["IMMERSIVE_MAP_WRITE_PIPELINE_MANIFEST"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: Self.manifestURL)
            return
        }
        let data = try XCTUnwrap(FileManager.default.contents(atPath: Self.manifestURL.path),
                                 "No pipelines.json: write it with IMMERSIVE_MAP_WRITE_PIPELINE_MANIFEST=1")
        let committed = try JSONDecoder().decode(Manifest.self, from: data)
        XCTAssertEqual(committed.pipelines.map(\.label), manifest.pipelines.map(\.label))
        for (committedPipeline, pipeline) in zip(committed.pipelines, manifest.pipelines) {
            XCTAssertEqual(committedPipeline, pipeline,
                           "\(pipeline.label) changed: write pipelines.json anew with IMMERSIVE_MAP_WRITE_PIPELINE_MANIFEST=1")
        }
    }

    func testEveryWGSLEntryPointIsBuiltByAManifestPipeline() throws {
        let manifest = recordedPipelines().map(Self.pipeline)
        let used = Set(manifest.flatMap { [$0.vertex.entryPoint] + ($0.fragment.map { [$0.entryPoint] } ?? []) })
        var entryPoints: [String] = []
        for file in try WGSLSources.files() {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
            for (index, line) in lines.enumerated() where line.hasPrefix("@vertex") || line.hasPrefix("@fragment") {
                guard index + 1 < lines.count, let name = lines[index + 1].split(separator: "(").first?.split(separator: " ").last else { continue }
                entryPoints.append(String(name))
            }
        }
        XCTAssertFalse(entryPoints.isEmpty)
        for entryPoint in entryPoints {
            XCTAssertTrue(used.contains(entryPoint),
                          "\(entryPoint) is in a WGSL file but no ported pipeline builds it: add its pipeline to recordedPipelines()")
        }
        for name in used {
            XCTAssertTrue(entryPoints.contains(name), "\(name) is built by a pipeline but is in no WGSL file")
        }
    }
}
