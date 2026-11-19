// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

class TilePipeline {
    /// Which surface the pipeline draws tiles onto. The flat one projects
    /// through a model matrix into the plane (Tile.metal); the sphere one
    /// projects tile-local positions onto the globe through the surface
    /// morph (TileSphere.metal). Same vertex format, styles and blending.
    enum Surface {
        case flat
        case sphere
    }

    let pipelineState: any GPURenderPipeline
    /// Flat surface only: the fills classes without the line fields (no
    /// export, no interpolation, no coverage math), blended for the
    /// translucent layers and unblended for the opaque depth pass.
    /// `pipelineState` remains the line-fields variant (ribbons, road
    /// buckets, bridge overlay).
    let flatFillsPipelineState: (any GPURenderPipeline)?
    let flatOpaquePipelineState: (any GPURenderPipeline)?
    /// Flat surface only: every flat variant again with the ground relief
    /// (Tile.metal, kTileGroundRelief), the vertex raised by the terrain
    /// read at vertex texture 0 with its uniform at vertex buffer 9, for
    /// the tiles whose terrain is in. Keyed by the class the plain variant
    /// draws.
    let flatReliefPipelineStates: [FlatClass: any GPURenderPipeline]

    /// The flat classes, each with its plain pipeline state and its relief
    /// one.
    enum FlatClass: Hashable {
        /// The line-fields pipeline (ribbons, road buckets, bridge overlay).
        case lines
        case fills
        case opaqueFills
        case roadOpaque
        case roadBlended
    }
    /// Flat surface only: the road ribbons (Tile.metal, kTileRoadRibbons),
    /// whose geometry is the road and whose depth is the road's rank. The
    /// opaque ones draw unblended, the rest blend.
    let flatRoadOpaquePipelineState: (any GPURenderPipeline)?
    let flatRoadBlendedPipelineState: (any GPURenderPipeline)?
    /// Sphere surface only: the resting-sphere fills class, blended (the
    /// translucent fill layers). Carries no line fields. The morph keeps
    /// `pipelineState` (tileSphereMorphVertexShader), the only sphere
    /// variant with the unroll and the fog.
    let sphereFillsPipelineState: (any GPURenderPipeline)?
    /// The fills class with blending disabled: what the opaque ground
    /// layers draw with, front-to-back under the depth test.
    let sphereOpaqueFillsPipelineState: (any GPURenderPipeline)?
    /// The resting-sphere ribbons class: the line ribbons of the ground
    /// bucket through the line-field coverage, blended, in the phases of
    /// `SphereRibbonPhase` (TileSphere.metal, kTileSphereRibbonPhase).
    let sphereRibbonsPipelineState: (any GPURenderPipeline)?
    let sphereRibbonCorePipelineState: (any GPURenderPipeline)?
    let sphereRibbonFeatherPipelineState: (any GPURenderPipeline)?
    /// The morph's class variants: the same layered passes as the resting
    /// sphere (the unroll never self-intersects toward the camera, so the
    /// rank depth band applies unchanged), with the unroll and the fog.
    let sphereMorphFillsPipelineState: (any GPURenderPipeline)?
    let sphereMorphOpaqueFillsPipelineState: (any GPURenderPipeline)?
    let sphereMorphRibbonsPipelineState: (any GPURenderPipeline)?
    let sphereMorphRibbonCorePipelineState: (any GPURenderPipeline)?
    let sphereMorphRibbonFeatherPipelineState: (any GPURenderPipeline)?

    /// Which part of a ribbon a sphere ribbons draw paints
    /// (kTileSphereRibbonPhase in TileSphere.metal): the whole ribbon in
    /// one blended draw, the core alone (the fragments the line covers by
    /// half or more, which write the rank depth) or the feather alone (the
    /// rest, blended after the cores).
    enum SphereRibbonPhase: Int32 {
        case whole = 0
        case core = 1
        case feather = 2
    }

    /// - Parameter readsGroundShadowMask: the flat world pass reads the
    ///   per-pixel ground shadow mask at fragment texture 1; the globe atlas
    ///   bake keeps the direct cascade sampling path (with a disabled uniform)
    ///   and only binds the shadow map slot.
    init(device: any GPUDevice,
         pixelFormat: GPUPixelFormat,
         sampleCount: Int = 1,
         readsGroundShadowMask: Bool = false,
         surface: Surface = .flat) {
        // Every variant reads the tile vertex at buffer 0, writes the world
        // pass's colour, depth and stencil, and blends by the source alpha
        // unless it is opaque. Alpha blends with .one so coverage
        // accumulates on a transparent destination; over an opaque one the
        // result is unchanged.
        func make(_ label: String, vertex: GPUShaderFunction, fragment: GPUShaderFunction, blended: Bool) -> any GPURenderPipeline {
            var color = GPUColorTarget(format: pixelFormat)
            if blended {
                color.blend = (color: GPUBlendComponent(source: .sourceAlpha, destination: .oneMinusSourceAlpha),
                               alpha: GPUBlendComponent(source: .one, destination: .oneMinusSourceAlpha))
            }
            var descriptor = GPURenderPipelineDescriptor(vertexFunction: vertex, fragmentFunction: fragment, colorTargets: [color])
            descriptor.label = label
            descriptor.vertexLayout = TileVertexIn.gpuVertexLayout
            descriptor.depthStencilFormat = .depth32FloatStencil8
            descriptor.sampleCount = sampleCount
            do {
                return try device.makeRenderPipeline(descriptor)
            } catch {
                fatalError("Failed to create the tile pipeline \(label): \(error)")
            }
        }

        switch surface {
        case .flat:
            func flat(_ name: String,
                      lineFields: Bool,
                      roadRibbons: Bool = false,
                      roadBlended: Bool = false,
                      groundRelief: Bool = false) -> GPUShaderFunction {
                // The mask is the plane's shadow: the relief's variants
                // sample the cascades at their raised points instead
                // (`GroundShadowMaskBinding`).
                GPUShaderFunction(name: name, constants: [0: .bool(readsGroundShadowMask && groundRelief == false),
                                                          1: .bool(lineFields),
                                                          4: .bool(roadRibbons),
                                                          5: .bool(roadBlended),
                                                          6: .bool(groundRelief)])
            }
            pipelineState = make("TileLines",
                                 vertex: flat("tileVertexShader", lineFields: true),
                                 fragment: flat("tileFragmentShader", lineFields: true),
                                 blended: true)
            let fillsVertex = flat("tileVertexShader", lineFields: false)
            let fillsFragment = flat("tileFragmentShader", lineFields: false)
            flatFillsPipelineState = make("TileFills", vertex: fillsVertex, fragment: fillsFragment, blended: true)
            flatOpaquePipelineState = make("TileOpaqueFills", vertex: fillsVertex, fragment: fillsFragment, blended: false)
            // The relief variants: each class's fragment function and
            // blending with the relief's vertex function.
            let reliefFills = (vertex: flat("tileVertexShader", lineFields: false, groundRelief: true),
                               fragment: flat("tileFragmentShader", lineFields: false, groundRelief: true))
            flatReliefPipelineStates = [
                .lines: make("TileReliefLines",
                             vertex: flat("tileVertexShader", lineFields: true, groundRelief: true),
                             fragment: flat("tileFragmentShader", lineFields: true, groundRelief: true),
                             blended: true),
                .fills: make("TileReliefFills", vertex: reliefFills.vertex, fragment: reliefFills.fragment, blended: true),
                .opaqueFills: make("TileReliefOpaqueFills", vertex: reliefFills.vertex, fragment: reliefFills.fragment, blended: false),
                .roadOpaque: make("TileReliefRoadOpaque",
                                  vertex: flat("tileVertexShader", lineFields: true, roadRibbons: true, groundRelief: true),
                                  fragment: flat("tileRoadFragmentShader", lineFields: true, roadRibbons: true, groundRelief: true),
                                  blended: false),
                .roadBlended: make("TileReliefRoadBlended",
                                   vertex: flat("tileVertexShader", lineFields: true, roadRibbons: true, roadBlended: true,
                                                groundRelief: true),
                                   fragment: flat("tileRoadFragmentShader", lineFields: true, roadRibbons: true, roadBlended: true,
                                                  groundRelief: true),
                                   blended: true),
            ]
            // The road ribbons: the blended pair, and the opaque pair with
            // blending off.
            flatRoadBlendedPipelineState = make("TileRoadBlended",
                                                vertex: flat("tileVertexShader", lineFields: true, roadRibbons: true, roadBlended: true),
                                                fragment: flat("tileRoadFragmentShader", lineFields: true, roadRibbons: true,
                                                               roadBlended: true),
                                                blended: true)
            flatRoadOpaquePipelineState = make("TileRoadOpaque",
                                               vertex: flat("tileVertexShader", lineFields: true, roadRibbons: true),
                                               fragment: flat("tileRoadFragmentShader", lineFields: true, roadRibbons: true),
                                               blended: false)
            sphereFillsPipelineState = nil
            sphereOpaqueFillsPipelineState = nil
            sphereRibbonsPipelineState = nil
            sphereRibbonCorePipelineState = nil
            sphereRibbonFeatherPipelineState = nil
            sphereMorphFillsPipelineState = nil
            sphereMorphOpaqueFillsPipelineState = nil
            sphereMorphRibbonsPipelineState = nil
            sphereMorphRibbonCorePipelineState = nil
            sphereMorphRibbonFeatherPipelineState = nil
        case .sphere:
            func sphere(_ name: String, fog: Bool, lineFields: Bool, ribbonPhase: SphereRibbonPhase = .whole) -> GPUShaderFunction {
                GPUShaderFunction(name: name, constants: [0: .bool(fog),
                                                          1: .bool(lineFields),
                                                          2: .int32(ribbonPhase.rawValue)])
            }
            // The morph: the sphere variants with the unroll and the fog.
            pipelineState = make("TileSphereMorph",
                                 vertex: sphere("tileSphereMorphVertexShader", fog: true, lineFields: true),
                                 fragment: sphere("tileSphereFragmentShader", fog: true, lineFields: true),
                                 blended: true)
            // The class variants: the fills class carries no line fields
            // at all, the ribbons class the analytic line coverage, in its
            // phases. The morph's add the fog.
            func classStates(_ prefix: String, vertex: String, fog: Bool)
                -> (fills: any GPURenderPipeline, opaqueFills: any GPURenderPipeline, ribbons: any GPURenderPipeline,
                    ribbonCore: any GPURenderPipeline, ribbonFeather: any GPURenderPipeline) {
                let fillsVertex = sphere(vertex, fog: fog, lineFields: false)
                let fillsFragment = sphere("tileSphereFragmentShader", fog: fog, lineFields: false)
                let ribbonsVertex = sphere(vertex, fog: fog, lineFields: true)
                return (fills: make("\(prefix)Fills", vertex: fillsVertex, fragment: fillsFragment, blended: true),
                        opaqueFills: make("\(prefix)OpaqueFills", vertex: fillsVertex, fragment: fillsFragment, blended: false),
                        ribbons: make("\(prefix)Ribbons", vertex: ribbonsVertex,
                                      fragment: sphere("tileSphereFragmentShader", fog: fog, lineFields: true), blended: true),
                        ribbonCore: make("\(prefix)RibbonCore", vertex: ribbonsVertex,
                                         fragment: sphere("tileSphereFragmentShader", fog: fog, lineFields: true, ribbonPhase: .core),
                                         blended: true),
                        ribbonFeather: make("\(prefix)RibbonFeather", vertex: ribbonsVertex,
                                            fragment: sphere("tileSphereFragmentShader", fog: fog, lineFields: true,
                                                             ribbonPhase: .feather),
                                            blended: true))
            }
            let pure = classStates("TileSphere", vertex: "tileSpherePureVertexShader", fog: false)
            sphereFillsPipelineState = pure.fills
            sphereOpaqueFillsPipelineState = pure.opaqueFills
            sphereRibbonsPipelineState = pure.ribbons
            sphereRibbonCorePipelineState = pure.ribbonCore
            sphereRibbonFeatherPipelineState = pure.ribbonFeather
            let morph = classStates("TileSphereMorph", vertex: "tileSphereMorphVertexShader", fog: true)
            sphereMorphFillsPipelineState = morph.fills
            sphereMorphOpaqueFillsPipelineState = morph.opaqueFills
            sphereMorphRibbonsPipelineState = morph.ribbons
            sphereMorphRibbonCorePipelineState = morph.ribbonCore
            sphereMorphRibbonFeatherPipelineState = morph.ribbonFeather
            flatFillsPipelineState = nil
            flatOpaquePipelineState = nil
            flatReliefPipelineStates = [:]
            flatRoadOpaquePipelineState = nil
            flatRoadBlendedPipelineState = nil
        }
    }

    // MARK: - The pipeline for a draw

    /// The flat line-fields pipeline (ribbons, road buckets, bridge
    /// overlay), and the combined morph pipeline on the sphere.
    var linesPipeline: any GPURenderPipeline { pipelineState }

    /// The road ribbons' pipeline, opaque or blended. Nil when the pipeline
    /// has none (a sphere pipeline), and the caller draws the roads as
    /// plain ribbons.
    func flatRoadPipeline(blended: Bool) -> (any GPURenderPipeline)? {
        blended ? flatRoadBlendedPipelineState : flatRoadOpaquePipelineState
    }

    /// The flat translucent fills variant (no line fields), the line-fields
    /// pipeline when absent.
    var flatFillsPipeline: any GPURenderPipeline { flatFillsPipelineState ?? pipelineState }

    /// The flat opaque ground variant (no line fields, blending off), the
    /// blended pipeline when absent.
    var flatOpaquePipeline: any GPURenderPipeline { flatOpaquePipelineState ?? pipelineState }

    /// A flat class raised by its terrain. Nil when the pipeline has no
    /// relief variants (a sphere pipeline), and the caller draws flat.
    func flatReliefPipeline(_ flatClass: FlatClass) -> (any GPURenderPipeline)? {
        flatReliefPipelineStates[flatClass]
    }

    /// The opaque fills variant (blending off) for the layered ground, the
    /// blended fills variant when absent.
    func sphereOpaqueFillsPipeline(morph: Bool) -> any GPURenderPipeline {
        (morph ? sphereMorphOpaqueFillsPipelineState : sphereOpaqueFillsPipelineState)
            ?? sphereClassPipeline(linesClass: false, morph: morph)
    }

    /// The sphere variant for one ground class, on the resting sphere or the
    /// morph, the combined morph pipeline on a surface that has no variants.
    func sphereClassPipeline(linesClass: Bool, morph: Bool, ribbonPhase: SphereRibbonPhase = .whole) -> any GPURenderPipeline {
        let state: (any GPURenderPipeline)?
        if morph {
            switch (linesClass, ribbonPhase) {
            case (false, _): state = sphereMorphFillsPipelineState
            case (true, .whole): state = sphereMorphRibbonsPipelineState
            case (true, .core): state = sphereMorphRibbonCorePipelineState
            case (true, .feather): state = sphereMorphRibbonFeatherPipelineState
            }
        } else {
            switch (linesClass, ribbonPhase) {
            case (false, _): state = sphereFillsPipelineState
            case (true, .whole): state = sphereRibbonsPipelineState
            case (true, .core): state = sphereRibbonCorePipelineState
            case (true, .feather): state = sphereRibbonFeatherPipelineState
            }
        }
        return state ?? pipelineState
    }

    // MARK: - Selecting it on the GPU encoder

    func selectPipeline(renderEncoder: any GPURenderEncoder) {
        renderEncoder.setPipeline(pipelineState)
    }

    func selectFlatLinesPipeline(renderEncoder: any GPURenderEncoder) {
        renderEncoder.setPipeline(linesPipeline)
    }

    @discardableResult
    func selectFlatRoadPipeline(renderEncoder: any GPURenderEncoder, blended: Bool) -> Bool {
        guard let state = flatRoadPipeline(blended: blended) else { return false }
        renderEncoder.setPipeline(state)
        return true
    }

    func selectFlatFillsPipeline(renderEncoder: any GPURenderEncoder) {
        renderEncoder.setPipeline(flatFillsPipeline)
    }

    func selectFlatOpaquePipeline(renderEncoder: any GPURenderEncoder) {
        renderEncoder.setPipeline(flatOpaquePipeline)
    }

    @discardableResult
    func selectFlatReliefPipeline(_ flatClass: FlatClass, renderEncoder: any GPURenderEncoder) -> Bool {
        guard let state = flatReliefPipeline(flatClass) else { return false }
        renderEncoder.setPipeline(state)
        return true
    }

    func selectSphereOpaqueFillsPipeline(renderEncoder: any GPURenderEncoder, morph: Bool) {
        renderEncoder.setPipeline(sphereOpaqueFillsPipeline(morph: morph))
    }

    func selectSphereClassPipeline(renderEncoder: any GPURenderEncoder,
                                   linesClass: Bool,
                                   morph: Bool,
                                   ribbonPhase: SphereRibbonPhase = .whole) {
        renderEncoder.setPipeline(sphereClassPipeline(linesClass: linesClass, morph: morph, ribbonPhase: ribbonPhase))
    }
}
