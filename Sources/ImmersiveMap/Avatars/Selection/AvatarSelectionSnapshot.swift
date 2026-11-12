// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PortableFoundation

// What a tap is tested against: the avatars' screen boxes of the last
// frame. Plain values apart from the projector, so the render core that
// carries them builds where the avatars do not yet
// (PortableEngineExclusions.txt).

enum AvatarSelectionTarget: Equatable {
    case marker(UInt64)
}

struct AvatarSelectionEntry {
    let target: AvatarSelectionTarget
    let bounds: CGRect
    let anchorPoint: CGPoint
    let drawOrder: Int

    init(markerID: UInt64,
         bounds: CGRect,
         anchorPoint: CGPoint,
         drawOrder: Int) {
        self.target = .marker(markerID)
        self.bounds = bounds
        self.anchorPoint = anchorPoint
        self.drawOrder = drawOrder
    }

    init(target: AvatarSelectionTarget,
         bounds: CGRect,
         anchorPoint: CGPoint,
         drawOrder: Int) {
        self.target = target
        self.bounds = bounds
        self.anchorPoint = anchorPoint
        self.drawOrder = drawOrder
    }

    var markerID: UInt64? {
        if case .marker(let id) = target {
            return id
        }
        return nil
    }
}

struct AvatarSelectionSnapshot {
    static let empty = AvatarSelectionSnapshot(frameIndex: 0,
                                               drawSize: .zero,
                                               entries: [])

    let frameIndex: UInt64
    let drawSize: CGSize
    let entries: [AvatarSelectionEntry]

    func withFrameIndex(_ frameIndex: UInt64) -> AvatarSelectionSnapshot {
        AvatarSelectionSnapshot(frameIndex: frameIndex,
                                drawSize: drawSize,
                                entries: entries)
    }

    func hitTest(point: CGPoint) -> AvatarSelectionTarget? {
        for entry in entries.reversed() where entry.bounds.contains(point) {
            return entry.target
        }
        return nil
    }
}
