// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import CoreGraphics
import PortableFoundation

// The shapes' coverage on Apple's platforms, filled by Core Graphics.
extension PinShapeDistanceField {
    /// Whether each sample of a `side` by `side` grid lies inside the shape.
    /// Row 0 is the top of the unit square.
    static func coverage(paths: [CGPath], side: Int) -> [Bool] {
        var pixels = [UInt8](repeating: 0, count: side * side)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress,
                                          width: side,
                                          height: side,
                                          bitsPerComponent: 8,
                                          bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return
            }
            // The unit square, y down, laid inside the margin.
            context.translateBy(x: 0.0, y: CGFloat(side))
            context.scaleBy(x: CGFloat(side), y: -CGFloat(side))
            context.translateBy(x: margin, y: margin)
            context.scaleBy(x: 1.0 - 2.0 * margin, y: 1.0 - 2.0 * margin)
            context.clip(to: CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0))
            context.setFillColor(gray: 1.0, alpha: 1.0)
            for path in paths {
                context.addPath(path)
                context.fillPath()
            }
        }
        return pixels.map { $0 >= 128 }
    }

    /// Whether each sample of a `side` by `side` grid lies inside the shape a
    /// mask pictures: where the mask is light and opaque. Row 0 is the top.
    static func coverage(mask: CGImage, side: Int) -> [Bool] {
        var pixels = [UInt8](repeating: 0, count: side * side)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress,
                                          width: side,
                                          height: side,
                                          bitsPerComponent: 8,
                                          bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return
            }
            // Over black, a transparent part of the mask and a black one read
            // the same. The context is not flipped: an image drawn into one
            // comes out upright, its top in the first row.
            context.setFillColor(gray: 0.0, alpha: 1.0)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            context.interpolationQuality = .high
            let inset = margin * CGFloat(side)
            context.draw(mask, in: CGRect(x: inset,
                                          y: inset,
                                          width: CGFloat(side) - 2.0 * inset,
                                          height: CGFloat(side) - 2.0 * inset))
        }
        return pixels.map { $0 >= 128 }
    }

    static func coverage(paths: [PinShapePath], side: Int) -> [Bool]? {
        coverage(paths: paths.map(\.cgPath), side: side)
    }

    static func coverage(mask: PinImage, side: Int) -> [Bool]? {
        coverage(mask: mask.cgImage, side: side)
    }

    /// The field of Core Graphics paths, as `encodedField(for:)` makes a
    /// shape's.
    static func encodedField(paths: [CGPath]) -> [UInt16] {
        encodedField(inside: coverage(paths: paths, side: fineSide))
    }

    static func encodedField(mask: CGImage) -> [UInt16] {
        encodedField(inside: coverage(mask: mask, side: fineSide))
    }

}
