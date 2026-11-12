// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import PortableFoundation
import simd

/// The `Text` folder: text atlas decoding, glyph metrics, label text layout
/// (measure, wrap, align), the vertex data shared with the renderer, and this
/// renderer, which builds the text pipeline and the glyph-atlas textures. Text
/// data and geometry only: no schema-specific name or language rules, no
/// runtime label caches, collision state or fade policy, no tile loading.
/// The text shader sits beside it in `Text/Shaders`.
final class TextRenderer {
    /// The layout half: atlas metrics and every measure, wrap and vertex
    /// build (`TextLayout`). The renderer adds the atlas textures and the
    /// pipelines.
    let layout: TextLayout
    /// The bold and the thin atlas. The thin one is the bold one when the
    /// thin atlas is missing, and the bold one a blank texel when it is.
    let texture: any GPUTexture
    let thinTexture: any GPUTexture
    let pipelineState: any GPURenderPipeline
    let labelPipelineState: any GPURenderPipeline
    let roadLabelPipelineState: any GPURenderPipeline
    let poiIconPipelineState: any GPURenderPipeline
    /// The route sign plates: the POI quad's vertex stage and the plate's
    /// distance field (RouteShield.metal).
    let routeShieldPipelineState: any GPURenderPipeline

    /// `resource` finds a file of the engine's resources by name and
    /// extension: the bundle on Apple's platforms
    /// (`ImmersiveMapResourceBundle`), the resources folder elsewhere.
    init(device: any GPUDevice,
         resource: (_ name: String, _ extension: String) -> URL?,
         sampleCount: Int = 1) {
        // The JSON first: it carries the dimensions the raw pixel file has
        // no header for.
        layout = TextLayout(resource: resource)
        let bold = Self.loadAtlasTexture(device: device, url: resource(TextLayout.boldAtlasName, "bgra"),
                                         name: TextLayout.boldAtlasName, atlas: layout.atlasData.atlas)
            ?? Self.makeFallbackTexture(device: device)
        texture = bold
        thinTexture = Self.loadAtlasTexture(device: device, url: resource(TextLayout.thinAtlasName, "bgra"),
                                            name: TextLayout.thinAtlasName, atlas: layout.thinAtlasData.atlas)
            ?? bold

        // Mirrors TextVertex: a float4 position and a float2 uv.
        var textLayout = GPUVertexLayout()
        textLayout.attributes[0] = GPUVertexAttribute(format: .float4, offset: 0, bufferIndex: 0)
        textLayout.attributes[1] = GPUVertexAttribute(format: .float2, offset: MemoryLayout<SIMD4<Float>>.stride, bufferIndex: 0)
        textLayout.strides[0] = MemoryLayout<TextVertex>.stride
        // Mirrors LabelVertex.
        var labelLayout = GPUVertexLayout()
        labelLayout.attributes[0] = GPUVertexAttribute(format: .float2,
                                                       offset: MemoryLayout<LabelVertex>.offset(of: \LabelVertex.position) ?? 0,
                                                       bufferIndex: 0)
        labelLayout.attributes[1] = GPUVertexAttribute(format: .float2,
                                                       offset: MemoryLayout<LabelVertex>.offset(of: \LabelVertex.uv) ?? 0,
                                                       bufferIndex: 0)
        labelLayout.attributes[2] = GPUVertexAttribute(format: .int,
                                                       offset: MemoryLayout<LabelVertex>.offset(of: \LabelVertex.labelIndex) ?? 0,
                                                       bufferIndex: 0)
        labelLayout.attributes[3] = GPUVertexAttribute(format: .float2,
                                                       offset: MemoryLayout<LabelVertex>.offset(of: \LabelVertex.spriteUV) ?? 0,
                                                       bufferIndex: 0)
        labelLayout.strides[0] = MemoryLayout<LabelVertex>.stride

        func makePipeline(_ vertex: String, _ fragment: String, _ layout: GPUVertexLayout) -> any GPURenderPipeline {
            var color = GPUColorTarget(format: .bgra8Unorm)
            // Alpha blends with .one so glyph coverage accumulates on a transparent
            // destination; over an opaque one the result is unchanged.
            color.blend = (color: GPUBlendComponent(source: .sourceAlpha, destination: .oneMinusSourceAlpha),
                           alpha: GPUBlendComponent(source: .one, destination: .oneMinusSourceAlpha))
            var descriptor = GPURenderPipelineDescriptor(vertexFunction: GPUShaderFunction(name: vertex),
                                                         fragmentFunction: GPUShaderFunction(name: fragment),
                                                         colorTargets: [color])
            descriptor.label = vertex
            descriptor.vertexLayout = layout
            descriptor.depthStencilFormat = .depth32FloatStencil8
            descriptor.sampleCount = sampleCount
            do {
                return try device.makeRenderPipeline(descriptor)
            } catch {
                fatalError("Pipeline creation failed: \(error)")
            }
        }
        pipelineState = makePipeline("textVertex", "textFragment", textLayout)
        labelPipelineState = makePipeline("labelTextVertex", "textFragment", labelLayout)
        roadLabelPipelineState = makePipeline("roadLabelTextVertex", "roadTextFragment", labelLayout)
        poiIconPipelineState = makePipeline("poiSpriteVertex", "poiSpriteFragment", labelLayout)
        routeShieldPipelineState = makePipeline("poiSpriteVertex", "routeShieldFragment", labelLayout)
    }

    // The layout, for the callers that reach it through the renderer.

    var atlasData: AtlasData { layout.atlasData }
    var thinAtlasData: AtlasData { layout.thinAtlasData }
    var preparedTileTextRevision: UInt32 { layout.preparedTileTextRevision }
    var glyphCoverage: VectorTileLabelGlyphCoverage { layout.glyphCoverage }

    func atlasEmTexels(for weight: LabelFontWeight) -> CGFloat {
        layout.atlasEmTexels(for: weight)
    }

    func collectMultiTextVertices(for entries: [TextEntry]) -> [TextVertex] {
        layout.collectMultiTextVertices(for: entries)
    }

    func collectMultiTextVertices(into vertices: inout [TextVertex], for entries: [TextEntry]) {
        layout.collectMultiTextVertices(into: &vertices, for: entries)
    }

    func collectLabelVertices(for text: String,
                              labelIndex: simd_int1,
                              scale: Float,
                              wrap: LabelWrapOptions? = nil,
                              normalizeY: Bool = true,
                              weight: LabelFontWeight = .bold,
                              letterSpacing: Float = 0) -> TextMetrics {
        layout.collectLabelVertices(for: text,
                                    labelIndex: labelIndex,
                                    scale: scale,
                                    wrap: wrap,
                                    normalizeY: normalizeY,
                                    weight: weight,
                                    letterSpacing: letterSpacing)
    }

    func collectTextVertices(for text: String, at position: SIMD2<Float>, scale: Float = 1.0) -> [TextVertex] {
        layout.collectTextVertices(for: text, at: position, scale: scale)
    }

    private static func makeFallbackTexture(device: any GPUDevice) -> any GPUTexture {
        guard let texture = device.makeTexture(GPUTextureDescriptor(format: .bgra8Unorm, width: 1, height: 1)) else {
            fatalError("Failed to create the fallback text atlas texture")
        }
        return texture
    }

    /// The atlas pixels ship raw (`<name>.bgra`: BGRA8, the byte order of
    /// `bgra8Unorm`, row major, top row first, `width * height * 4` bytes,
    /// no header), the bytes the image decoder used to produce, written
    /// once by `Tools/TextAtlas/png_to_rgba.swift`. Loading is then a copy into a
    /// staging buffer and a blit into the private texture: no PNG inflate
    /// and unfilter, which was the largest single item of the engine's
    /// creation on the main thread.
    private static func loadAtlasTexture(device: any GPUDevice, url: URL?, name: String, atlas: AtlasInfo) -> (any GPUTexture)? {
        guard let url else {
            #if DEBUG
            print("Could not find atlas pixels in bundle: \(name).bgra")
            #endif
            return nil
        }
        let width = atlas.width
        let height = atlas.height
        let bytesPerRow = width * 4
        guard width > 0, height > 0,
              let pixels = try? Data(contentsOf: url, options: .mappedIfSafe),
              pixels.count == bytesPerRow * height else {
            #if DEBUG
            print("Atlas pixels \(name).bgra do not match the \(width)x\(height) atlas in \(name).json")
            #endif
            return nil
        }
        // .private (the descriptor's default): the atlas is static, no CPU
        // access is needed after the upload, and a shared texture would keep
        // a CPU copy for its whole lifetime (2 x 16 MB).
        guard let texture = device.makeTexture(GPUTextureDescriptor(format: .bgra8Unorm, width: width, height: height)),
              let staging = pixels.withUnsafeBytes({ bytes in
                  device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, storage: .shared)
              }),
              let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitEncoder() else {
            return nil
        }
        blit.copy(from: staging, sourceOffset: 0, bytesPerRow: bytesPerRow,
                  to: texture, slice: 0, mipmapLevel: 0,
                  x: 0, y: 0, width: width, height: height)
        blit.endEncoding()
        commandBuffer.commit()
        // The render queues that sample the atlas are not ordered against
        // this one; waiting here is what makes the texture whole for them.
        commandBuffer.waitUntilCompleted()
        return texture
    }
}
