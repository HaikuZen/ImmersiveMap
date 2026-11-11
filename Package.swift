// swift-tools-version: 6.1

import PackageDescription

// The engine draws with Metal and its views are SwiftUI, so the products
// exist on Apple's platforms only. The targets under them that know nothing
// of either (the tile formats, the geometry tools) build everywhere, and off
// Apple's platforms the package is those targets and their tests, with two
// more that stand in for modules only Apple's SDKs have: `simd` and `os`.
//
// A manifest cannot ask which platform it is built for, only which one it is
// read on, so a Linux machine gets the portable package by itself and a Mac
// building for another platform (WebAssembly, say) asks for it with
// IMMERSIVE_MAP_PORTABLE=1.
#if canImport(Darwin)
let readOnApplePlatform = true
#else
let readOnApplePlatform = false
#endif
let portable = !readOnApplePlatform || Context.environment["IMMERSIVE_MAP_PORTABLE"] == "1"

// A build that ships to a browser must not link the platform's Foundation
// (the reason and the cost are in PortableFoundation.swift). It is asked for
// with IMMERSIVE_MAP_SLIM=1, and the XCTest targets, which cannot be built
// without Foundation, are left out of it. `PortableFoundationTests` stays:
// it is what tests the slim build's own geometry types.
let slim = portable && Context.environment["IMMERSIVE_MAP_SLIM"] == "1"

// The targets every platform builds.
var targets: [Target] = [
    // What a portable target imports in place of Foundation: Foundation on
    // Apple's platforms, FoundationEssentials and the C library elsewhere
    // (the reason is in the file).
    .target(
        name: "PortableFoundation",
        swiftSettings: slim ? [.define("PORTABLE_FOUNDATION_OWN_GEOMETRY")] : []
    ),
    // A PNG decoder for the platforms without ImageIO (terrain tiles off
    // Apple's platforms), over PMTiles' inflate.
    .target(
        name: "PortableImage",
        dependencies: ["PMTiles", "PortableFoundation"]
    ),
    // The GPU the engine draws with, as protocols and values a backend
    // conforms to (Metal on Apple's platforms, WebGPU elsewhere), shaped
    // after what the engine does with Metal. Nothing uses it yet: the
    // features move onto it one folder at a time.
    .target(
        name: "ImmersiveMapGPU"
    ),
    // A GPU that draws nothing and logs the calls, for the tests of the
    // features' drawing on any platform.
    .target(
        name: "ImmersiveMapGPUTestSupport",
        dependencies: ["ImmersiveMapGPU"]
    ),
    // The ear-clipping triangulator, a port of mapbox/earcut. Its own
    // module so the algorithm depends on nothing in the engine and the
    // engine reaches it through one entry point at `package` access,
    // so nothing of it leaks to an app that links the product.
    .target(
        name: "Earcut"
    ),
    // The Mapbox Vector Tile decoder: the wire format, the decoded model
    // and the tile-space geometry it produces. Its own module for the same
    // reason, everything at `package` access. `TestSupport` is the
    // test-side encoder and fixture tiles both test targets share; it is
    // a regular target because test targets cannot share sources.
    .target(
        name: "Mvt",
        dependencies: ["PortableFoundation"]
    ),
    .target(
        name: "MvtTestSupport",
        dependencies: ["Mvt", "PortableFoundation"]
    ),
    // The PMTiles v3 reader: the format (the header, the directories,
    // the Hilbert tile id and the gzip step, pure functions over bytes)
    // and the HTTP range client that reads an archive with them. Its own
    // module for the same reason as `Earcut`: a tool that knows nothing
    // of the engine, reached at `package` access. The test support target
    // is the independent archive writer both test targets share.
    .target(
        name: "PMTiles",
        dependencies: ["PortableFoundation"]
    ),
    .target(
        name: "PMTilesTestSupport",
        dependencies: ["PMTiles", "PortableFoundation"]
    ),
    // The ground flattener: stacked painted rings in, one layer of
    // triangles that do not overlap out, cut to a grid for a heightmap.
    // Its own module for the same reason as `Earcut`: pure geometry that
    // knows nothing of the engine, reached at `package` access.
    .target(
        name: "TileFlattening",
        dependencies: ["PortableFoundation"]
    ),
    .testTarget(
        name: "EarcutTests",
        dependencies: ["Earcut"],
        resources: [.copy("Fixtures")]
    ),
    .testTarget(
        name: "MvtTests",
        dependencies: ["Mvt", "MvtTestSupport"]
    ),
    .testTarget(
        name: "TileFlatteningTests",
        dependencies: ["TileFlattening"]
    ),
    .testTarget(
        name: "PMTilesTests",
        dependencies: ["PMTiles", "PMTilesTestSupport"]
    ),
    .testTarget(
        name: "PortableFoundationTests",
        dependencies: ["PortableFoundation"]
    ),
    // PortableFoundation's stand-ins against Foundation's own answers, where
    // there is a Foundation to ask (not in a slim build).
    .testTarget(
        name: "ImmersiveMapGPUTests",
        dependencies: ["ImmersiveMapGPU", "ImmersiveMapGPUTestSupport"]
    ),
    .testTarget(
        name: "PortableImageTests",
        dependencies: ["PortableImage"]
    ),
    .testTarget(
        name: "PortableFoundationParityTests",
        dependencies: ["PortableFoundation"]
    ),
    // The vector, matrix and quaternion functions the engine takes from
    // `simd`, by known answers. On Apple's platforms the tests run against
    // Apple's module and off them against the stand-in, so the two are held
    // to the same answers.
    .testTarget(
        name: "SimdTests",
        dependencies: portable ? ["simd"] : []
    ),
    // The same for `os`: the lock, the logger and the signposter.
    .testTarget(
        name: "OSTests",
        dependencies: portable ? ["os"] : []
    )
]

if slim {
    targets.removeAll { $0.isTest && ["PortableFoundationTests", "PortableImageTests", "ImmersiveMapGPUTests"].contains($0.name) == false }
}

if portable {
    targets += [
        // The stand-in for Apple's `simd` module, under its name, so the
        // sources that write `import simd` compile unchanged.
        .target(
            name: "simd"
        ),
        // The same for Apple's `os` module: the logger, the signposter and
        // the unfair lock.
        .target(
            name: "os"
        )
    ]
} else {
    targets += [
        // The GPU interface (`ImmersiveMapGPU`) over Metal: thin wrappers that
        // forward each call to the Metal object they hold.
        .target(
            name: "ImmersiveMapMetal",
            dependencies: ["ImmersiveMapGPU"]
        ),
        .testTarget(
            name: "ImmersiveMapMetalTests",
            dependencies: ["ImmersiveMapGPU", "ImmersiveMapMetal"]
        ),
        .target(
            name: "ImmersiveMap",
            dependencies: ["Earcut", "ImmersiveMapGPU", "ImmersiveMapMetal", "Mvt", "PMTiles", "PortableFoundation", "PortableImage", "TileFlattening"],
            // The shaders and their headers: not resources, so no build
            // system makes a library of its own from them. `MetalLibraryPlugin`
            // compiles every .metal file of the target into the one
            // default.metallib of the resource bundle, under Xcode and under
            // `swift build` alike. A new shader folder goes here.
            exclude: [
                "Avatars/Shaders",
                "Globe/Shaders",
                "Horizon/Shaders",
                "Labels/Shaders",
                "Layers/Shaders",
                "Render/Debug/Shaders",
                "Render/PostProcessing/Shaders",
                "Render/Shaders",
                "SceneModels/Shaders",
                "Shadows/Shaders",
                "Starfield/Shaders",
                "Text/Shaders",
                "Tile/Relief/Shaders",
                "Tile/Shaders",
            ],
            resources: [
                .process("Avatars/Resources/avatar_marker_sdf.json"),
                .process("Avatars/Resources/avatar_marker_sdf.png"),
                .process("Text/Resources"),
                // The overview of the globe laid into the tiles of zooms 0 to 5
                // (`OverviewTileSource`): copied whole, a PMTiles archive.
                .copy("Tile/Overview/Resources/overview.pmtiles"),
                // The tree model the woods and the parks stand
                // (`TreeModelContents`): copied whole, as the GPU reads it.
                .copy("Tile/Trees/Resources/tree_broadleaf.immtree"),
            ],
            plugins: ["MetalLibraryPlugin"]
        ),
        // Compiles the engine's shaders into its resource bundle's
        // default.metallib with `xcrun metal`, the same way for Xcode and for
        // SwiftPM's command line, which on its own copies .metal files into
        // the bundle uncompiled.
        .plugin(
            name: "MetalLibraryPlugin",
            capability: .buildTool()
        ),
        // The debug panel over the map (`ImmersiveMapDebugPanel.hud`). The
        // engine holds what the panel reads and drags and the slot it fills,
        // at `package` access, and this target fills it from outside, so an
        // app that links `ImmersiveMap` alone compiles none of the panel.
        .target(
            name: "ImmersiveMapDebug",
            dependencies: ["ImmersiveMap"]
        ),
        .testTarget(
            name: "ImmersiveMapTests",
            dependencies: ["ImmersiveMap", "ImmersiveMapDebug", "ImmersiveMapGPU", "ImmersiveMapGPUTestSupport", "Mvt", "MvtTestSupport", "PMTilesTestSupport"]
        )
    ]
}

let package = Package(
    name: "ImmersiveMap",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: portable ? [] : [
        .library(
            name: "ImmersiveMap",
            targets: ["ImmersiveMap"]
        ),
        // The debug panel, apart from the engine: linked by a development
        // app and the tests, never by a shipping app, which carries nothing
        // of it.
        .library(
            name: "ImmersiveMapDebug",
            targets: ["ImmersiveMapDebug"]
        )
    ],
    targets: targets,
    swiftLanguageModes: [.v6]
)
