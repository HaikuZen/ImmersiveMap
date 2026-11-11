// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PortableFoundation
import simd

// The text renderer's data that is not the GPU's: the atlas description
// read from its JSON, the glyph and label vertices, the measured sizes and
// the wrap options. Apart from `TextRenderer` so the code that lays labels
// out builds where there is no Metal.

struct TextSize {
    let width: simd_float1
    let height: simd_float1
}

struct TextMetrics {
    let size: TextSize
    let vertices: [LabelVertex]
}

enum LabelTextAlignment {
    case left
    case center
    case right
}

struct LabelWrapOptions {
    let maxWidth: Float
    let maxLines: Int
    let alignment: LabelTextAlignment

    init(maxWidth: Float,
         maxLines: Int,
         alignment: LabelTextAlignment = .left) {
        self.maxWidth = maxWidth
        self.maxLines = maxLines
        self.alignment = alignment
    }
}

struct AtlasData: Codable {
    let atlas: AtlasInfo
    let metrics: Metrics
    let glyphs: [Glyph]
}

struct AtlasInfo: Codable {
    let type: String
    let distanceRange: CGFloat
    let distanceRangeMiddle: CGFloat
    let size: CGFloat
    let width: Int
    let height: Int
    let yOrigin: String
}

struct Metrics: Codable {
    let emSize: CGFloat
    let lineHeight: CGFloat
    let ascender: CGFloat
    let descender: CGFloat
    let underlineY: CGFloat
    let underlineThickness: CGFloat
}

struct Glyph: Codable {
    let unicode: UInt32
    let advance: CGFloat
    var planeBounds: Bounds?
    var atlasBounds: Bounds?
    
    enum CodingKeys: String, CodingKey {
        case unicode, advance, planeBounds = "planeBounds", atlasBounds = "atlasBounds"
    }
}

struct Bounds: Codable {
    let left: CGFloat
    let bottom: CGFloat
    let right: CGFloat
    let top: CGFloat
}

struct TextVertex {
    var position: SIMD4<Float> // x, y, z=0, w=1
    var uv: SIMD2<Float>
}

struct TextStyleUniform: Equatable {
    var textColor: SIMD3<Float>
    /// How far the letters are grown past the font's outline, in pixels.
    var fillBiasPx: Float
    var strokeColor: SIMD3<Float>
    var strokeWidthPx: Float
    /// The opacity of the fill and the halo, 1 solid
    /// (`LabelTextStyle.opacity`).
    var opacity: Float
    /// The share of the halo's width over which it fades out, 0 solid to
    /// its edge (`LabelTextStyle.haloSoftness`).
    var haloSoftness: Float

    init(textColor: SIMD3<Float>,
         strokeColor: SIMD3<Float> = SIMD3<Float>(1.0, 1.0, 1.0),
         strokeWidthPx: Float = 2.0,
         fillBiasPx: Float = 0.75,
         opacity: Float = 1,
         haloSoftness: Float = 0) {
        self.textColor = textColor
        self.fillBiasPx = fillBiasPx
        self.strokeColor = strokeColor
        self.strokeWidthPx = strokeWidthPx
        self.opacity = opacity
        self.haloSoftness = haloSoftness
    }
}

struct LabelVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
    var labelIndex: simd_int1
    var spriteUV: SIMD2<Float>

    init(position: SIMD2<Float>,
         uv: SIMD2<Float>,
         labelIndex: simd_int1,
         spriteUV: SIMD2<Float> = .zero) {
        self.position = position
        self.uv = uv
        self.labelIndex = labelIndex
        self.spriteUV = spriteUV
    }
}

struct TextEntry {
    let text: String
    let position: SIMD2<Float>
    let scale: Float
    
    init(text: String, position: SIMD2<Float>, scale: Float = 1.0) {
        self.text = text
        self.position = position
        self.scale = scale
    }
}
