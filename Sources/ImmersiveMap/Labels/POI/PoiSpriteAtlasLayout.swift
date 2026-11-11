// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PortableFoundation
import simd
// The symbols' weight is the platform's font weight. Without UIKit or
// AppKit there are no symbols to draw, and the descriptor is the layout's
// sizes alone.
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Where each POI icon sits in the sprite atlas, the symbols it is drawn
// from and the atlas's sizes: plain values apart from `PoiSpriteAtlas`, which rasterizes
// the sprites and holds their GPU texture, so the label code that places
// the icons builds where there is no Metal.

extension PoiSpriteIcon {
    /// The SF Symbols the sprite is rasterized from, first available wins.
    var symbolNames: [String] {
        switch self {
        case .restaurant:
            return ["fork.knife", "fork.knife.circle.fill", "mappin.circle.fill"]
        case .cafe:
            return ["cup.and.saucer.fill", "mug.fill", "fork.knife"]
        case .bar:
            return ["wineglass.fill", "wineglass", "fork.knife"]
        case .park:
            return ["tree.fill", "leaf.fill", "circle.fill"]
        case .museum:
            return ["building.columns.fill", "building.columns", "building.2.fill"]
        case .hospital:
            return ["cross.case.fill", "cross.case", "cross.fill"]
        case .school:
            return ["graduationcap.fill", "book.fill", "building.columns.fill"]
        case .airport:
            return ["airplane", "airplane.circle.fill", "mappin.circle.fill"]
        case .stadium:
            return ["sportscourt.fill", "figure.soccer", "circle.fill"]
        case .hotel:
            return ["bed.double.fill", "bed.double", "building.2.fill"]
        case .shopping:
            return ["bag.fill", "cart.fill", "basket.fill"]
        case .gasStation:
            return ["fuelpump.fill", "fuelpump", "bolt.car.fill"]
        case .pharmacy:
            return ["pills.fill", "cross.case.fill", "cross.fill"]
        case .viewpoint:
            return ["binoculars.fill", "eye.fill", "location.viewfinder"]
        case .train:
            return ["tram.fill", "train.side.front.car", "circle.fill"]
        case .transit:
            return ["bus.fill", "bus", "circle.fill"]
        case .parking:
            return ["parkingsign", "p.circle.fill", "car.fill"]
        case .bank:
            return ["banknote.fill", "creditcard.fill", "building.columns.fill"]
        case .theatre:
            return ["theatermasks.fill", "film.fill", "star.fill"]
        case .toilets:
            return ["toilet.fill", "figure.stand", "circle.fill"]
        case .civic:
            return ["building.2.fill", "building.fill", "circle.fill"]
        case .worship:
            return ["hands.and.sparkles.fill", "hands.sparkles.fill", "sparkles"]
        case .marker:
            // No symbol: the marker is the disc alone.
            return []
        }
    }

    /// The disc's side relative to an icon's. The plain marker is a small
    /// solid dot in the category colour, so a POI without a symbol reads
    /// as a place, lighter than the POIs that say what they are.
    var discScale: Float {
        switch self {
        case .marker: return 0.42
        default: return 1
        }
    }
}

struct PoiSpriteAtlasDescriptor {
    let cellSize: Int
    let cellPadding: Int
    let minimumColumns: Int
    #if canImport(UIKit)
    let symbolWeight: UIImage.SymbolWeight
    #elseif canImport(AppKit)
    let symbolWeight: NSFont.Weight
    #endif

    /// The cell is a texture resolution, not a layout size: it stays in device
    /// pixels while the quad it fills is sized in points. It has to cover the
    /// largest quad the type scale can ask for on the densest display, which is
    /// a 12 point POI label's icon at 3x, or about 131 pixels; 128 pixels of
    /// cell less 16 of padding leaves 96 drawable, a gentler magnification than
    /// the 64 pixel cell gave at the sizes that shipped before.
    #if canImport(UIKit) || canImport(AppKit)
    static let `default` = PoiSpriteAtlasDescriptor(cellSize: 128,
                                                    cellPadding: 16,
                                                    minimumColumns: 4,
                                                    symbolWeight: .semibold)
    #else
    static let `default` = PoiSpriteAtlasDescriptor(cellSize: 128,
                                                    cellPadding: 16,
                                                    minimumColumns: 4)
    #endif
}

struct PoiSpriteAtlasRegion {
    let index: Int
    let pixelRect: CGRect
    let uvRect: SIMD4<Float>
}

struct PoiSpriteAtlasLayout {
    let icons: [PoiSpriteIcon]
    let descriptor: PoiSpriteAtlasDescriptor
    let cellsPerSide: Int
    let pixelSize: Int

    private let regionsByIcon: [PoiSpriteIcon: PoiSpriteAtlasRegion]

    init(icons: [PoiSpriteIcon] = PoiSpriteIcon.allCases,
         descriptor: PoiSpriteAtlasDescriptor = .default) {
        precondition(icons.isEmpty == false, "POI sprite atlas requires at least one icon.")
        precondition(descriptor.cellSize > descriptor.cellPadding * 2,
                     "POI sprite atlas padding must leave drawable pixels inside each cell.")

        self.icons = icons
        self.descriptor = descriptor

        let requiredSide = Int(ceil(sqrt(Double(icons.count))))
        self.cellsPerSide = max(descriptor.minimumColumns, requiredSide)
        self.pixelSize = self.cellsPerSide * descriptor.cellSize

        let invSize = 1.0 / Float(pixelSize)
        var regions: [PoiSpriteIcon: PoiSpriteAtlasRegion] = [:]
        regions.reserveCapacity(icons.count)

        for (index, icon) in icons.enumerated() {
            let cellX = index % cellsPerSide
            let cellY = index / cellsPerSide
            let pixelRect = CGRect(x: cellX * descriptor.cellSize,
                                   y: cellY * descriptor.cellSize,
                                   width: descriptor.cellSize,
                                   height: descriptor.cellSize)
            let uvRect = SIMD4<Float>(Float(pixelRect.minX) * invSize,
                                      Float(pixelRect.minY) * invSize,
                                      Float(pixelRect.maxX) * invSize,
                                      Float(pixelRect.maxY) * invSize)
            regions[icon] = PoiSpriteAtlasRegion(index: index,
                                                 pixelRect: pixelRect,
                                                 uvRect: uvRect)
        }

        self.regionsByIcon = regions
    }

    func region(for icon: PoiSpriteIcon) -> PoiSpriteAtlasRegion? {
        regionsByIcon[icon]
    }
}
