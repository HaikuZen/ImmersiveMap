// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import QuartzCore

protocol RenderPassDescriptorProvider: AnyObject {
    func makeRenderPassDescriptor(frameContext: FrameContext,
                                  attachments: FrameAttachmentStore,
                                  target: FrameRenderTarget?) -> MTLRenderPassDescriptor?
}

struct RenderPassNode {
    let name: RenderPassName
    let descriptorProvider: any RenderPassDescriptorProvider
    let layers: [RenderLayer]
}
