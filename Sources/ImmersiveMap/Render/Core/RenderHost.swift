// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import PortableFoundation

/// What a platform hands the render core (`RenderPersistentContext`): the
/// engine's resources on its device, the queue the frames go on, and what
/// only the platform can make. Apple's host builds it from the view's layer
/// (`RenderHost.metal`); another platform passes nil where it has nothing.
struct RenderHost {
    /// The engine's resources on the platform's device.
    let resources: RenderResources
    /// The queue every frame's command buffer comes from.
    let commandQueue: any GPUCommandQueue
    /// The POI icons' atlas texture (`PoiSpriteAtlas`, drawn with Apple's
    /// symbols).
    let poiSpriteTexture: any GPUTexture
    /// Tile geometry kept in files and loaded straight into GPU memory, nil
    /// where the tiles are cached inline.
    let tileFileGeometry: TileFileGeometry?
    /// The model tiles' and the trees' loads of a cached file straight into
    /// GPU memory, nil where they are copied from memory.
    let modelTileFileLoader: ModelTileMesh.FileLoader?
    let treeFileLoader: TreeModelMesh.FileLoader?
    /// Loads a layer's mesh from its file on disk straight into its buffers
    /// (`LayerMesh.FileLoader`), nil where the platform has no such path.
    let layerFileLoader: LayerMesh.FileLoader?
    /// Reads a scene model's asset file into a mesh, throwing where the
    /// platform reads none.
    let loadSceneModelAsset: @Sendable (URL) throws -> SceneModelMesh
    /// The subsystem the platform draws its own layer with (the pins, on
    /// Apple's platforms), placed in the pins' slot of the graph, nil for
    /// none.
    let makePinSubsystem: (() -> any RenderSubsystem & RenderPassAvailabilityProvider)?
}
