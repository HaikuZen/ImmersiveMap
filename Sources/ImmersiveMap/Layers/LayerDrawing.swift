// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import simd

/// The layers' draws of a frame, apart from the subsystem that binds the
/// frame's shared values first (`LayerRenderSubsystem`), so the drawing
/// builds and is tested everywhere.
enum LayerDrawing {
    /// A layer's mesh and whether the terrain hides it.
    typealias DrawnLayer = (mesh: LayerMesh, hidesBehindTerrain: Bool)

    /// Draws the layers once the frame's shared values are bound (the
    /// camera, the globe, the light and the fog): each layer's zones, then
    /// its lines, then its joins and points, every chunk once per draw
    /// state `placements` gives it. Leaves the encoder in its neutral
    /// state. Internal so tests can record what a frame draws.
    static func drawLayers(_ drawn: [DrawnLayer],
                           pipeline: LayerPipeline,
                           surface: LayerPipeline.Surface,
                           placements: (LayerMeshChunk) -> [LayerDrawUniform],
                           depthDisabledState: any GPUDepthStencilState,
                           encoder: any GPURenderEncoder) {
        encoder.setStencilReference(0)
        // A zone's triangles are counter-clockwise in render space, as the
        // ground's: culling the back faces removes the far side of the
        // planet. A line's and a point's quads are cut there instead.
        encoder.setFrontFacing(.counterClockwise)

        let states = pipeline.states(for: surface)
        for (mesh, hidesBehindTerrain) in drawn {
            // Each chunk with its draws of this frame, none for a chunk
            // outside the view.
            let chunks = mesh.chunks.compactMap { chunk -> (chunk: LayerMeshChunk, draws: [LayerDrawUniform])? in
                let draws = placements(chunk)
                return draws.isEmpty ? nil : (chunk, draws)
            }
            guard chunks.isEmpty == false else { continue }
            encoder.setDepthStencilState(hidesBehindTerrain ? pipeline.behindTerrainState : pipeline.overGroundState)
            if let vertices = mesh.fillVertices, let indices = mesh.fillIndices {
                encoder.setCullMode(.back)
                encoder.setPipeline(states.fill)
                encoder.setVertexBuffer(vertices, offset: 0, index: 0)
                for (chunk, draws) in chunks where chunk.fillIndexCount > 0 {
                    for draw in draws {
                        encoder.setVertexValue(draw, index: 2)
                        encoder.drawIndexed(.triangle,
                                            indexCount: chunk.fillIndexCount,
                                            indexType: .uint32,
                                            indexBuffer: indices,
                                            indexBufferOffset: chunk.fillIndexStart * MemoryLayout<UInt32>.stride)
                    }
                }
            }
            encoder.setCullMode(.none)
            if let vertices = mesh.lineVertices, let indices = mesh.lineIndices {
                encoder.setPipeline(states.line)
                encoder.setVertexBuffer(vertices, offset: 0, index: 0)
                for (chunk, draws) in chunks where chunk.lineIndexCount > 0 {
                    for draw in draws {
                        encoder.setVertexValue(draw, index: 2)
                        encoder.drawIndexed(.triangle,
                                            indexCount: chunk.lineIndexCount,
                                            indexType: .uint32,
                                            indexBuffer: indices,
                                            indexBufferOffset: chunk.lineIndexStart * MemoryLayout<UInt32>.stride)
                    }
                }
            }
            if let discs = mesh.discs {
                encoder.setPipeline(states.point)
                encoder.setVertexBuffer(discs, offset: 0, index: 0)
                // The lines' joins with the lines, then the points over them.
                for pass in 0 ..< 2 {
                    for (chunk, draws) in chunks {
                        let start = pass == 0 ? chunk.joinStart : chunk.pointStart
                        let count = pass == 0 ? chunk.joinCount : chunk.pointCount
                        guard count > 0 else { continue }
                        for draw in draws {
                            encoder.setVertexValue(draw, index: 2)
                            encoder.draw(.triangle,
                                         vertexStart: 0,
                                         vertexCount: 6,
                                         instanceCount: count,
                                         baseInstance: start)
                        }
                    }
                }
            }
        }

        encoder.setCullMode(.none)
        encoder.setFrontFacing(.clockwise)
        encoder.setDepthStencilState(depthDisabledState)
    }
}
