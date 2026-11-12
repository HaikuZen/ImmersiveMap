// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The text's layout needs no GPU: it reads the atlases' descriptions
/// through the resource lookup every platform has and lays labels out from
/// them, so a tile's labels are built wherever the tile is prepared.
final class TextLayoutTests: XCTestCase {
    private func makeLayout() throws -> TextLayout {
        TextLayout(resource: TestResources.url)
    }

    func testTheAtlasesLoadThroughThePortableResourceLookup() throws {
        let layout = try makeLayout()
        XCTAssertFalse(layout.atlasData.glyphs.isEmpty)
        XCTAssertFalse(layout.thinAtlasData.glyphs.isEmpty)
        XCTAssertGreaterThan(layout.atlasData.atlas.width, 1)
        XCTAssertGreaterThan(layout.atlasEmTexels(for: .bold), 0)
    }

    func testALabelIsLaidOutWithNoGPU() throws {
        let layout = try makeLayout()
        let metrics = layout.collectLabelVertices(for: "Roma", labelIndex: 3, scale: 14)
        XCTAssertEqual(metrics.vertices.count, 4 * 6, "Two triangles a glyph")
        XCTAssertTrue(metrics.vertices.allSatisfy { $0.labelIndex == 3 })
        XCTAssertGreaterThan(metrics.size.width, 0)
        XCTAssertGreaterThan(metrics.size.height, 0)

        let wider = layout.collectLabelVertices(for: "Roma", labelIndex: 3, scale: 14, letterSpacing: 0.2)
        XCTAssertGreaterThan(wider.size.width, metrics.size.width, "Tracking widens the label")
    }

    func testALongNameWrapsOntoMoreLines() throws {
        let layout = try makeLayout()
        let name = "Kafedra anatomii gistologii mikrobiologii akademii"
        let single = layout.collectLabelVertices(for: name, labelIndex: 0, scale: 14)
        let wrapped = layout.collectLabelVertices(for: name, labelIndex: 0, scale: 14,
                                                  wrap: LabelWrapOptions(maxWidth: 14 * 8, maxLines: 3))
        XCTAssertLessThan(wrapped.size.width, single.size.width)
        XCTAssertGreaterThan(wrapped.size.height, single.size.height)
    }

    func testMissingAtlasesLayOutNothing() {
        let layout = TextLayout(resource: { _, _ in nil })
        XCTAssertTrue(layout.atlasData.glyphs.isEmpty)
        XCTAssertTrue(layout.collectLabelVertices(for: "Roma", labelIndex: 0, scale: 14).vertices.isEmpty)
    }
}
