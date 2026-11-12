// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The single per-frame decision "does the shadow pass run": the resolved
/// shadow state must exist AND at least one caster must be present. Called
/// identically by `RenderPassGraph.plan` (pass injection) and by the receiver
/// bind sites, so the pass and the samplers can never disagree within a frame
/// (the same trick as `RenderLayerPlanner`). Both call after
/// subsystem updates, when `sharedState` is final for the frame.
enum ShadowPassGateResolver {
    /// The buildings cast only where they draw
    /// (`FrameContextSharedState.drawnBuildingPlacements`): planned but off
    /// the buildings' zoom, or waiting for a model tile, they cast nothing.
    /// The mountains cast wherever the relief stands
    /// (`GroundReliefFrame.castsShadows`), with no building in sight.
    static func resolve(frameContext: FrameContext) -> ShadowFrameState? {
        resolve(shadowFrameState: frameContext.shadowFrameState,
                hasBuildingCasters: frameContext.sharedState.drawnBuildingPlacements.isEmpty == false,
                hasModelCasters: frameContext.sharedState.sceneModelState.hasShadowCasters,
                hasTerrainCasters: frameContext.services.groundRelief?.castsShadows ?? false)
    }

    static func resolve(shadowFrameState: ShadowFrameState?,
                        hasBuildingCasters: Bool,
                        hasModelCasters: Bool,
                        hasTerrainCasters: Bool = false) -> ShadowFrameState? {
        guard let shadowFrameState, hasBuildingCasters || hasModelCasters || hasTerrainCasters else {
            return nil
        }
        return shadowFrameState
    }

}
