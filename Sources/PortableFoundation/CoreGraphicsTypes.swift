// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// The Core Graphics geometry types for a slim build (see
// PortableFoundation.swift): one made off Apple's platforms that must not
// link the platform's Foundation, which is where every other build takes
// them from. On Apple's platforms the names are Core Graphics' own.
//
// The engine speaks of screen points, sizes and rectangles in these types,
// its public API included, so a slim build has them under the same names
// with the same meaning and the sources stay as they are. Only what the
// engine uses is here. A member the engine starts to use is added with Core
// Graphics' behaviour, and `PortableFoundationTests` holds this file, the
// platform's Foundation and Core Graphics to the same answers.

#if !canImport(Darwin) && PORTABLE_FOUNDATION_OWN_GEOMETRY

/// Core Graphics' scalar. On Apple's platforms it is a type of its own that
/// converts to and from `Double` without a word. Here it is `Double`, which
/// the same sources compile against. That holds on a 32-bit platform too,
/// where Apple's and Foundation's scalar is a `Float`: the sources lean on
/// the silent conversion to `Double`, which only a `Double` gives a plain
/// alias. So a slim build keeps screen coordinates in more digits than the
/// other builds of the same 32-bit platform, and nothing may count on the
/// scalar's size.
public typealias CGFloat = Double

public struct CGPoint: Equatable, Hashable, Sendable {
    public var x: CGFloat
    public var y: CGFloat

    public static let zero = CGPoint(x: 0, y: 0)

    public init() {
        x = 0
        y = 0
    }

    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    public init(x: Int, y: Int) {
        self.x = CGFloat(x)
        self.y = CGFloat(y)
    }
}

public struct CGSize: Equatable, Hashable, Sendable {
    public var width: CGFloat
    public var height: CGFloat

    public static let zero = CGSize(width: 0, height: 0)

    public init() {
        width = 0
        height = 0
    }

    public init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    public init(width: Int, height: Int) {
        self.width = CGFloat(width)
        self.height = CGFloat(height)
    }
}

/// A rectangle by its origin and size. A size may be negative, the rectangle
/// then extends back from its origin, and the edges and the extents below
/// are those of the rectangle it covers, as in Core Graphics.
public struct CGRect: Equatable, Hashable, Sendable {
    public var origin: CGPoint
    public var size: CGSize

    public static let zero = CGRect(x: 0, y: 0, width: 0, height: 0)

    /// The rectangle that is nowhere: what a union starts from. Its origin
    /// is at infinity.
    public static let null = CGRect(x: CGFloat.infinity, y: CGFloat.infinity, width: 0, height: 0)

    public init() {
        origin = .zero
        size = .zero
    }

    public init(origin: CGPoint, size: CGSize) {
        self.origin = origin
        self.size = size
    }

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        origin = CGPoint(x: x, y: y)
        size = CGSize(width: width, height: height)
    }

    public init(x: Int, y: Int, width: Int, height: Int) {
        origin = CGPoint(x: x, y: y)
        size = CGSize(width: width, height: height)
    }

    public var isNull: Bool {
        origin.x == CGFloat.infinity || origin.y == CGFloat.infinity
    }

    /// True for the null rectangle and for one with no area.
    public var isEmpty: Bool {
        isNull || size.width == 0 || size.height == 0
    }

    public var width: CGFloat { abs(size.width) }
    public var height: CGFloat { abs(size.height) }
    public var minX: CGFloat { size.width < 0 ? origin.x + size.width : origin.x }
    public var maxX: CGFloat { size.width < 0 ? origin.x : origin.x + size.width }
    public var midX: CGFloat { origin.x + size.width / 2 }
    public var minY: CGFloat { size.height < 0 ? origin.y + size.height : origin.y }
    public var maxY: CGFloat { size.height < 0 ? origin.y : origin.y + size.height }
    public var midY: CGFloat { origin.y + size.height / 2 }

    /// The same rectangle with a size that is not negative.
    public var standardized: CGRect {
        isNull ? self : CGRect(x: minX, y: minY, width: width, height: height)
    }

    /// True for a point inside or on the minimum edges. The maximum edges
    /// are outside, so rectangles side by side share no point.
    public func contains(_ point: CGPoint) -> Bool {
        guard !isEmpty else {
            return false
        }
        return point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }

    /// The smallest rectangle that covers both. The null rectangle adds
    /// nothing, an empty one that is somewhere adds its place.
    public func union(_ other: CGRect) -> CGRect {
        if isNull {
            return other
        }
        if other.isNull {
            return self
        }
        let left = min(minX, other.minX)
        let bottom = min(minY, other.minY)
        return CGRect(x: left, y: bottom,
                      width: max(maxX, other.maxX) - left,
                      height: max(maxY, other.maxY) - bottom)
    }

    /// The rectangle with each vertical edge moved in by `dx` and each
    /// horizontal edge by `dy`, outward for a negative value. One inset past
    /// its own middle is the null rectangle.
    public func insetBy(dx: CGFloat, dy: CGFloat) -> CGRect {
        guard !isNull else {
            return self
        }
        let inset = CGRect(x: minX + dx, y: minY + dy, width: width - 2 * dx, height: height - 2 * dy)
        return inset.size.width < 0 || inset.size.height < 0 ? .null : inset
    }

    public func offsetBy(dx: CGFloat, dy: CGFloat) -> CGRect {
        guard !isNull else {
            return self
        }
        return CGRect(x: minX + dx, y: minY + dy, width: width, height: height)
    }
}

#endif
