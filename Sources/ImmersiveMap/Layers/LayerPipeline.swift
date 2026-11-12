// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import simd

/// The pipelines of the layers of the app's data (Layers.metal): zones,
/// lines and discs, each in one variant per surface the ground is drawn on
/// (`Surface`), in the world pass's formats and sample count, blended like
/// the ground. The shaders read their vertices from buffers by index, so
/// no vertex descriptor.
final class LayerPipeline {
    /// Mirrors `kLayerSurface` in Layers.metal.
    enum Surface: Int, CaseIterable {
        case flat = 0
        case sphere = 1
        case morph = 2
    }

    struct States {
        let fill: any GPURenderPipeline
        let line: any GPURenderPipeline
        let point: any GPURenderPipeline
    }

    private let statesBySurface: [Surface: States]
    /// How a layer is tested where it draws: never against the ground's
    /// depth (`overGround`) or against it, so the relief nearer the camera
    /// hides it (`behindTerrain`, `ImmersiveMapLayer.hidesBehindTerrain`).
    /// Both test the surface mask bit the buildings, the models and the
    /// trees raise where they stand (`TileSourceStencilPriority`), as the
    /// roads do, so whatever stands in front of a layer covers it, and
    /// neither writes depth or stencil. The reference is zero.
    let overGroundState: any GPUDepthStencilState
    let behindTerrainState: any GPUDepthStencilState

    init(device: any GPUDevice,
         pixelFormat: GPUPixelFormat,
         sampleCount: Int) {
        var color = GPUColorTarget(format: pixelFormat)
        color.blend = (color: GPUBlendComponent(source: .sourceAlpha, destination: .oneMinusSourceAlpha),
                       alpha: GPUBlendComponent(source: .one, destination: .oneMinusSourceAlpha))

        func makeState(vertex: String, fragment: String, surface: Surface) -> any GPURenderPipeline {
            // Function constant 0 picks the surface, in both functions.
            let constants: [Int: GPUConstantValue] = [0: .int32(Int32(surface.rawValue))]
            var descriptor = GPURenderPipelineDescriptor(vertexFunction: GPUShaderFunction(name: vertex, constants: constants),
                                                         fragmentFunction: GPUShaderFunction(name: fragment, constants: constants),
                                                         colorTargets: [color])
            descriptor.label = "\(vertex) \(surface)"
            descriptor.depthStencilFormat = .depth32FloatStencil8
            descriptor.sampleCount = sampleCount
            do {
                return try device.makeRenderPipeline(descriptor)
            } catch {
                fatalError("Failed to create the layer pipeline: \(error)")
            }
        }
        var states: [Surface: States] = [:]
        for surface in Surface.allCases {
            states[surface] = States(fill: makeState(vertex: "layerFillVertex", fragment: "layerFillFragment", surface: surface),
                                     line: makeState(vertex: "layerLineVertex", fragment: "layerLineFragment", surface: surface),
                                     point: makeState(vertex: "layerPointVertex", fragment: "layerPointFragment", surface: surface))
        }
        statesBySurface = states

        func makeDepthState(testsDepth: Bool) -> any GPUDepthStencilState {
            var stencil = GPUStencilFaceState()
            stencil.compare = .equal
            stencil.stencilFailure = .keep
            stencil.depthFailure = .keep
            stencil.pass = .keep
            stencil.readMask = TileSourceStencilPriority.surfaceMaskBit
            stencil.writeMask = 0
            var descriptor = GPUDepthStencilDescriptor()
            descriptor.depthCompare = testsDepth ? .less : .always
            descriptor.depthWriteEnabled = false
            descriptor.frontStencil = stencil
            descriptor.backStencil = stencil
            guard let state = device.makeDepthStencilState(descriptor) else {
                fatalError("Failed to create the layer depth state")
            }
            return state
        }
        overGroundState = makeDepthState(testsDepth: false)
        behindTerrainState = makeDepthState(testsDepth: true)
    }

    func states(for surface: Surface) -> States {
        statesBySurface[surface]!
    }
}

/// Mirrors `LayerDraw` in Layers.metal: one chunk's draw state.
struct LayerDrawUniform {
    var modelMatrix: matrix_float4x4
    var uvOrigin: SIMD2<Float>
    var uvScale: Float
    var referenceWorldX: Float
    var viewportSizePx: SIMD2<Float>
    var pixelsPerPoint: Float
    var depth: Float
}

/// Where the layers sit in the ground's far-plane depth band: a step
/// behind the labels painted on the map (`SurfaceLabelDepth`), which draw
/// over them, and nearer than the ground and the roads, so a layer lies
/// over those and every building and model stays in front of it.
enum LayerDepth {
    static let depth: Float = 1 - GlobeSurfaceDepthRank.appLayersRank * GlobeSurfaceDepthRank.layerDepthStep
}
