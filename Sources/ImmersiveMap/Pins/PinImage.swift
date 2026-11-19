// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import PortableFoundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A pin's picture, the engine's own image type: the one the pins take on
/// every platform. On Apple's platforms it wraps a `CGImage` as it is, so a
/// picture made from one draws as it always did and is drawn by Core
/// Graphics into the atlas. Elsewhere it holds its pixels.
///
/// Pins that share a picture share one cell of the atlas: the atlas knows a
/// picture by its identity (`atlasKey`), so hand the same `PinImage` (or, on
/// Apple's platforms, the same `CGImage`) to every pin that shows it.
public final class PinImage: @unchecked Sendable {
    // Immutable after init: the class exists for its identity, which keys
    // the atlas, not to be changed.
    enum Storage {
        /// Premultiplied BGRA, eight bits a sample, rows from the top, no
        /// padding: the atlas's own texel format.
        case pixels([UInt8])
        #if canImport(CoreGraphics)
        case cgImage(CGImage)
        #endif
    }

    /// The width in pixels.
    public let width: Int
    /// The height in pixels.
    public let height: Int
    let storage: Storage

    /// A picture from pixels already in the atlas's format.
    ///
    /// - Parameters:
    ///   - width: The width in pixels, at least 1.
    ///   - height: The height in pixels, at least 1.
    ///   - premultipliedBGRA: Blue, green, red and alpha, eight bits each,
    ///     the colours multiplied by the alpha, rows from the top, no
    ///     padding: `width * height * 4` bytes.
    public init(width: Int, height: Int, premultipliedBGRA: [UInt8]) {
        precondition(width > 0 && height > 0, "a pin's picture has at least one pixel")
        precondition(premultipliedBGRA.count == width * height * 4,
                     "a picture has four bytes a pixel")
        self.width = width
        self.height = height
        self.storage = .pixels(premultipliedBGRA)
    }

    /// A picture from straight (not premultiplied) RGBA pixels, as a PNG
    /// decoder or a browser's `getImageData` gives them.
    ///
    /// - Parameters:
    ///   - width: The width in pixels, at least 1.
    ///   - height: The height in pixels, at least 1.
    ///   - rgba: Red, green, blue and alpha, eight bits each, rows from the
    ///     top, no padding: `width * height * 4` bytes.
    public convenience init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(rgba.count == width * height * 4, "a picture has four bytes a pixel")
        var bgra = [UInt8](repeating: 0, count: rgba.count)
        var index = 0
        while index < rgba.count {
            let alpha = UInt32(rgba[index + 3])
            bgra[index] = Self.premultiply(rgba[index + 2], alpha)
            bgra[index + 1] = Self.premultiply(rgba[index + 1], alpha)
            bgra[index + 2] = Self.premultiply(rgba[index], alpha)
            bgra[index + 3] = UInt8(alpha)
            index += 4
        }
        self.init(width: width, height: height, premultipliedBGRA: bgra)
    }

    #if canImport(CoreGraphics)
    /// A picture of a `CGImage`, kept as it is and drawn by Core Graphics.
    public init(cgImage: CGImage) {
        self.width = cgImage.width
        self.height = cgImage.height
        self.storage = .cgImage(cgImage)
    }

    /// The picture as a `CGImage`: the one it was made from, or one made of
    /// its pixels.
    public var cgImage: CGImage {
        switch storage {
        case .cgImage(let image):
            return image
        case .pixels(let pixels):
            guard let image = Self.makeCGImage(width: width, height: height, premultipliedBGRA: pixels) else {
                fatalError("Failed to make a CGImage of a \(width)x\(height) pin picture.")
            }
            return image
        }
    }

    private static func makeCGImage(width: Int, height: Int, premultipliedBGRA: [UInt8]) -> CGImage? {
        let alphaInfo = CGImageAlphaInfo.premultipliedFirst
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: alphaInfo.rawValue))
        guard let provider = CGDataProvider(data: Data(premultipliedBGRA) as CFData) else {
            return nil
        }
        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: bitmapInfo,
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent)
    }
    #endif

    /// What the atlas knows the picture by: the `CGImage`'s identity for a
    /// picture of one, so that pins handed the same `CGImage` share a cell
    /// as they always did, and the picture's own otherwise.
    var atlasKey: ObjectIdentifier {
        switch storage {
        case .pixels:
            return ObjectIdentifier(self)
        #if canImport(CoreGraphics)
        case .cgImage(let image):
            return ObjectIdentifier(image)
        #endif
        }
    }

    /// Whether two pictures are the same one to the atlas.
    func isSamePicture(as other: PinImage) -> Bool {
        atlasKey == other.atlasKey
    }

    private static func premultiply(_ sample: UInt8, _ alpha: UInt32) -> UInt8 {
        UInt8((UInt32(sample) * alpha + 127) / 255)
    }
}

/// Resamples premultiplied pixels to another size, for a picture of pixels
/// drawn into an atlas cell of another size: a box filter as wide as the
/// step between target pixels (an average of what each target pixel covers)
/// when it shrinks, a linear filter when it grows. Premultiplied samples
/// average without dark fringes at transparent edges.
enum PinPixelResampler {
    static func resample(_ pixels: [UInt8],
                         width: Int,
                         height: Int,
                         toWidth targetWidth: Int,
                         height targetHeight: Int) -> [UInt8] {
        precondition(pixels.count == width * height * 4)
        if width == targetWidth && height == targetHeight {
            return pixels
        }
        let columns = weights(from: width, to: targetWidth)
        let rows = weights(from: height, to: targetHeight)

        // Rows first: target width by source height.
        var horizontal = [Float](repeating: 0, count: targetWidth * height * 4)
        for y in 0..<height {
            let sourceRow = y * width * 4
            let targetRow = y * targetWidth * 4
            for x in 0..<targetWidth {
                var sum = SIMD4<Float>(repeating: 0)
                for (sourceX, weight) in columns[x] {
                    let index = sourceRow + sourceX * 4
                    sum += SIMD4<Float>(Float(pixels[index]),
                                        Float(pixels[index + 1]),
                                        Float(pixels[index + 2]),
                                        Float(pixels[index + 3])) * weight
                }
                let index = targetRow + x * 4
                horizontal[index] = sum.x
                horizontal[index + 1] = sum.y
                horizontal[index + 2] = sum.z
                horizontal[index + 3] = sum.w
            }
        }

        var result = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)
        for y in 0..<targetHeight {
            for x in 0..<targetWidth {
                var sum = SIMD4<Float>(repeating: 0)
                for (sourceY, weight) in rows[y] {
                    let index = (sourceY * targetWidth + x) * 4
                    sum += SIMD4<Float>(horizontal[index],
                                        horizontal[index + 1],
                                        horizontal[index + 2],
                                        horizontal[index + 3]) * weight
                }
                let alpha = min(max(sum.w.rounded(), 0), 255)
                let index = (y * targetWidth + x) * 4
                // A premultiplied colour never exceeds its alpha.
                result[index] = UInt8(min(max(sum.x.rounded(), 0), alpha))
                result[index + 1] = UInt8(min(max(sum.y.rounded(), 0), alpha))
                result[index + 2] = UInt8(min(max(sum.z.rounded(), 0), alpha))
                result[index + 3] = UInt8(alpha)
            }
        }
        return result
    }

    /// For each target sample, the source samples it reads and their
    /// weights, which sum to 1. Sample centres sit at half pixels.
    static func weights(from sourceCount: Int, to targetCount: Int) -> [[(Int, Float)]] {
        let scale = Float(sourceCount) / Float(targetCount)
        // The filter's half width in source pixels: a triangle one pixel
        // wide either side when growing, as wide as a target pixel when
        // shrinking.
        let support = max(scale, 1.0)
        return (0..<targetCount).map { target in
            let center = (Float(target) + 0.5) * scale
            let first = max(Int((center - support).rounded(.down)), 0)
            let last = min(Int((center + support).rounded(.up)), sourceCount - 1)
            var taps: [(Int, Float)] = []
            var total: Float = 0
            if first <= last {
                for source in first...last {
                    let distance = abs(Float(source) + 0.5 - center) / support
                    let weight = max(0, 1 - distance)
                    if weight > 0 {
                        taps.append((source, weight))
                        total += weight
                    }
                }
            }
            if taps.isEmpty || total <= 0 {
                let nearest = min(max(Int(center), 0), sourceCount - 1)
                return [(nearest, 1)]
            }
            return taps.map { ($0.0, $0.1 / total) }
        }
    }
}

#if !canImport(CoreGraphics)
extension PinImage {
    /// The picture a pin shows while its remote picture loads, when it was
    /// given no placeholder of its own. Apple's platforms draw it with Core
    /// Graphics (`PinImageLoader`). Here the host's drawer draws it
    /// (`PinPictureHost`), made on first use, so the host sets its drawer
    /// before it makes a pin. Without one it is the same dark square
    /// without the figure on it.
    public static let defaultPlaceholder: PinImage = {
        if let drawn = PinPictureHost.drawer?.placeholder(side: 64) {
            return drawn
        }
        let side = 64
        // 0.18, 0.20, 0.24 of the Apple placeholder, opaque, as BGRA.
        let texel: [UInt8] = [61, 51, 46, 255]
        var pixels: [UInt8] = []
        pixels.reserveCapacity(side * side * 4)
        for _ in 0..<(side * side) {
            pixels.append(contentsOf: texel)
        }
        return PinImage(width: side, height: side, premultipliedBGRA: pixels)
    }()
}
#endif

/// How a pin's remote picture is loaded: `URLSession` and ImageIO on
/// Apple's platforms (`PinImageLoader`), and elsewhere the loader the host
/// sets before it makes a pins controller (a browser page's `fetch` and
/// `createImageBitmap`). With none set, a remote picture fails to load and
/// the pin keeps its placeholder.
package enum PinRemoteImages {
    package typealias Load = @Sendable (URL) async throws -> PinImage

    /// The host's loader, for the platforms without ImageIO.
    nonisolated(unsafe) package static var hostLoader: Load?

    /// No loader was set where the platform has none of its own.
    package struct NoLoader: Error, Equatable {}

    static var loader: Load {
        #if canImport(ImageIO)
        return { url in try await PinImageLoader.load(from: url) }
        #else
        return hostLoader ?? { _ in throw NoLoader() }
        #endif
    }
}
