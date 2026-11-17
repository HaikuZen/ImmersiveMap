// Copyright (c) 2025-2026 ImmersiveMap contributors.
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
    /// is found, one of the tests' own holds the model, named by the
    /// variable the engine reads, made once for the run. The other lookups
    /// of the run find the same files there or none, as before.
    private static let resources: Void = {
        guard (try? ImmersiveMapResourceBundle.location()) == nil else { return }
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ImmersiveMap/Tile/Trees/Resources")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortableMapRendererTests-\(UUID().uuidString)", isDirectory: true)
        let name = "\(TreeModelStore.resourceName).\(TreeModelStore.resourceExtension)"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(contentsOf: sources.appendingPathComponent(name)).write(to: folder.appendingPathComponent(name))
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
}
