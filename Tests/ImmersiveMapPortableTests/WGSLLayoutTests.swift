// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd
import XCTest
@testable import ImmersiveMap

/// Each WGSL uniform struct has its Swift twin's fields at the twin's
/// offsets and is as long as the bytes the engine sends
/// (`setVertexValue` sends the value's stride). A field that moves on one
/// side alone reads another field's bytes on the GPU, which no picture
/// test would point to.
final class WGSLLayoutTests: XCTestCase {
    private func layouts(_ path: String) throws -> [String: WGSLSources.Layout] {
        let url = WGSLSources.engineSources.appendingPathComponent(path)
        return try WGSLSources.layouts(in: String(contentsOf: url, encoding: .utf8))
    }

    private func assertLayout<T>(_ name: String, in path: String, matches _: T.Type,
                                 offsets: [Int?], file: StaticString = #filePath, line: UInt = #line) throws {
        let layout = try XCTUnwrap(try layouts(path)[name], "\(name) in \(path)", file: file, line: line)
        XCTAssertEqual(layout.members.map(\.offset), offsets.map { $0 ?? -1 },
                       "\(name)'s fields at the Swift twin's offsets", file: file, line: line)
        XCTAssertEqual(layout.size, MemoryLayout<T>.stride,
                       "\(name) as long as the bytes the engine sends", file: file, line: line)
    }

    func testTheSharedUniformsMatchTheirSwiftTwins() throws {
        let shared = "Render/Shaders/Shared/RenderUniforms.wgsl"
        try assertLayout("Camera", in: shared, matches: CameraUniform.self, offsets: [
            MemoryLayout<CameraUniform>.offset(of: \.matrix),
            MemoryLayout<CameraUniform>.offset(of: \.eye),
            MemoryLayout<CameraUniform>.offset(of: \.padding),
        ])
        try assertLayout("Globe", in: shared, matches: GlobeUniform.self, offsets: [
            MemoryLayout<GlobeUniform>.offset(of: \.panX),
            MemoryLayout<GlobeUniform>.offset(of: \.panY),
            MemoryLayout<GlobeUniform>.offset(of: \.radius),
            MemoryLayout<GlobeUniform>.offset(of: \.transition),
        ])
        try assertLayout("GlobeFrameConstants", in: shared, matches: GlobeFrameConstantsUniform.self, offsets: [
            MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \.rotation),
            MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \.sphereClip),
            MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \.sphereWorld),
            MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \.mapSize),
            MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \.panMercatorY),
            MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \.panLatitude),
            MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \.panLongitude),
            MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \.curvature),
            MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \._padding),
        ])
    }

    func testTheGlobesLightAndCapsMatchTheirSwiftTwins() throws {
        try assertLayout("GlobeLight", in: "Globe/Shaders/GlobeLight.wgsl", matches: GlobeLightUniform.self, offsets: [
            MemoryLayout<GlobeLightUniform>.offset(of: \.lightAndStrength),
            MemoryLayout<GlobeLightUniform>.offset(of: \.nightColorAndSoftness),
        ])
        try assertLayout("CapParams", in: "Globe/Shaders/Globe.wgsl", matches: GlobeCapParams.self, offsets: [
            MemoryLayout<GlobeCapParams>.offset(of: \.color),
        ])
    }

    func testTheShadowUniformsMatchTheirSwiftTwins() throws {
        let shared = "Render/Shaders/Shared/RenderUniforms.wgsl"
        typealias Cascade = ShadowCascadeUniform
        try assertLayout("ShadowCascade", in: shared, matches: Cascade.self, offsets: [
            MemoryLayout<Cascade>.offset(of: \.worldToShadowTexture),
            MemoryLayout<Cascade>.offset(of: \.tentSpread),
            MemoryLayout<Cascade>.offset(of: \.fadeStartDistance),
            MemoryLayout<Cascade>.offset(of: \.depthBias),
            MemoryLayout<Cascade>.offset(of: \.fadeEndDistance),
            MemoryLayout<Cascade>.offset(of: \.uvMinimum),
            MemoryLayout<Cascade>.offset(of: \.uvMaximum),
            MemoryLayout<Cascade>.offset(of: \.normalOffsetWorld),
            MemoryLayout<Cascade>.offset(of: \._padding0),
            MemoryLayout<Cascade>.offset(of: \.texelSizeUV),
        ])
        try assertLayout("Shadow", in: shared, matches: ShadowUniform.self, offsets: [
            MemoryLayout<ShadowUniform>.offset(of: \.near),
            MemoryLayout<ShadowUniform>.offset(of: \.far),
            MemoryLayout<ShadowUniform>.offset(of: \.eye),
            MemoryLayout<ShadowUniform>.offset(of: \.strength),
            MemoryLayout<ShadowUniform>.offset(of: \._padding0),
            MemoryLayout<ShadowUniform>.offset(of: \._padding1),
            MemoryLayout<ShadowUniform>.offset(of: \._padding2),
            MemoryLayout<ShadowUniform>.offset(of: \.lightDirection),
            MemoryLayout<ShadowUniform>.offset(of: \.tint),
            MemoryLayout<ShadowUniform>.offset(of: \.fadeCenter),
            MemoryLayout<ShadowUniform>.offset(of: \._padding3),
        ])
        try assertLayout("ShadowCasterMatrices", in: shared, matches: ShadowCasterUniform.self, offsets: [
            MemoryLayout<ShadowCasterUniform>.offset(of: \.lightProjectionView),
        ])
        try assertLayout("GroundShadowMaskUniform", in: "Shadows/Shaders/GroundShadowMask.wgsl",
                         matches: GroundShadowMaskUniform.self, offsets: [
                             MemoryLayout<GroundShadowMaskUniform>.offset(of: \.inverseProjectionView),
                             MemoryLayout<GroundShadowMaskUniform>.offset(of: \.viewportSize),
                             MemoryLayout<GroundShadowMaskUniform>.offset(of: \._padding),
                         ])
    }

    func testTheFogAndTheBuildingsMatchTheirSwiftTwins() throws {
        try assertLayout("GroundFog", in: "Render/Shaders/Shared/GroundFog.wgsl", matches: GroundFogUniform.self, offsets: [
            MemoryLayout<GroundFogUniform>.offset(of: \.colorAndDensity),
            MemoryLayout<GroundFogUniform>.offset(of: \.eyeAndMetersPerUnit),
            MemoryLayout<GroundFogUniform>.offset(of: \.parameters),
            MemoryLayout<GroundFogUniform>.offset(of: \.skyColorAndGradient),
            MemoryLayout<GroundFogUniform>.offset(of: \.startSoftness),
        ])
        let buildings = "Tile/Shaders/TileExtruded.wgsl"
        try assertLayout("BuildingLift", in: buildings, matches: BuildingLiftUniform.self, offsets: [
            MemoryLayout<BuildingLiftUniform>.offset(of: \.unitsPerMetre),
            MemoryLayout<BuildingLiftUniform>.offset(of: \.datumMetres),
            MemoryLayout<BuildingLiftUniform>.offset(of: \.strength),
            MemoryLayout<BuildingLiftUniform>.offset(of: \.padding),
        ])
        // An element of the style table: its size is the array's stride.
        try assertLayout("Style", in: buildings, matches: TilePolygonStyle.self, offsets: [
            MemoryLayout<TilePolygonStyle>.offset(of: \.color),
        ])
    }

    func testTheLabelsMatchTheirSwiftTwins() throws {
        let common = "Labels/Shaders/Shared/LabelTextCommon.wgsl"
        try assertLayout("ScreenPointOutput", in: common, matches: ScreenPointOutput.self, offsets: [
            MemoryLayout<ScreenPointOutput>.offset(of: \.position),
            MemoryLayout<ScreenPointOutput>.offset(of: \.depth),
            MemoryLayout<ScreenPointOutput>.offset(of: \.visible),
            MemoryLayout<ScreenPointOutput>.offset(of: \.visibilityAlpha),
        ])
        try assertLayout("LabelRuntimeMeta", in: common, matches: LabelRuntimeMeta.self, offsets: [
            MemoryLayout<LabelRuntimeMeta>.offset(of: \.fadeAlpha),
            MemoryLayout<LabelRuntimeMeta>.offset(of: \.perspectiveScale),
            MemoryLayout<LabelRuntimeMeta>.offset(of: \.labelSizePoints),
        ])
        try assertLayout("RoadLabelSceneDepthUniforms", in: common, matches: RoadLabelSceneDepthUniforms.self, offsets: [
            MemoryLayout<RoadLabelSceneDepthUniforms>.offset(of: \.projectionView),
            MemoryLayout<RoadLabelSceneDepthUniforms>.offset(of: \.inverseProjectionView),
            MemoryLayout<RoadLabelSceneDepthUniforms>.offset(of: \.eye),
            MemoryLayout<RoadLabelSceneDepthUniforms>.offset(of: \.viewportSize),
            MemoryLayout<RoadLabelSceneDepthUniforms>.offset(of: \.enabled),
        ])
        let road = "Labels/Shaders/Road/RoadLabelTextVertex.wgsl"
        try assertLayout("RoadGlyphInput", in: road, matches: RoadGlyphInput.self, offsets: [
            MemoryLayout<RoadGlyphInput>.offset(of: \.pathIndex),
            MemoryLayout<RoadGlyphInput>.offset(of: \.instanceIndex),
            MemoryLayout<RoadGlyphInput>.offset(of: \.labelInstanceIndex),
            MemoryLayout<RoadGlyphInput>.offset(of: \._padding),
            MemoryLayout<RoadGlyphInput>.offset(of: \.glyphCenter),
            MemoryLayout<RoadGlyphInput>.offset(of: \.labelCenterY),
            MemoryLayout<RoadGlyphInput>.offset(of: \.labelWidth),
            MemoryLayout<RoadGlyphInput>.offset(of: \.spacing),
            MemoryLayout<RoadGlyphInput>.offset(of: \.minLength),
        ])
        try assertLayout("RoadGlyphPlacementOutput", in: road, matches: RoadGlyphPlacementOutput.self, offsets: [
            MemoryLayout<RoadGlyphPlacementOutput>.offset(of: \.position),
            MemoryLayout<RoadGlyphPlacementOutput>.offset(of: \.angle),
            MemoryLayout<RoadGlyphPlacementOutput>.offset(of: \.visible),
        ])
        try assertLayout("TextStyle", in: "Text/Shaders/TextShader.wgsl", matches: TextStyleUniform.self, offsets: [
            MemoryLayout<TextStyleUniform>.offset(of: \.textColor),
            MemoryLayout<TextStyleUniform>.offset(of: \.fillBiasPx),
            MemoryLayout<TextStyleUniform>.offset(of: \.strokeColor),
            MemoryLayout<TextStyleUniform>.offset(of: \.strokeWidthPx),
            MemoryLayout<TextStyleUniform>.offset(of: \.opacity),
            MemoryLayout<TextStyleUniform>.offset(of: \.haloSoftness),
        ])
        try assertLayout("PoiIconStyle", in: "Labels/Shaders/POI/PoiSprite.wgsl", matches: PoiIconStyleUniform.self, offsets: [
            MemoryLayout<PoiIconStyleUniform>.offset(of: \.backgroundColor),
            MemoryLayout<PoiIconStyleUniform>.offset(of: \.iconColor),
            MemoryLayout<PoiIconStyleUniform>.offset(of: \.opacity),
        ])
        try assertLayout("RouteShieldStyle", in: "Labels/Shaders/RouteShield/RouteShield.wgsl",
                         matches: RouteShieldStyleUniform.self, offsets: [
                             MemoryLayout<RouteShieldStyleUniform>.offset(of: \.fillColor),
                             MemoryLayout<RouteShieldStyleUniform>.offset(of: \.borderColor),
                             MemoryLayout<RouteShieldStyleUniform>.offset(of: \.headerColor),
                             MemoryLayout<RouteShieldStyleUniform>.offset(of: \.borderWidthPoints),
                             MemoryLayout<RouteShieldStyleUniform>.offset(of: \.cornerRadiusPoints),
                             MemoryLayout<RouteShieldStyleUniform>.offset(of: \.headerFraction),
                             MemoryLayout<RouteShieldStyleUniform>.offset(of: \.shape),
                         ])
    }

    func testTheSurfaceLabelsMatchTheirSwiftTwins() throws {
        let surface = "Labels/Shaders/Surface/SurfaceLabel.wgsl"
        try assertLayout("SurfaceLabelSphereTile", in: surface, matches: GlobeSurfaceTileUniform.self, offsets: [
            MemoryLayout<GlobeSurfaceTileUniform>.offset(of: \.uvOrigin),
            MemoryLayout<GlobeSurfaceTileUniform>.offset(of: \.uvScale),
            MemoryLayout<GlobeSurfaceTileUniform>.offset(of: \.referenceWorldX),
        ])
        try assertLayout("SurfaceLabelDraw", in: surface, matches: SurfaceLabelDrawUniform.self, offsets: [
            MemoryLayout<SurfaceLabelDrawUniform>.offset(of: \.fillColor),
            MemoryLayout<SurfaceLabelDrawUniform>.offset(of: \.strokeColor),
            MemoryLayout<SurfaceLabelDrawUniform>.offset(of: \.haloAtlasTexels),
            MemoryLayout<SurfaceLabelDrawUniform>.offset(of: \.depth),
            MemoryLayout<SurfaceLabelDrawUniform>.offset(of: \.haloPass),
            MemoryLayout<SurfaceLabelDrawUniform>.offset(of: \.tileUnitsPerPoint),
            MemoryLayout<SurfaceLabelDrawUniform>.offset(of: \.viewportSizePx),
            MemoryLayout<SurfaceLabelDrawUniform>.offset(of: \.pixelsPerPoint),
            MemoryLayout<SurfaceLabelDrawUniform>.offset(of: \.haloSoftness),
        ])
    }

    func testTheTreesMatchTheirSwiftTwins() throws {
        let trees = "Tile/Shaders/Trees.wgsl"
        try assertLayout("TreeInstance", in: trees, matches: TreeInstance.self, offsets: [
            MemoryLayout<TreeInstance>.offset(of: \.position),
            MemoryLayout<TreeInstance>.offset(of: \.height),
            MemoryLayout<TreeInstance>.offset(of: \.packed),
        ])
        try assertLayout("TreeTile", in: trees, matches: TreeTileUniform.self, offsets: [
            MemoryLayout<TreeTileUniform>.offset(of: \.modelMatrix),
            MemoryLayout<TreeTileUniform>.offset(of: \.heightScale),
            MemoryLayout<TreeTileUniform>.offset(of: \.padding),
        ])
        try assertLayout("TreeFrame", in: trees, matches: TreeFrameUniform.self, offsets: [
            MemoryLayout<TreeFrameUniform>.offset(of: \.lightDirection),
            MemoryLayout<TreeFrameUniform>.offset(of: \.crownColor),
            MemoryLayout<TreeFrameUniform>.offset(of: \.crownShadeColor),
            MemoryLayout<TreeFrameUniform>.offset(of: \.trunkColor),
            MemoryLayout<TreeFrameUniform>.offset(of: \.crown),
        ])
    }

    func testTheGroundMatchesItsSwiftTwins() throws {
        let shading = "Tile/Shaders/TileShading.wgsl"
        try assertLayout("Style", in: shading, matches: TilePolygonStyle.self, offsets: [
            MemoryLayout<TilePolygonStyle>.offset(of: \.color),
        ])
        try assertLayout("LineStyle", in: shading, matches: TileLineStyle.self, offsets: [
            MemoryLayout<TileLineStyle>.offset(of: \.widthPoints),
            MemoryLayout<TileLineStyle>.offset(of: \.dashLengthPoints),
            MemoryLayout<TileLineStyle>.offset(of: \.dashGapPoints),
            MemoryLayout<TileLineStyle>.offset(of: \.edgeThreshold),
            MemoryLayout<TileLineStyle>.offset(of: \.minimumWidthPoints),
            MemoryLayout<TileLineStyle>.offset(of: \.dashInTileUnits),
            MemoryLayout<TileLineStyle>.offset(of: \.halfWidthUnits),
            MemoryLayout<TileLineStyle>.offset(of: \.worldLockZoom),
            MemoryLayout<TileLineStyle>.offset(of: \.rampStartWidthPoints),
            MemoryLayout<TileLineStyle>.offset(of: \.rampStartZoom),
            MemoryLayout<TileLineStyle>.offset(of: \.rampEndZoom),
            MemoryLayout<TileLineStyle>.offset(of: \.rampStartAlpha),
            MemoryLayout<TileLineStyle>.offset(of: \.sphereAlpha),
            MemoryLayout<TileLineStyle>.offset(of: \.sphereColorRed),
            MemoryLayout<TileLineStyle>.offset(of: \.sphereColorGreen),
            MemoryLayout<TileLineStyle>.offset(of: \.sphereColorBlue),
            MemoryLayout<TileLineStyle>.offset(of: \.sphereLookUntilZoom),
        ])
        try assertLayout("OverviewFadeUniform", in: shading, matches: TileOverviewFadeUniform.self, offsets: [
            MemoryLayout<TileOverviewFadeUniform>.offset(of: \.pixelsPerPoint),
            MemoryLayout<TileOverviewFadeUniform>.offset(of: \.cameraZoom),
            MemoryLayout<TileOverviewFadeUniform>.offset(of: \.viewportSizePx),
            MemoryLayout<TileOverviewFadeUniform>.offset(of: \.pointWidthReferenceDepth),
            MemoryLayout<TileOverviewFadeUniform>.offset(of: \.pointWidthCentrePixelsPerWorldUnit),
            MemoryLayout<TileOverviewFadeUniform>.offset(of: \.groundAxisXClipX),
            MemoryLayout<TileOverviewFadeUniform>.offset(of: \.groundAxisXClipY),
            MemoryLayout<TileOverviewFadeUniform>.offset(of: \.groundAxisXClipW),
            MemoryLayout<TileOverviewFadeUniform>.offset(of: \.groundAxisYClipX),
            MemoryLayout<TileOverviewFadeUniform>.offset(of: \.groundAxisYClipY),
            MemoryLayout<TileOverviewFadeUniform>.offset(of: \.groundAxisYClipW),
        ])
        try assertLayout("LineDashUniform", in: shading, matches: LineDashUniform.self, offsets: [
            MemoryLayout<LineDashUniform>.offset(of: \.unitsPerPoint),
        ])
        try assertLayout("FlatDepthBand", in: "Tile/Shaders/Tile.wgsl", matches: FlatDepthBand.self, offsets: [
            MemoryLayout<FlatDepthBand>.offset(of: \.offset),
            MemoryLayout<FlatDepthBand>.offset(of: \.rankStep),
        ])
        try assertLayout("GroundReliefUniform", in: "Tile/Relief/Shaders/GroundRelief.wgsl", matches: GroundReliefUniform.self, offsets: [
            MemoryLayout<GroundReliefUniform>.offset(of: \.placement),
            MemoryLayout<GroundReliefUniform>.offset(of: \.frame),
            MemoryLayout<GroundReliefUniform>.offset(of: \.hillshadeLight),
            MemoryLayout<GroundReliefUniform>.offset(of: \.hillshadeShadowColor),
            MemoryLayout<GroundReliefUniform>.offset(of: \.hillshadeHighlightColor),
            MemoryLayout<GroundReliefUniform>.offset(of: \.hillshadeEye),
            MemoryLayout<GroundReliefUniform>.offset(of: \.hillshadeFade),
            MemoryLayout<GroundReliefUniform>.offset(of: \.shading),
            MemoryLayout<GroundReliefUniform>.offset(of: \.occlusion),
        ])
        let sphere = "Tile/Shaders/TileSphere.wgsl"
        try assertLayout("GlobeSurfaceTile", in: sphere, matches: GlobeSurfaceTileUniform.self, offsets: [
            MemoryLayout<GlobeSurfaceTileUniform>.offset(of: \.uvOrigin),
            MemoryLayout<GlobeSurfaceTileUniform>.offset(of: \.uvScale),
            MemoryLayout<GlobeSurfaceTileUniform>.offset(of: \.referenceWorldX),
        ])
        try assertLayout("SphereHandoverUniform", in: sphere, matches: TileSphereHandoverUniform.self, offsets: [
            MemoryLayout<TileSphereHandoverUniform>.offset(of: \.handover),
        ])
        let raster = "Tile/Shaders/TileRaster.wgsl"
        try assertLayout("TileRasterSampling", in: raster, matches: RasterTileSamplingUniform.self, offsets: [
            MemoryLayout<RasterTileSamplingUniform>.offset(of: \.mipLevelBias),
        ])
        try assertLayout("TileRasterSurfaceTile", in: raster, matches: GlobeSurfaceTileUniform.self, offsets: [
            MemoryLayout<GlobeSurfaceTileUniform>.offset(of: \.uvOrigin),
            MemoryLayout<GlobeSurfaceTileUniform>.offset(of: \.uvScale),
            MemoryLayout<GlobeSurfaceTileUniform>.offset(of: \.referenceWorldX),
        ])
    }

    func testTheHorizonMatchesItsSwiftTwin() throws {
        try assertLayout("Horizon", in: "Horizon/Shaders/Horizon.wgsl", matches: HorizonUniform.self, offsets: [
            MemoryLayout<HorizonUniform>.offset(of: \.up),
            MemoryLayout<HorizonUniform>.offset(of: \.depression),
            MemoryLayout<HorizonUniform>.offset(of: \.center),
            MemoryLayout<HorizonUniform>.offset(of: \.sunInfluence),
            MemoryLayout<HorizonUniform>.offset(of: \.light),
            MemoryLayout<HorizonUniform>.offset(of: \.skyStrength),
            MemoryLayout<HorizonUniform>.offset(of: \.tint),
            MemoryLayout<HorizonUniform>.offset(of: \.whitenWeight),
            MemoryLayout<HorizonUniform>.offset(of: \.eye),
            MemoryLayout<HorizonUniform>.offset(of: \.featherStrength),
            MemoryLayout<HorizonUniform>.offset(of: \.bandRadians),
            MemoryLayout<HorizonUniform>.offset(of: \.glowRadians),
            MemoryLayout<HorizonUniform>.offset(of: \.whitenRadians),
            MemoryLayout<HorizonUniform>.offset(of: \.featherRadians),
            MemoryLayout<HorizonUniform>.offset(of: \.groundBandRadians),
            MemoryLayout<HorizonUniform>.offset(of: \.groundGain),
            MemoryLayout<HorizonUniform>.offset(of: \.cutoffStartRadians),
            MemoryLayout<HorizonUniform>.offset(of: \.cutoffEndRadians),
            MemoryLayout<HorizonUniform>.offset(of: \.skyColor),
            MemoryLayout<HorizonUniform>.offset(of: \.skyOpacity),
            MemoryLayout<HorizonUniform>.offset(of: \.skyGradientRadians),
            MemoryLayout<HorizonUniform>.offset(of: \.viewProjection),
            MemoryLayout<HorizonUniform>.offset(of: \.bandTopRadians),
        ])
    }

    func testTheLayersMatchTheirSwiftTwins() throws {
        let layers = "Layers/Shaders/Layers.wgsl"
        try assertLayout("LayerFillVertex", in: layers, matches: LayerFillVertex.self, offsets: [
            MemoryLayout<LayerFillVertex>.offset(of: \.position),
            MemoryLayout<LayerFillVertex>.offset(of: \.color),
        ])
        try assertLayout("LayerLineVertex", in: layers, matches: LayerLineVertex.self, offsets: [
            MemoryLayout<LayerLineVertex>.offset(of: \.start),
            MemoryLayout<LayerLineVertex>.offset(of: \.end),
            MemoryLayout<LayerLineVertex>.offset(of: \.corner),
            MemoryLayout<LayerLineVertex>.offset(of: \.widthPoints),
            MemoryLayout<LayerLineVertex>.offset(of: \.color),
        ])
        try assertLayout("LayerPointInstance", in: layers, matches: LayerPointInstance.self, offsets: [
            MemoryLayout<LayerPointInstance>.offset(of: \.position),
            MemoryLayout<LayerPointInstance>.offset(of: \.radiusPoints),
            MemoryLayout<LayerPointInstance>.offset(of: \.strokeWidthPoints),
            MemoryLayout<LayerPointInstance>.offset(of: \.color),
            MemoryLayout<LayerPointInstance>.offset(of: \.strokeColor),
        ])
        try assertLayout("LayerDraw", in: layers, matches: LayerDrawUniform.self, offsets: [
            MemoryLayout<LayerDrawUniform>.offset(of: \.modelMatrix),
            MemoryLayout<LayerDrawUniform>.offset(of: \.uvOrigin),
            MemoryLayout<LayerDrawUniform>.offset(of: \.uvScale),
            MemoryLayout<LayerDrawUniform>.offset(of: \.referenceWorldX),
            MemoryLayout<LayerDrawUniform>.offset(of: \.viewportSizePx),
            MemoryLayout<LayerDrawUniform>.offset(of: \.pixelsPerPoint),
            MemoryLayout<LayerDrawUniform>.offset(of: \.depth),
        ])
    }

    func testAPlainVec3MovesTheFieldAfterIt() throws {
        // The rule the shared structs' @size(16) is for: without it, WGSL
        // puts the next field at 12 bytes past a vec3f, Swift at 16.
        let plain = try WGSLSources.layouts(in: "struct A { e: vec3f, p: f32, }")["A"]
        XCTAssertEqual(plain?.members.map(\.offset), [0, 12])
        let sized = try WGSLSources.layouts(in: "struct A { @size(16) e: vec3f, p: f32, }")["A"]
        XCTAssertEqual(sized?.members.map(\.offset), [0, 16])
        XCTAssertEqual(sized?.size, 32, "Rounded to the vec3f's alignment of 16")
    }
}
