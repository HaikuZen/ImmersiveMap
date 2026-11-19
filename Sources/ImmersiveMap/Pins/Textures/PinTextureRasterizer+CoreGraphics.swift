// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import CoreGraphics
import os
import PortableFoundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// The pins' pictures on Apple's platforms, drawn by Core Graphics: a
// picture of a CGImage into an atlas cell, and the merged pins' counters.
extension PinTextureRasterizer {
    static func makeBGRAData(for image: CGImage,
                             width: Int,
                             height: Int,
                             flipVertically: Bool = true) -> [UInt8]? {
        if let warning = imageSizeWarning(sourceWidth: image.width,
                                          sourceHeight: image.height,
                                          targetWidth: width,
                                          targetHeight: height) {
            logger.warning("\(warning, privacy: .public)")
        }

        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height
        var data = [UInt8](repeating: 0, count: byteCount)
        let didDraw = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return false }
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let alphaInfo = CGImageAlphaInfo.premultipliedFirst
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: alphaInfo.rawValue))
            guard let context = CGContext(data: baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: colorSpace,
                                          bitmapInfo: bitmapInfo.rawValue)
            else {
                return false
            }
            if flipVertically {
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: 1, y: -1)
            }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return didDraw ? data : nil
    }

}

extension PinCountBadgePicture {
    /// A merged pin's counter drawn by Core Graphics, `side` pixels square.
    static func makeBadgeImage(for key: PinCountBadgeKey, side: Int) -> PinImage? {
        let size = CGSize(width: side, height: side)
        let image = PlatformGraphicsImageRenderer.makeCGImage(size: size) { _ in
            let bounds = CGRect(origin: .zero, size: size)
            let inset = max(size.width * 0.05, 1.5)
            let circleRect = bounds.insetBy(dx: inset, dy: inset)
            let circlePath = PlatformBezierPath(ovalIn: circleRect)
            PlatformColor.white.setFill()
            circlePath.fill()
            PlatformColor(white: 0.0, alpha: 0.10).setStroke()
            circlePath.lineWidth = max(size.width * 0.03, 1.0)
            circlePath.stroke()

            let textValue = key.text

            // Three-digit values are squeezed so they don't spill out of the circle.
            let baseFontSize = size.height * 0.44
            let fontScale = CGFloat(PinCountBadgeKey.fontScale(characterCount: textValue.count))
            let font = PlatformFont.monospacedDigitSystemFont(ofSize: baseFontSize * fontScale,
                                                              weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: PlatformColor(white: 0.08, alpha: 1.0)
            ]
            let text = textValue as NSString
            let textSize = text.size(withAttributes: attributes)
            let textRect = CGRect(x: circleRect.midX - textSize.width * 0.5,
                                  y: circleRect.midY - textSize.height * 0.5,
                                  width: ceil(textSize.width),
                                  height: ceil(textSize.height))
            text.draw(in: textRect, withAttributes: attributes)
        }
        return image.map { PinImage(cgImage: $0) }
    }
}
