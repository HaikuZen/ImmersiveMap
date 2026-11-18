// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PortableFoundation

final class TilePreparedDataBuilder {
    private let tileParser: TileMvtParser
    private let textLabelsBuilder: TileTextLabelsBuilder
    private let roadLabelsBuilder: TileRoadLabelsBuilder
    private let surfaceLabelsBuilder: TileSurfaceLabelsBuilder

    init(tileParser: TileMvtParser,
         textLabelsBuilder: TileTextLabelsBuilder,
         roadLabelsBuilder: TileRoadLabelsBuilder,
         surfaceLabelsBuilder: TileSurfaceLabelsBuilder) {
        self.tileParser = tileParser
        self.textLabelsBuilder = textLabelsBuilder
        self.roadLabelsBuilder = roadLabelsBuilder
        self.surfaceLabelsBuilder = surfaceLabelsBuilder
    }

    func build(tile: Tile, data: Data) throws -> PreparedTileLoadResult {
        let parsedTile = try tileParser.parse(tile: tile, mvtData: data)
        // A label stands on the screen or lies on the map, never both.
        let screenLabels = parsedTile.textLabels.filter { $0.placement == .screen }
        let textLabels = textLabelsBuilder.build(textLabels: screenLabels, tile: tile)
        let surfaceLabels = surfaceLabelsBuilder.build(textLabels: parsedTile.textLabels, tile: tile)
        let roadLabels = roadLabelsBuilder.build(roadTextLabels: parsedTile.roadTextLabels, tile: tile)

        let preparedTile = PreparedTileCPU(
            tile: tile,
            ground: PreparedTileCPU.GeometryLayer(vertices: parsedTile.drawingPolygon.vertices,
                                                  indices: parsedTile.drawingPolygon.indices,
                                                  styles: parsedTile.styles,
                                                  styleZoomFades: parsedTile.styleZoomFades,
                                                  lineStyles: parsedTile.lineStyles,
                                                  fillsIndexCount: parsedTile.drawingPolygon.fillsIndexCount,
                                                  isFlattened: parsedTile.groundIsFlattened),
            roads: parsedTile.drawingRoadPhases.map { structureBucket in
                structureBucket.map { phase in
                    PreparedTileCPU.GeometryLayer(vertices: phase.drawing.vertices,
                                                 indices: phase.drawing.indices,
                                                 styles: phase.styles,
                                                 styleZoomFades: phase.styleZoomFades,
                                                 lineStyles: phase.lineStyles,
                                                 edgeLineIndexStart: phase.drawing.edgeLineIndexStart)
                }
            },
            bridgeOverlay: PreparedTileCPU.GeometryLayer(vertices: parsedTile.drawingBridgePolygon.vertices,
                                                         indices: parsedTile.drawingBridgePolygon.indices,
                                                         styles: parsedTile.bridgeStyles,
                                                         styleZoomFades: parsedTile.bridgeStyleZoomFades,
                                                         lineStyles: parsedTile.bridgeLineStyles),
            extruded: PreparedTileCPU.Extruded(vertices: parsedTile.drawingExtruded.vertices,
                                               indices: parsedTile.drawingExtruded.indices,
                                               styles: parsedTile.drawingExtruded.styles,
                                               buildingRanges: parsedTile.drawingExtruded.buildingRanges,
                                               buildingAnchors: parsedTile.drawingExtruded.buildingAnchors,
                                               quarterIndexStarts: parsedTile.drawingExtruded.quarterIndexStarts),
            textLabels: textLabels,
            roadLabels: roadLabels,
            surfaceLabels: surfaceLabels,
            trees: parsedTile.trees,
            treeQuarterStarts: parsedTile.treeQuarterStarts
        )
        return PreparedTileLoadResult(preparedTile: preparedTile,
                                      parseLayerTimings: parsedTile.parseLayerTimings)
    }
}

extension TilePreparedDataBuilder {
    /// The builder a tile is parsed with under the settings, the style and
    /// the text's metrics: the tile store's, and a worker's that parses off
    /// the page's thread (`PortableTilePreparer`), so both bake one tile
    /// alike.
    convenience init(settings: ImmersiveMapSettings, styleRuntime: MapStyleRuntime, textLayout: TextLayout) {
        let parseOptions = TileParseOptions(settings: settings)
        let labelDecisions = TileLabelDecisions(style: styleRuntime.style,
                                                glyphCoverage: textLayout.glyphCoverage,
                                                language: settings.labels.language,
                                                fallbackPolicy: settings.labels.fallbackPolicy)
        self.init(tileParser: TileMvtParser(mapStyle: styleRuntime,
                                            labelDecisions: labelDecisions,
                                            options: parseOptions),
                  textLabelsBuilder: TileTextLabelsBuilder(textLayout: textLayout),
                  roadLabelsBuilder: TileRoadLabelsBuilder(textLayout: textLayout),
                  surfaceLabelsBuilder: TileSurfaceLabelsBuilder(textLayout: textLayout))
    }
}

extension PreparedTileCacheIdentity {
    /// What a tile parsed under the settings, the style and the text's
    /// metrics is stamped with (`TilePreparedDataBuilder.init(settings:styleRuntime:textLayout:)`):
    /// an entry of another identity is not read back.
    init(settings: ImmersiveMapSettings, styleRuntime: MapStyleRuntime, textLayout: TextLayout) {
        let parseOptions = TileParseOptions(settings: settings)
        self.init(
            preparedFormatVersion: PreparedTileDiskCaching.preparedFormatVersion,
            styleRevision: styleRuntime.preparedTileStyleRevision,
            tileSourceRevision: PreparedTileCacheIdentity.tileSourceRevision(for: settings.tiles.network),
            textRevision: textLayout.preparedTileTextRevision,
            labelLanguage: settings.labels.language,
            labelFallbackPolicy: settings.labels.fallbackPolicy,
            capitalMaximumZoom: UInt32(max(0, settings.labels.settlementVisibility.capitalMaximumZoom)),
            cityMaximumZoom: UInt32(max(0, settings.labels.settlementVisibility.cityMaximumZoom)),
            smallSettlementMaximumZoom: UInt32(max(0, settings.labels.settlementVisibility.smallSettlementMaximumZoom)),
            landmarkMinimumZoom: UInt32(max(0, settings.labels.landmarks.minimumZoom)),
            addTestBorders: settings.tiles.parsing.addTestBorders,
            labelsEnabled: settings.labels.isEnabled,
            groundFlatteningFromTileZoom: parseOptions.groundFlatteningFromTileZoom,
            groundFlatteningGrid: parseOptions.groundFlatteningGrid,
            groundFlatteningGridByTileZoomKey: parseOptions.groundFlatteningGridByTileZoomKey,
            groundReliefEnabled: parseOptions.groundReliefEnabled,
            buildingMinimumSourceZoom: parseOptions.buildingMinimumSourceZoom,
            buildingDeepestSourceZoom: parseOptions.buildingDeepestSourceZoom,
            overviewTilesEnabled: settings.tiles.overview.isEnabled,
            treeMinimumSourceZoom: parseOptions.treeMinimumSourceZoom,
            treeMaximumPerTile: parseOptions.treeMaximumPerTile
        )
    }
}

