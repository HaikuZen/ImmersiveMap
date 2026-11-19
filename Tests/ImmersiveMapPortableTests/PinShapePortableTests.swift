// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import XCTest
@testable import ImmersiveMap

/// The pins' shapes, badges and the host's drawer of their pictures, on
/// every platform the engine builds: the geometry the shapes hand a drawer,
/// what a mask covers, and what the engine does with a drawer and without
/// one. Apple's Core Graphics side is `PinShapeTests`.
final class PinShapePortableTests: XCTestCase {
    func testARoundedRectangleRunsAroundItsBoxThroughQuarterCircles() {
        // Values exact in binary, so the corners' sums are too.
        let rect = CGRect(x: 0.125, y: 0.25, width: 0.75, height: 0.5)
        let path = PinShapePath.roundedRect(rect, radius: 0.25)
        XCTAssertEqual(path.elements.first, .move(to: CGPoint(x: 0.375, y: 0.25)))
        XCTAssertEqual(path.elements.last, .close)
        XCTAssertEqual(path.elements.filter { if case .curve = $0 { true } else { false } }.count, 4)
        // Every point the path reaches lies on the box's edge.
        for element in path.elements {
            let point: CGPoint
            switch element {
            case .move(let to), .line(let to), .curve(let to, _, _), .quadCurve(let to, _):
                point = to
            case .close:
                continue
            }
            let onEdge = abs(point.x - rect.minX) < 1e-9 || abs(point.x - rect.maxX) < 1e-9
                || abs(point.y - rect.minY) < 1e-9 || abs(point.y - rect.maxY) < 1e-9
            XCTAssertTrue(onEdge, "\(point) is off the box")
        }
    }

    func testARadiusPastHalfTheShorterSideIsClampedAndNoRadiusIsARectangle() {
        let rect = CGRect(x: 0, y: 0, width: 1, height: 0.5)
        XCTAssertEqual(PinShapePath.roundedRect(rect, radius: 3).elements.first, .move(to: CGPoint(x: 0.25, y: 0)))
        XCTAssertEqual(PinShapePath.roundedRect(rect, radius: 0),
                       PinShapePath.polygon([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                                             CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5)]))
    }

    func testATailedShapeIsItsBodyAndAWedgeDownToTheAnchor() {
        let shape = PinShape.roundedRectangle(cornerRadius: 0.2, tail: true)
        guard case .paths(let parts) = shape.outline else {
            return XCTFail("A rounded rectangle is made of paths")
        }
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts[1].elements.contains(.line(to: CGPoint(x: 0.5, y: 1.0))),
                      "The wedge reaches the shape's bottom centre")
        XCTAssertEqual(shape.anchor, CGPoint(x: 0.5, y: 1.0))
        XCTAssertEqual(PinShape.roundedRectangle(cornerRadius: 0.2, tail: false).anchor, CGPoint(x: 0.5, y: 0.5))
    }

    func testShapesCompareByTheirOutline() {
        XCTAssertEqual(PinShape.circle, PinShape.roundedRectangle(cornerRadius: 0.5))
        XCTAssertNotEqual(PinShape.circle, PinShape.bubble)
        let mask = PinImage(width: 1, height: 1, premultipliedBGRA: [255, 255, 255, 255])
        XCTAssertEqual(PinShape.mask(mask), PinShape.mask(mask))
        let other = PinImage(width: 1, height: 1, premultipliedBGRA: [255, 255, 255, 255])
        XCTAssertNotEqual(PinShape.mask(mask), PinShape.mask(other), "A mask is known by its picture")
    }

    func testAPictureAreaIsCutToTheUnitSquare() {
        let mask = PinImage(width: 1, height: 1, premultipliedBGRA: [255, 255, 255, 255])
        XCTAssertEqual(PinShape.mask(mask, pictureArea: CGRect(x: 0.5, y: -1, width: 2, height: 1.5)).pictureArea,
                       CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(PinShape.mask(mask, pictureArea: CGRect(x: 2, y: 2, width: 1, height: 1)).pictureArea,
                       CGRect(x: 0, y: 0, width: 1, height: 1), "Nothing left of it is the whole square")
    }

    func testTheBadgeKeyReadsItsCountAndOverflowsPastTheMaximum() {
        XCTAssertEqual(PinCountBadgeKey(PinCountBadge(count: 7)).text, "7")
        XCTAssertEqual(PinCountBadgeKey(PinCountBadge(count: 7)).atlasIndex, 6)
        XCTAssertEqual(PinCountBadgeKey(PinCountBadge(count: 999)), .count(999))
        let overflow = PinCountBadgeKey(PinCountBadge(count: 1000))
        XCTAssertEqual(overflow, .overflow)
        XCTAssertEqual(overflow.text, "999+")
        XCTAssertEqual(overflow.atlasIndex, 999)
        XCTAssertEqual(PinCountBadgeKey.fontScale(characterCount: 2), 1.0)
        XCTAssertEqual(PinCountBadgeKey.fontScale(characterCount: 3), 0.82)
        XCTAssertEqual(PinCountBadgeKey.fontScale(characterCount: 4), 0.66)
    }

    func testTheBuiltInBubbleAndABarePictureBakeNoField() {
        XCTAssertNil(PinShapeDistanceField.encodedField(for: .bubble))
        XCTAssertNil(PinShapeDistanceField.encodedField(for: .picture()))
    }

    #if !canImport(CoreGraphics)
    func testWithoutADrawerAPathShapeHasNoField() {
        let previous = PinPictureHost.drawer
        PinPictureHost.drawer = nil
        defer { PinPictureHost.drawer = previous }
        XCTAssertNil(PinShapeDistanceField.encodedField(for: .circle))
    }

    func testTheDrawerIsAskedForTheShapesPartsInsideTheMargin() throws {
        let drawer = RecordingPinPictureDrawer()
        let previous = PinPictureHost.drawer
        PinPictureHost.drawer = drawer
        defer { PinPictureHost.drawer = previous }

        let field = try XCTUnwrap(PinShapeDistanceField.encodedField(for: .circle))
        let side = PinShapeDistanceField.textureSize
        XCTAssertEqual(field.count, side * side)
        let request = try XCTUnwrap(drawer.requests.first)
        XCTAssertEqual(request.side, PinShapeDistanceField.fineSide)
        XCTAssertEqual(request.margin, Double(PinShapeDistanceField.margin), accuracy: 1e-12)
        guard case .paths(let parts) = PinShape.circle.outline else {
            return XCTFail("A circle is made of paths")
        }
        XCTAssertEqual(request.parts, parts)
        // The drawer covered the left half: inside there, outside on the right.
        let row = side / 2
        XCTAssertGreaterThan(field[row * side + side / 4], PinShapeDistanceField.encode(distanceTexels: 0))
        XCTAssertLessThan(field[row * side + 3 * side / 4], PinShapeDistanceField.encode(distanceTexels: 0))
    }

    func testAMaskIsInsideWhereItIsLightAndOpaque() throws {
        // Left column white and opaque, right column white but clear, as
        // premultiplied BGRA: the clear one reads as black.
        let mask = PinImage(width: 2, height: 1, premultipliedBGRA: [255, 255, 255, 255, 0, 0, 0, 0])
        let side = 100
        let inside = try XCTUnwrap(PinShapeDistanceField.coverage(mask: mask, side: side))
        XCTAssertEqual(inside.count, side * side)
        XCTAssertTrue(inside[50 * side + 20])
        XCTAssertFalse(inside[50 * side + 80])
        XCTAssertFalse(inside[0], "The margin stays outside")
    }
    #endif
}

#if !canImport(CoreGraphics)
/// A drawer that covers the left half of every grid and records what it was
/// asked.
private final class RecordingPinPictureDrawer: PinPictureDrawing, @unchecked Sendable {
    struct Request {
        let parts: [PinShapePath]
        let side: Int
        let margin: Double
    }

    private(set) var requests: [Request] = []

    func coverage(of parts: [PinShapePath], side: Int, margin: Double) -> [Bool]? {
        requests.append(Request(parts: parts, side: side, margin: margin))
        return (0..<(side * side)).map { $0 % side < side / 2 }
    }

    func countBadge(text: String, side: Int) -> PinImage? {
        nil
    }

    func placeholder(side: Int) -> PinImage? {
        nil
    }
}
#endif
