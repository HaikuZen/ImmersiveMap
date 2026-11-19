// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import PortableFoundation

/// The pins' pictures the engine does not draw itself, drawn by the host
/// where there is no Core Graphics (a browser page, with a 2D canvas, as it
/// draws the POI icons). Apple's platforms draw them with Core Graphics and
/// never ask. Each picture is described here as Apple's platforms draw it,
/// so a host draws the same.
///
/// A picture the host cannot draw is nil: the placeholder then stays a
/// plain square, a shape has no field (`PinShapeDistanceField.encodedField`),
/// and a count no badge picture.
package protocol PinPictureDrawing: Sendable {
    /// Whether each sample of a `side` by `side` grid lies inside the shape,
    /// row 0 at the top: the parts filled white on black, one over another,
    /// each by the nonzero rule, inside a square of the grid inset by
    /// `margin` (a fraction of `side`) on every side, then a sample inside
    /// where it is at least half white. The parts are in a unit square with
    /// the origin in the top left corner and y down, which maps onto that
    /// inset square. `side * side` values.
    func coverage(of parts: [PinShapePath], side: Int, margin: Double) -> [Bool]?

    /// A merged pin's counter, `side` pixels square, transparent around: a
    /// white disc inset by `max(side * 0.05, 1.5)` pixels on every side,
    /// stroked in black at 10 % alpha `max(side * 0.03, 1)` pixels wide,
    /// and `text` centred on it in the system's bold font with tabular
    /// digits, 8 % grey, `side * 0.44` pixels high for one or two
    /// characters, 0.82 of that for three and 0.66 for more.
    func countBadge(text: String, side: Int) -> PinImage?

    /// The picture a pin shows while its remote picture loads, `side`
    /// pixels square (64): opaque (0.18, 0.20, 0.24), with two discs of
    /// (0.42, 0.46, 0.52) for a head and shoulders, in a 64-pixel square,
    /// y down: an ellipse in (22, 14, 20, 20) and one in (14, 38, 36, 22),
    /// scaled with the side.
    func placeholder(side: Int) -> PinImage?
}

/// Where the engine finds the host's drawer.
package enum PinPictureHost {
    /// Set by the host before it makes a map, where there is no Core
    /// Graphics. Nil on Apple's platforms, which draw the pictures
    /// themselves.
    nonisolated(unsafe) package static var drawer: (any PinPictureDrawing)?
}

/// A merged pin's counter as the badge atlas keeps it: a count up to
/// `maximumCount`, or the one badge of every larger count.
enum PinCountBadgeKey: Hashable {
    case count(Int)
    case overflow

    /// The largest count drawn as itself.
    static let maximumCount = 999

    init(_ badge: PinCountBadge) {
        self = badge.count > Self.maximumCount ? .overflow : .count(max(1, badge.count))
    }

    /// What the badge reads.
    var text: String {
        switch self {
        case .count(let count):
            return "\(count)"
        case .overflow:
            return "\(Self.maximumCount)+"
        }
    }

    /// The badge's cell in the atlas, counting from 0.
    var atlasIndex: Int {
        switch self {
        case .count(let count):
            return count - 1
        case .overflow:
            return Self.maximumCount
        }
    }

    /// The height of the badge's digits as a part of its side.
    static func fontScale(characterCount: Int) -> Double {
        characterCount <= 2 ? 1.0 : (characterCount == 3 ? 0.82 : 0.66)
    }
}
