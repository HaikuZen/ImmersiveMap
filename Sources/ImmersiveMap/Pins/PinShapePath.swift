// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import PortableFoundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A part of a pin shape's outline, a closed path in the pin's unit square
/// with the origin in the top left corner and y down, on every platform:
/// Core Graphics fills it on Apple's platforms (`cgPath`), the host's drawer
/// elsewhere (`PinPictureDrawing.coverage`). A shape's parts are filled one
/// over another, each by the nonzero rule.
package struct PinShapePath: Equatable, Sendable {
    package enum Element: Equatable, Sendable {
        case move(to: CGPoint)
        case line(to: CGPoint)
        case quadCurve(to: CGPoint, control: CGPoint)
        case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
        case close
    }

    package var elements: [Element]

    package init(elements: [Element]) {
        self.elements = elements
    }

    /// The distance of a cubic's control points from the corner, as a part
    /// of the radius, for the curve closest to a quarter circle.
    static let quarterCircleControl: CGFloat = 0.5522847498307936

    /// A rectangle with round corners of `radius`, clamped to half the
    /// shorter side, drawn clockwise on screen from the top edge.
    static func roundedRect(_ rect: CGRect, radius: CGFloat) -> PinShapePath {
        let radius = min(max(radius, 0.0), min(rect.width, rect.height) * 0.5)
        let minX = rect.minX
        let minY = rect.minY
        let maxX = rect.maxX
        let maxY = rect.maxY
        guard radius > 0 else {
            return polygon([CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY),
                            CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY)])
        }
        let reach = radius * (1.0 - quarterCircleControl)
        return PinShapePath(elements: [
            .move(to: CGPoint(x: minX + radius, y: minY)),
            .line(to: CGPoint(x: maxX - radius, y: minY)),
            .curve(to: CGPoint(x: maxX, y: minY + radius),
                   control1: CGPoint(x: maxX - reach, y: minY),
                   control2: CGPoint(x: maxX, y: minY + reach)),
            .line(to: CGPoint(x: maxX, y: maxY - radius)),
            .curve(to: CGPoint(x: maxX - radius, y: maxY),
                   control1: CGPoint(x: maxX, y: maxY - reach),
                   control2: CGPoint(x: maxX - reach, y: maxY)),
            .line(to: CGPoint(x: minX + radius, y: maxY)),
            .curve(to: CGPoint(x: minX, y: maxY - radius),
                   control1: CGPoint(x: minX + reach, y: maxY),
                   control2: CGPoint(x: minX, y: maxY - reach)),
            .line(to: CGPoint(x: minX, y: minY + radius)),
            .curve(to: CGPoint(x: minX + radius, y: minY),
                   control1: CGPoint(x: minX, y: minY + reach),
                   control2: CGPoint(x: minX + reach, y: minY)),
            .close
        ])
    }

    /// A closed polygon through `points`.
    static func polygon(_ points: [CGPoint]) -> PinShapePath {
        guard let first = points.first else {
            return PinShapePath(elements: [])
        }
        return PinShapePath(elements: [.move(to: first)] + points.dropFirst().map { .line(to: $0) } + [.close])
    }

    #if canImport(CoreGraphics)
    /// The path of a `CGPath`'s elements, in the same coordinates.
    init(_ path: CGPath) {
        var elements: [Element] = []
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let points = element.points
            switch element.type {
            case .moveToPoint:
                elements.append(.move(to: points[0]))
            case .addLineToPoint:
                elements.append(.line(to: points[0]))
            case .addQuadCurveToPoint:
                elements.append(.quadCurve(to: points[1], control: points[0]))
            case .addCurveToPoint:
                elements.append(.curve(to: points[2], control1: points[0], control2: points[1]))
            case .closeSubpath:
                elements.append(.close)
            @unknown default:
                break
            }
        }
        self.elements = elements
    }

    /// The path as Core Graphics fills it.
    var cgPath: CGPath {
        let path = CGMutablePath()
        for element in elements {
            switch element {
            case .move(let point):
                path.move(to: point)
            case .line(let point):
                path.addLine(to: point)
            case .quadCurve(let point, let control):
                path.addQuadCurve(to: point, control: control)
            case .curve(let point, let control1, let control2):
                path.addCurve(to: point, control1: control1, control2: control2)
            case .close:
                path.closeSubpath()
            }
        }
        return path
    }
    #endif
}
