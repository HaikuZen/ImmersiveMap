// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapMetal
import Metal

/// Process-wide immutable GPU resources shared by every renderer instance:
/// the Metal device and its shader library, the engine's resources made
/// with them through the GPU interface (`RenderResources`, whose members
/// are read here as if they were this type's own), and what only Apple's
/// platforms make (the pins' resources, the POI icons' atlas).
///
/// A new `ImmersiveMapView` used to rebuild all of this from scratch: the
/// shader library load, ~26 pipeline states, the MSDF text atlases (two raw
/// pixel uploads and two JSON metric decodes), the POI sprite
/// rasterization, and the procedural sphere/cap geometry. None of it depends
/// on anything that varies between views but the sample count: the device is
/// the system singleton and the color format is always `bgra8Unorm`, so one
/// set per sample count serves the whole process and a second map view (or a
/// settings-driven renderer recreation) skips the entire cost.
///
/// Everything held here is immutable after creation and is safe to read from
/// any thread (Metal objects are thread-safe for use; the Swift wrappers never
/// mutate after init). The cache itself is `@MainActor` because every renderer
/// creation path already runs on the main actor; the build behind it runs
/// on a detached task (`resources(sampleCount:)`, `prewarm(sampleCount:)`),
/// so the first map view of a process, or an app that prewarms at launch,
/// never stalls the main thread on shader pipelines and atlases.
///
/// Deliberate trade-offs of process-lifetime caching:
/// - The set stays resident after the last map view goes away (the decoded
///   text atlases dominate at ~2×17 MB of private textures). That is the
///   point (the next view starts warm), but apps where the map is a rarely
///   visited screen pay the residency; a release-when-idle hook can be added
///   if that ever matters in practice.
/// - The device is resolved once. If the system default device can change
///   mid-process (Intel macOS with an external GPU), later renderers keep the
///   original device, unlike the old per-view bootstrap which re-resolved it.
@MainActor
@dynamicMemberLookup
final class SharedRenderResources {
    let device: MTLDevice
    let library: MTLLibrary
    /// The device and library as the GPU interface, the one every feature
    /// that draws through it makes its resources with.
    let gpuDevice: MetalDevice
    let renderSampleCount: Int
    /// The one color format the engine renders in; `RendererSetup` stamps it
    /// onto every view's layer.
    let colorPixelFormat: MTLPixelFormat = .bgra8Unorm
    /// The engine's resources, made through the GPU interface.
    let core: RenderResources

    // MARK: - Apple's own

    let pins: PinsRenderer.SharedResources
    let poiSpriteAtlas: PoiSpriteAtlas

    /// `core`'s members, read as this type's own (`shared.tilePipeline`).
    nonisolated subscript<Value>(dynamicMember keyPath: KeyPath<RenderResources, Value>) -> Value {
        core[keyPath: keyPath]
    }

    // MARK: - Lifecycle

    private static var cached: [Int: SharedRenderResources] = [:]
    /// The builds in progress, one per resolved sample count, so a prewarm
    /// and the first map view that arrives while it runs share one build.
    private static var inFlight: [Int: Task<SharedRenderResources, any Error>] = [:]
    /// Metal objects are thread-safe; the box carries the device into the
    /// background build under strict concurrency.
    private struct DeviceBox: @unchecked Sendable {
        let device: MTLDevice
    }
    private static let sharedDevice: DeviceBox? = MTLCreateSystemDefaultDevice().map(DeviceBox.init)

    private static func resolvedSampleCount(_ sampleCount: Int) -> (device: MTLDevice, sampleCount: Int) {
        guard let box = sharedDevice else {
            fatalError("Metal is not supported on this device")
        }
        return (box.device, RendererSetup.resolvedRenderSampleCount(requested: sampleCount, metalDevice: box.device))
    }

    /// Returns the process-wide instance for a sample count, creating it on
    /// the calling thread when nothing has built it yet. The count is the
    /// one the device can actually render with
    /// (`RendererSetup.resolvedRenderSampleCount`), so two requests the
    /// device resolves alike share one set. The synchronous path: the
    /// offscreen recorders and the tests take it; a map view goes through
    /// `resources(sampleCount:)` so the build never blocks the main thread.
    /// Throws when the engine's resources cannot be found
    /// (`ImmersiveMapResourceBundle.NotFound`, `RenderResourcesError`), and
    /// a later call tries again.
    static func shared(sampleCount: Int = 1) throws -> SharedRenderResources {
        let (device, resolved) = resolvedSampleCount(sampleCount)
        if let cached = cached[resolved] {
            return cached
        }
        let resources = SharedRenderResources(built: try Self.build(device: device, renderSampleCount: resolved))
        cached[resolved] = resources
        return resources
    }

    /// Whether `shared(sampleCount:)` would return without building.
    static func isAvailable(sampleCount: Int = 1) -> Bool {
        cached[resolvedSampleCount(sampleCount).sampleCount] != nil
    }

    /// The process-wide instance for a sample count, built off the main
    /// thread when it does not exist yet: the shader library, the pipeline
    /// states (which is where the device compiles the shaders, once per
    /// build, the system caching the binaries after that), the atlases and
    /// the geometry come together on a detached task, and only the SF
    /// Symbol sprite atlas, which rasterizes through UIImage/NSImage, is
    /// made here at the end. Concurrent callers await the same build; a
    /// synchronous `shared` call that lands in the meantime builds its own
    /// copy and wins, and the awaited build is then dropped in its favour.
    /// Throws as `shared(sampleCount:)` does, to every caller awaiting the
    /// build, and a later call tries again.
    static func resources(sampleCount: Int = 1) async throws -> SharedRenderResources {
        let (device, resolved) = resolvedSampleCount(sampleCount)
        if let cached = cached[resolved] {
            return cached
        }
        if let inFlight = inFlight[resolved] {
            return try await inFlight.value
        }
        let box = DeviceBox(device: device)
        let task = Task { @MainActor () throws -> SharedRenderResources in
            let built: Built
            do {
                built = try await Task.detached(priority: .userInitiated) {
                    try Self.build(device: box.device, renderSampleCount: resolved)
                }.value
            } catch {
                inFlight[resolved] = nil
                throw error
            }
            if let cached = cached[resolved] {
                inFlight[resolved] = nil
                return cached
            }
            let resources = SharedRenderResources(built: built)
            cached[resolved] = resources
            inFlight[resolved] = nil
            return resources
        }
        inFlight[resolved] = task
        return try await task.value
    }

    /// Builds the resources for a sample count ahead of the first map view,
    /// off the main thread; see `resources(sampleCount:)`. Returns when
    /// they are ready, or when the build failed: the map view that needs
    /// them builds again and shows the error.
    static func prewarm(sampleCount: Int = 1) async {
        _ = try? await resources(sampleCount: sampleCount)
    }

    #if DEBUG
    /// Forgets the built set for a sample count, so a test can watch it
    /// being built again. Engines holding the old set keep it.
    static func dropCachedForTesting(sampleCount: Int) {
        let resolved = resolvedSampleCount(sampleCount).sampleCount
        cached[resolved] = nil
        inFlight[resolved] = nil
    }
    #endif

    /// Everything the build makes away from the main actor: immutable
    /// GPU objects and the engine's wrappers around them.
    private struct Built: @unchecked Sendable {
        let device: MTLDevice
        let library: MTLLibrary
        let gpuDevice: MetalDevice
        let renderSampleCount: Int
        let core: RenderResources
        let pins: PinsRenderer.SharedResources
    }

    private nonisolated static func build(device: MTLDevice, renderSampleCount: Int) throws -> Built {
        // The bundle first: the text atlases and the pin are read
        // from it whichever library the shaders come from.
        let resourceBundle = try ImmersiveMapResourceBundle.bundle()
        let library = try RendererSetup.makeLibrary(metalDevice: device, bundle: resourceBundle)
        let gpuDevice = MetalDevice(device: device, library: library)
        let pixelFormat: MTLPixelFormat = .bgra8Unorm
        // Converted once, before the jobs: a format the GPU interface does
        // not name stops here, saying which, rather than in a worker.
        guard let colorFormat = GPUPixelFormat(metal: pixelFormat) else {
            fatalError("The GPU interface has no name for the color format \(pixelFormat.rawValue)")
        }
        // The engine's resources (whose pipelines compile on every core) and
        // the pins' side by side; each job writes its own variable, and
        // `concurrentPerform` returns once both finished.
        var core: RenderResources?
        var pins: PinsRenderer.SharedResources?
        nonisolated(unsafe) let jobs: [() -> Void] = [
            { core = RenderResources(device: gpuDevice,
                                     colorFormat: colorFormat,
                                     sampleCount: renderSampleCount,
                                     resource: { resourceBundle.url(forResource: $0, withExtension: $1) }) },
            { pins = PinsRenderer.SharedResources.make(metalDevice: device,
                                                          pixelFormat: pixelFormat,
                                                          library: library,
                                                          resourceBundle: resourceBundle,
                                                          sampleCount: 1) },
        ]
        DispatchQueue.concurrentPerform(iterations: jobs.count) { jobs[$0]() }
        return Built(device: device,
                     library: library,
                     gpuDevice: gpuDevice,
                     renderSampleCount: renderSampleCount,
                     core: core!,
                     pins: pins!)
    }

    private init(built: Built) {
        self.device = built.device
        self.library = built.library
        self.gpuDevice = built.gpuDevice
        self.renderSampleCount = built.renderSampleCount
        self.core = built.core
        self.pins = built.pins
        // SF Symbol rasterization goes through UIImage/NSImage and stays on
        // the main thread rather than joining the background build.
        self.poiSpriteAtlas = PoiSpriteAtlas(device: built.gpuDevice)
    }
}
