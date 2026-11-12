// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PortableFoundation

struct TileCoverageZoomPlan: Equatable {
    let baseZoom: Int
}

enum TileCoverageZoomPolicy {
    static func resolve(cameraZoom: Double,
                        renderSurfaceMode: ViewMode,
                        maximumZoomLevel: Int) -> TileCoverageZoomPlan {
        let baseZoom = min(max(0, Int(cameraZoom)), maximumZoomLevel)
        return TileCoverageZoomPlan(baseZoom: baseZoom)
    }
}
