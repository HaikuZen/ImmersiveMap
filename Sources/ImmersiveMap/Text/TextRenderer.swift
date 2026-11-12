// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import simd

/// The `Text` folder: text atlas decoding, glyph metrics, label text layout
/// (measure, wrap, align), the vertex data shared with the renderer, and this
/// renderer, which builds the text pipeline and the glyph-atlas textures. Text
/// data and geometry only: no schema-specific name or language rules, no
/// runtime label caches, collision state or fade policy, no tile loading.
/// The text shader sits beside it in `Text/Shaders`.
class TextRenderer {
    /// The layout half: atlas metrics and every measure, wrap and vertex
    /// build (`TextLayout`). The renderer adds the atlas textures and the
    /// pipelines.
    let layout: TextLayout
    private var device: MTLDevice!
    var texture: MTLTexture!
    var thinTexture: MTLTexture!
    private var bundle: Bundle!
    var pipelineState: MTLRenderPipelineState!
    var labelPipelineState: MTLRenderPipelineState!
    var roadLabelPipelineState: MTLRenderPipelineState!
    var poiIconPipelineState: MTLRenderPipelineState!
    /// The route sign plates: the POI quad's vertex stage and the plate's
    /// distance field (RouteShield.metal).
    var routeShieldPipelineState: MTLRenderPipelineState!
    private var library: MTLLibrary
    private let sampleCount: Int

    /// `resourceBundle` holds the atlases (`ImmersiveMapResourceBundle`).
    init(device: MTLDevice,
         library: MTLLibrary,
         resourceBundle: Bundle,
         sampleCount: Int = 1) {
        self.device = device
        self.library = library
        self.sampleCount = sampleCount
        self.bundle = resourceBundle

        // The JSON first: it carries the dimensions the raw pixel file has
        // no header for.
        layout = TextLayout(resource: { resourceBundle.url(forResource: $0, withExtension: $1) })
        loadAtlasTexture()
        createPipelines()
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

    private func loadAtlasTexture() {
        texture = loadAtlasTexture(named: TextLayout.boldAtlasName, atlas: layout.atlasData.atlas) ?? makeFallbackTexture()
        thinTexture = loadAtlasTexture(named: TextLayout.thinAtlasName, atlas: layout.thinAtlasData.atlas) ?? texture
    }

    private func makeFallbackTexture() -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2D
        descriptor.pixelFormat = .bgra8Unorm
        descriptor.width = 1
        descriptor.height = 1
        descriptor.usage = [.shaderRead]
        return device.makeTexture(descriptor: descriptor)!
    }

    /// The atlas pixels ship raw (`<name>.bgra`: BGRA8, the byte order of
    /// `bgra8Unorm`, row major, top row first, `width * height * 4` bytes,
    /// no header), the bytes the image decoder used to produce, written
    /// once by `Tools/TextAtlas/png_to_rgba.swift`. Loading is then a copy into a
    /// staging buffer and a blit into the private texture: no PNG inflate
    /// and unfilter, which was the largest single item of the engine's
    /// creation on the main thread.
    private func loadAtlasTexture(named name: String, atlas: AtlasInfo) -> MTLTexture? {
        guard let url = bundle.url(forResource: name, withExtension: "bgra") else {
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
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        // .private: the atlas is static, no CPU access is needed after the
        // upload, and a shared texture would keep a CPU copy for its whole
        // lifetime (2 x 16 MB).
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor),
              let staging = pixels.withUnsafeBytes({ bytes in
                  device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
              }),
              let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return nil
        }
        blit.copy(from: staging,
                  sourceOffset: 0,
                  sourceBytesPerRow: bytesPerRow,
                  sourceBytesPerImage: bytesPerRow * height,
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: texture,
                  destinationSlice: 0,
                  destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.commit()
        // The render queues that sample the atlas are not ordered against
        // this one; waiting here is what makes the texture whole for them.
        commandBuffer.waitUntilCompleted()
        return texture
    }

    private func createPipelines() {
        guard let textVertexFn = library.makeFunction(name: "textVertex"),
              let labelVertexFn = library.makeFunction(name: "labelTextVertex"),
              let roadLabelVertexFn = library.makeFunction(name: "roadLabelTextVertex"),
              let poiIconVertexFn = library.makeFunction(name: "poiSpriteVertex"),
              let poiIconFragmentFn = library.makeFunction(name: "poiSpriteFragment"),
              let routeShieldFragmentFn = library.makeFunction(name: "routeShieldFragment"),
              let fragmentFn = library.makeFunction(name: "textFragment"),
              let roadFragmentFn = library.makeFunction(name: "roadTextFragment") else { fatalError("Functions not found") }
        
        let textVertexDescriptor = MTLVertexDescriptor()
        textVertexDescriptor.attributes[0].format = .float4
        textVertexDescriptor.attributes[0].offset = 0
        textVertexDescriptor.attributes[0].bufferIndex = 0
        textVertexDescriptor.attributes[1].format = .float2
        textVertexDescriptor.attributes[1].offset = MemoryLayout<SIMD4<Float>>.stride
        textVertexDescriptor.attributes[1].bufferIndex = 0
        textVertexDescriptor.layouts[0].stride = MemoryLayout<TextVertex>.stride
        
        let labelVertexDescriptor = MTLVertexDescriptor()
        labelVertexDescriptor.attributes[0].format = .float2
        labelVertexDescriptor.attributes[0].offset = MemoryLayout<LabelVertex>.offset(of: \LabelVertex.position) ?? 0
        labelVertexDescriptor.attributes[0].bufferIndex = 0
        labelVertexDescriptor.attributes[1].format = .float2
        labelVertexDescriptor.attributes[1].offset = MemoryLayout<LabelVertex>.offset(of: \LabelVertex.uv) ?? 0
        labelVertexDescriptor.attributes[1].bufferIndex = 0
        labelVertexDescriptor.attributes[2].format = .int
        labelVertexDescriptor.attributes[2].offset = MemoryLayout<LabelVertex>.offset(of: \LabelVertex.labelIndex) ?? 0
        labelVertexDescriptor.attributes[2].bufferIndex = 0
        labelVertexDescriptor.attributes[3].format = .float2
        labelVertexDescriptor.attributes[3].offset = MemoryLayout<LabelVertex>.offset(of: \LabelVertex.spriteUV) ?? 0
        labelVertexDescriptor.attributes[3].bufferIndex = 0
        labelVertexDescriptor.layouts[0].stride = MemoryLayout<LabelVertex>.stride
        
        do {
            pipelineState = try makePipelineState(vertexFunction: textVertexFn,
                                                  vertexDescriptor: textVertexDescriptor,
                                                  fragmentFunction: fragmentFn)
            labelPipelineState = try makePipelineState(vertexFunction: labelVertexFn,
                                                       vertexDescriptor: labelVertexDescriptor,
                                                       fragmentFunction: fragmentFn)
            roadLabelPipelineState = try makePipelineState(vertexFunction: roadLabelVertexFn,
                                                           vertexDescriptor: labelVertexDescriptor,
                                                           fragmentFunction: roadFragmentFn)
            poiIconPipelineState = try makePipelineState(vertexFunction: poiIconVertexFn,
                                                         vertexDescriptor: labelVertexDescriptor,
                                                         fragmentFunction: poiIconFragmentFn)
            routeShieldPipelineState = try makePipelineState(vertexFunction: poiIconVertexFn,
                                                             vertexDescriptor: labelVertexDescriptor,
                                                             fragmentFunction: routeShieldFragmentFn)
        } catch {
            fatalError("Pipeline creation failed: \(error)")
        }
    }
    
    private func makePipelineState(vertexFunction: MTLFunction,
                                   vertexDescriptor: MTLVertexDescriptor,
                                   fragmentFunction: MTLFunction) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.rasterSampleCount = sampleCount
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        // Alpha blends with .one so glyph coverage accumulates on a transparent
        // destination; over an opaque one the result is unchanged.
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}
