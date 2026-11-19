// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
import ImmersiveMapGPU
import ImmersiveMapGPUTestSupport
@testable import ImmersiveMap
import Testing

/// The frame engine over a device that is not Metal (`RenderHost.portable`),
/// as the browser program drives it: made, and its frames scheduled one
/// after another, so the frame slots come back as the GPU completes them.
/// The recording GPU completes at once and draws nothing, and no tile reaches
/// the map.
@MainActor
struct PortableMapRendererTests {
    /// The engine loads its tree model from its resources folder when it
    /// starts, and stops a debug build where there is none, as in the
    /// portable package, which has no resources of its own. Where no folder
    /// is found, one of the tests' own holds the model and the pins'
    /// bubble, named by the variable the engine reads, made once for the
    /// run. The other lookups of the run find the same files there or none,
    /// as before.
    private static let resources: Void = {
        guard (try? ImmersiveMapResourceBundle.location()) == nil else { return }
        let engine = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ImmersiveMap")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortableMapRendererTests-\(UUID().uuidString)", isDirectory: true)
        let files = ["Tile/Trees/Resources/\(TreeModelStore.resourceName).\(TreeModelStore.resourceExtension)",
                     "Pins/Resources/\(PinSDFResource.baseName).png",
                     "Pins/Resources/\(PinSDFResource.baseName).json"]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in files {
                let source = engine.appendingPathComponent(file)
                try Data(contentsOf: source).write(to: folder.appendingPathComponent(source.lastPathComponent))
            }
        } catch {
            Issue.record("The tests' resources folder could not be made: \(error)")
        }
        setenv(ImmersiveMapResourceBundle.directoryEnvironmentVariable, folder.path, 1)
    }()

    init() {
        Self.resources
    }

    /// No network: the archive on a port nothing listens on, no model
    /// archive, no disk cache.
    private static func offlineSettings() -> ImmersiveMapSettings {
        var settings = ImmersiveMapSettings.default.tileArchive(URL(string: "http://127.0.0.1:1/planet.pmtiles")!)
        settings.modelArchive.archiveURL = nil
        settings.tiles.cache.preparedTileCacheEnabled = false
        return settings
    }

    @Test func framesAreScheduledOnAnotherDevice() throws {
        let device = RecordingGPUDevice()
        let map = try PortableMapRenderer(device: device, settings: Self.offlineSettings())
        var descriptor = GPUTextureDescriptor(format: .bgra8Unorm, width: 64, height: 48)
        descriptor.usage = [.renderTarget]
        let target = try #require(device.makeTexture(descriptor))
        // More frames than the engine keeps in flight.
        for _ in 0 ..< 5 {
            #expect(map.render(into: target, width: 64, height: 48, pixelsPerPoint: 1))
        }
    }

    @Test func cameraMovesBetweenFrames() throws {
        let device = RecordingGPUDevice()
        let map = try PortableMapRenderer(device: device, settings: Self.offlineSettings())
        var descriptor = GPUTextureDescriptor(format: .bgra8Unorm, width: 64, height: 48)
        descriptor.usage = [.renderTarget]
        let target = try #require(device.makeTexture(descriptor))
        map.setCamera(latitudeDegrees: 45.46, longitudeDegrees: 9.19, zoom: 12)
        #expect(map.render(into: target, width: 64, height: 48, pixelsPerPoint: 2))
        let start = map.cameraPosition
        #expect(abs(start.latitudeDegrees - 45.46) < 1e-6)
        #expect(abs(start.zoom - 12) < 1e-6)

        map.pan(deltaX: 30, deltaY: -10)
        map.endPan()
        let panned = map.cameraPosition
        #expect(panned.longitudeDegrees != start.longitudeDegrees)
        map.zoom(delta: 1)
        #expect(map.cameraPosition.zoom > panned.zoom)
        map.rotate(yaw: 0.3)
        #expect(map.cameraPosition.bearing != start.bearing)
        map.tilt(by: 0.4)
        #expect(map.cameraPosition.pitch > start.pitch)
        #expect(map.render(into: target, width: 64, height: 48, pixelsPerPoint: 2))
    }

    @Test func aFrameRequestIsTakenOnce() {
        var demand = PortableFrameDemand()
        // A new map has never drawn.
        let first = demand.take()
        let second = demand.take()
        #expect(first)
        #expect(second == false)
        demand.request()
        demand.request()
        #expect(demand.isRequested)
        let third = demand.take()
        #expect(third)
        #expect(demand.isRequested == false)
    }

    /// The pins are the engine's, as on Apple's platforms: their pipelines
    /// are made with the map, and a pin where the camera looks puts its
    /// picture in the pins' atlas when a frame is drawn.
    @Test func thePinsAreDrawnByTheEngine() throws {
        let device = RecordingGPUDevice()
        let map = try PortableMapRenderer(device: device, settings: Self.offlineSettings())
        #expect(device.pipelines.contains { $0.vertexFunction.name == "pinVertex" })
        var descriptor = GPUTextureDescriptor(format: .bgra8Unorm, width: 64, height: 48)
        descriptor.usage = [.renderTarget]
        let target = try #require(device.makeTexture(descriptor))
        map.setCamera(latitudeDegrees: 45.46, longitudeDegrees: 9.19, zoom: 4)
        let picture = PinImage(width: 2, height: 2, premultipliedBGRA: [UInt8](repeating: 255, count: 16))
        map.pinsController.add(ImmersiveMapPin(id: 1, coordinate: GeoCoordinate(latitude: 45.46, longitude: 9.19),
                                               image: picture))
        #expect(map.render(into: target, width: 64, height: 48, pixelsPerPoint: 2))
        #expect(device.textures.contains { $0.descriptor.label == "PinAtlas" })
    }

    /// A pin added, changed or removed asks for a frame, as the camera does.
    @Test func aPinChangeAsksForAFrame() throws {
        let device = RecordingGPUDevice()
        let map = try PortableMapRenderer(device: device, settings: Self.offlineSettings())
        var descriptor = GPUTextureDescriptor(format: .bgra8Unorm, width: 64, height: 48)
        descriptor.usage = [.renderTarget]
        let target = try #require(device.makeTexture(descriptor))
        // Frames until the map is still: the first frames start the tiles'
        // and the labels' work.
        for _ in 0 ..< 10 where map.needsFrame(width: 64, height: 48, pixelsPerPoint: 2) {
            map.render(into: target, width: 64, height: 48, pixelsPerPoint: 2)
        }
        #expect(map.needsFrame(width: 64, height: 48, pixelsPerPoint: 2) == false)
        let picture = PinImage(width: 2, height: 2, premultipliedBGRA: [UInt8](repeating: 255, count: 16))
        map.pinsController.add(ImmersiveMapPin(id: 1, coordinate: GeoCoordinate(latitude: 10, longitude: 20),
                                               image: picture))
        #expect(map.needsFrame(width: 64, height: 48, pixelsPerPoint: 2))
    }

    @Test func aNewMapAndANewSizeNeedAFrame() throws {
        let device = RecordingGPUDevice()
        let map = try PortableMapRenderer(device: device, settings: Self.offlineSettings())
        var descriptor = GPUTextureDescriptor(format: .bgra8Unorm, width: 64, height: 48)
        descriptor.usage = [.renderTarget]
        let target = try #require(device.makeTexture(descriptor))
        #expect(map.needsFrame(width: 64, height: 48, pixelsPerPoint: 2))
        #expect(map.render(into: target, width: 64, height: 48, pixelsPerPoint: 2))
        #expect(map.needsFrame(width: 32, height: 48, pixelsPerPoint: 2))
        #expect(map.needsFrame(width: 64, height: 48, pixelsPerPoint: 1))
    }

    /// A marker where the camera looks straight down lands on the drawing's
    /// centre, in points, and one on the far side of the globe is left out.
    @Test func markersArePlacedWhereTheFrameProjectsThem() throws {
        let device = RecordingGPUDevice()
        let map = try PortableMapRenderer(device: device, settings: Self.offlineSettings())
        var descriptor = GPUTextureDescriptor(format: .bgra8Unorm, width: 64, height: 48)
        descriptor.usage = [.renderTarget]
        let target = try #require(device.makeTexture(descriptor))
        map.setCamera(latitudeDegrees: 45.46, longitudeDegrees: 9.19, zoom: 5)
        map.setMarker(id: 7, latitudeDegrees: 45.46, longitudeDegrees: 9.19)
        map.setMarker(id: 8, latitudeDegrees: -45.46, longitudeDegrees: -170.81)
        #expect(map.markerPositions.isEmpty)

        #expect(map.render(into: target, width: 64, height: 48, pixelsPerPoint: 2))
        let centre = try #require(map.markerPositions.first { $0.id == 7 })
        #expect(abs(centre.x - 16) < 0.5)
        #expect(abs(centre.y - 12) < 0.5)
        #expect(centre.alpha > 0)
        #expect(map.markerPositions.contains { $0.id == 8 } == false)

        map.removeMarker(id: 7)
        #expect(map.markerPositions.contains { $0.id == 7 } == false)
        #expect(map.needsFrame(width: 64, height: 48, pixelsPerPoint: 2))
    }

    /// A clock the test moves by hand.
    private final class TestClock {
        var now: Double = 100
    }

    /// A fast release on the globe glides on, the camera moving with each
    /// step of the clock and no input, and slows to a stop.
    @Test func aFastReleaseOnTheGlobeGlidesAndStops() throws {
        let clock = TestClock()
        let map = try PortableMapRenderer(device: RecordingGPUDevice(), settings: Self.offlineSettings(), clock: { clock.now })
        map.setCamera(latitudeDegrees: 45.46, longitudeDegrees: 9.19, zoom: 2)
        map.pan(deltaX: 30, deltaY: 0)
        map.endPan(velocityX: 2000, velocityY: 0)
        #expect(map.isGliding)
        #expect(map.needsFrame(width: 64, height: 48, pixelsPerPoint: 2))

        let released = map.cameraPosition.longitudeDegrees
        clock.now += 0.016
        map.advanceGlide()
        #expect(map.cameraPosition.longitudeDegrees != released)

        // The half-life and the stop velocity end it within a few seconds.
        var steps = 0
        while map.isGliding, steps < 200 {
            clock.now += 0.05
            map.advanceGlide()
            steps += 1
        }
        #expect(map.isGliding == false)
        let stopped = map.cameraPosition.longitudeDegrees
        clock.now += 0.05
        map.advanceGlide()
        #expect(map.cameraPosition.longitudeDegrees == stopped)
    }

    @Test func aSlowReleaseDoesNotGlide() throws {
        let clock = TestClock()
        let map = try PortableMapRenderer(device: RecordingGPUDevice(), settings: Self.offlineSettings(), clock: { clock.now })
        map.setCamera(latitudeDegrees: 45.46, longitudeDegrees: 9.19, zoom: 2)
        map.pan(deltaX: 5, deltaY: 0)
        map.endPan(velocityX: 100, velocityY: 0)
        #expect(map.isGliding == false)
    }

    @Test func aDragOrAZoomStopsAGlide() throws {
        let clock = TestClock()
        let map = try PortableMapRenderer(device: RecordingGPUDevice(), settings: Self.offlineSettings(), clock: { clock.now })
        map.setCamera(latitudeDegrees: 45.46, longitudeDegrees: 9.19, zoom: 2)
        map.endPan(velocityX: 2000, velocityY: 0)
        #expect(map.isGliding)
        map.pan(deltaX: 1, deltaY: 0)
        #expect(map.isGliding == false)
        map.endPan(velocityX: 2000, velocityY: 0)
        #expect(map.isGliding)
        map.zoom(delta: 0.5)
        #expect(map.isGliding == false)
    }

    /// The layout a page draws the POI icons to is the engine's own: every
    /// icon's cell where the layout puts it, in an atlas of its side.
    @Test func thePoiAtlasLayoutDescribesTheEnginesCells() throws {
        let layout = PoiSpriteAtlasLayout()
        let json = try #require(JSONSerialization.jsonObject(with: Data(PortableMapRenderer.poiAtlasLayoutDescription.utf8))
            as? [String: Any])
        #expect(json["side"] as? Int == layout.pixelSize)
        #expect(json["cellSize"] as? Int == layout.descriptor.cellSize)
        #expect(json["padding"] as? Int == layout.descriptor.cellPadding)
        #expect((json["symbolInset"] as? Double).map { abs($0 - Double(PoiSpriteAtlasLayout.symbolInsetFraction)) < 1e-9 } == true)
        let icons = try #require(json["icons"] as? [[String: Any]])
        #expect(icons.count == PoiSpriteIcon.allCases.count)
        for entry in icons {
            let icon = try #require((entry["name"] as? String).flatMap(PoiSpriteIcon.init(rawValue:)))
            let region = try #require(layout.region(for: icon))
            #expect(entry["x"] as? Int == Int(region.pixelRect.minX))
            #expect(entry["y"] as? Int == Int(region.pixelRect.minY))
        }
    }

    /// The page's atlas becomes the POI texture whole, and one of another
    /// size none: the icons are left blank rather than sampled out of place.
    @Test func thePagesPoiAtlasIsUploadedWhenItFits() throws {
        let side = PoiSpriteAtlasLayout().pixelSize
        let fitting = RecordingGPUDevice()
        _ = try PortableMapRenderer(device: fitting, settings: Self.offlineSettings(),
                                    poiAtlas: [UInt8](repeating: 255, count: side * side * 4))
        let atlas = try #require(fitting.textures.first { $0.width == side && $0.height == side })
        #expect(atlas.format == .bgra8Unorm)
        #expect(atlas.replacedRegions.count == 1)
        #expect(atlas.replacedRegions.first.map { $0.width == side && $0.height == side } == true)

        let wrong = RecordingGPUDevice()
        _ = try PortableMapRenderer(device: wrong, settings: Self.offlineSettings(), poiAtlas: [UInt8](repeating: 255, count: 16))
        #expect(wrong.textures.contains { $0.width == side && $0.height == side } == false)
    }

    /// The badge's credits are the settings' resolved attribution at the
    /// camera's zoom: the biomes' only up to the zoom they are drawn to.
    @Test func theAttributionFollowsTheCamerasZoom() throws {
        let settings = Self.offlineSettings()
        let map = try PortableMapRenderer(device: RecordingGPUDevice(), settings: settings)
        let biomesEnd = settings.tiles.overview.creditMaximumZoom
        map.setCamera(latitudeDegrees: 45.46, longitudeDegrees: 9.19, zoom: max(0, biomesEnd - 2))
        let near = map.attribution
        #expect(near.credits == settings.resolvedAttribution.credits(atZoom: map.cameraPosition.zoom).map(\.text))
        #expect(near.credits.first == ImmersiveMapAttribution.engineCredit.text)
        #expect(near.credits.contains(OverviewTileSource.creditText))
        #expect(near.linkURL == settings.resolvedAttribution.linkURL?.absoluteString)

        map.setCamera(latitudeDegrees: 45.46, longitudeDegrees: 9.19, zoom: biomesEnd + 2)
        #expect(map.attribution.credits.contains(OverviewTileSource.creditText) == false)
        #expect(map.attribution.credits.contains(ImmersiveMapTilesService.attribution.credits[0].text))
    }

    @Test func theAttributionsJSONEscapesItsText() throws {
        let attribution = PortableAttribution(credits: ["© \"Quoted\" \\ data", "line\nbreak"], linkURL: nil)
        let json = try #require(JSONSerialization.jsonObject(with: Data(attribution.json.utf8)) as? [String: Any])
        #expect(json["credits"] as? [String] == attribution.credits)
        #expect(json["link"] is NSNull)
    }

    /// A page's own attribution takes the tile source's place, as the Apple
    /// views' override does, and the engine still adds the biomes' credit.
    @Test func aPagesAttributionTakesTheTileSourcesPlace() throws {
        let json = #"{"credits":[{"text":"© City data"},{"text":"Roads © Agency","minZoom":10}],"link":"https://example.invalid/license","showsEngineCredit":false}"#
        let options = try PortableAttributionOptions(json: Data(json.utf8))
        #expect(options.credits == [ImmersiveMapAttribution.Credit("© City data"),
                                    ImmersiveMapAttribution.Credit("Roads © Agency", zoomRange: 10 ..< .infinity)])
        let settings = options.applied(to: Self.offlineSettings())
        let map = try PortableMapRenderer(device: RecordingGPUDevice(), settings: settings)
        map.setCamera(latitudeDegrees: 45.46, longitudeDegrees: 9.19, zoom: 4)
        #expect(map.attribution.credits == ["© City data", OverviewTileSource.creditText])
        #expect(map.attribution.linkURL == "https://example.invalid/license")
        map.setCamera(latitudeDegrees: 45.46, longitudeDegrees: 9.19, zoom: 12)
        #expect(map.attribution.credits == ["© City data", "Roads © Agency"])
    }

    @Test func aPagesLinkAloneKeepsTheDefaultCredit() throws {
        let options = try PortableAttributionOptions(json: Data(#"{"link":"https://example.invalid/osm"}"#.utf8))
        let settings = options.applied(to: Self.offlineSettings())
        #expect(settings.resolvedAttribution.credits.map(\.text).contains(ImmersiveMapTilesService.attribution.credits[0].text))
        #expect(settings.resolvedAttribution.linkURL?.absoluteString == "https://example.invalid/osm")
    }

    @Test func anAttributionOfAnotherShapeIsRefused() {
        for json in [#"[1]"#, #"{"credits":"© x"}"#, #"{"credits":[{"minZoom":3}]}"#,
                     #"{"credits":[{"text":"x","minZoom":5,"maxZoom":5}]}"#, #"{"showsEngineCredit":"no"}"#] {
            #expect(throws: PortableAttributionOptions.Invalid.self) {
                try PortableAttributionOptions(json: Data(json.utf8))
            }
        }
    }
}
