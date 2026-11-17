// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapMetal
import Metal
import QuartzCore

extension RenderHost {
    /// Apple's host for a view's layer: the process-wide shared resources,
    /// stamped onto the layer with the view's own command queue
    /// (`RendererSetup.buildMetal`), the IO queue's file loaders, Model I/O
    /// for the scene models' assets, the POI icons drawn with the system's
    /// symbols, and the avatars.
    @MainActor
    static func metal(layer: CAMetalLayer,
                      shared: SharedRenderResources,
                      avatarSource: AvatarRenderSource,
                      config: ImmersiveMapSettings) -> RenderHost {
        let metal = RendererSetup.buildMetal(layer: layer, sharedResources: shared)
        // Metal's device is safe to use from any thread, the loads' queue
        // included.
        nonisolated(unsafe) let device = metal.device
        let avatarsRenderer = AvatarsRenderer(metalDevice: metal.device,
                                              sharedResources: shared.avatars,
                                              config: config.avatars)
        let depthDisabledState = shared.depthDisabledState.metalState
        return RenderHost(resources: shared.core,
                          commandQueue: MetalCommandQueue(metal.commandQueue),
                          poiSpriteTexture: shared.poiSpriteAtlas.texture,
                          tileFileGeometry: .metal(device: metal.device,
                                                   compressionEnabled: config.tiles.cache.preparedDiskCompressionEnabled),
                          modelTileFileLoader: ModelTileMesh.metalFileLoader(device: metal.device),
                          treeFileLoader: TreeModelMesh.metalFileLoader(device: metal.device),
                          loadSceneModelAsset: { url in try SceneModelAssetLoader.load(url: url, device: device) },
                          makeAvatarSubsystem: {
                              AvatarRenderSubsystem(avatarsRenderer: avatarsRenderer,
                                                    avatarSource: avatarSource,
                                                    depthDisabledState: depthDisabledState)
                          })
    }
}
