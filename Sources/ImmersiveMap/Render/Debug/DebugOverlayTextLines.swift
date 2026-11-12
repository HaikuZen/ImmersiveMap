// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PortableFoundation

/// The debug overlay's text, apart from its drawing (`DebugOverlayRenderer`),
/// so the HUD snapshot that reads it builds everywhere.
enum DebugOverlayTextLines {
    /// Fixed decimals, the same in every locale (FoundationEssentials has
    /// no number format styles).
    static func makeCoordinateTextLines(zoom: Double,
                                        latitude: Double,
                                        longitude: Double) -> (zoom: String, latLon: String) {
        let zoomLine = "z: \(String(fixed: zoom, fractionDigits: 2))"
        let latText = String(fixed: latitude, fractionDigits: 3)
        let lonText = String(fixed: longitude, fractionDigits: 3)
        return (zoom: zoomLine, latLon: "lat: \(latText) lon: \(lonText)")
    }

    static func makeOverlayDiagnosticsTextLines(cameraDebugLines: [String],
                                                diagnostics: FrameDiagnostics?,
                                                memorySnapshot: ProcessMemorySnapshot? = ProcessMemoryReader.current()) -> [String] {
        guard let diagnostics else {
            return cameraDebugLines
        }
        var lines: [String] = []
        appendSection(title: "Camera", body: cameraDebugLines, into: &lines)
        appendDiagnosticsSections(from: diagnostics,
                                  memorySnapshot: memorySnapshot,
                                  into: &lines)
        return lines
    }

    private static func appendDiagnosticsSections(from diagnostics: FrameDiagnostics,
                                                  memorySnapshot: ProcessMemorySnapshot?,
                                                  into lines: inout [String]) {
        let hasKnownFrameDelta = diagnostics.frameDeltaTime.isFinite && diagnostics.frameDeltaTime > 0
        let frameTimeText = hasKnownFrameDelta
            ? "\(String(format: "%.2f", diagnostics.frameDeltaTime * 1000.0))ms"
            : "--"
        let fpsText = hasKnownFrameDelta
            ? String(format: "%.1f", 1.0 / diagnostics.frameDeltaTime)
            : "--"
        // One value a line in every section, so a reader finds the one
        // they watch.
        var frameLines = ["frame:\(diagnostics.frameIndex)", "dt:\(frameTimeText)", "fps:\(fpsText)"]
        let gpuFrameMs = diagnostics.measurementValue(.gpuFrameDurationMs)
        if gpuFrameMs > 0 {
            frameLines.append("gpu:\(String(format: "%.2f", gpuFrameMs))ms")
        }
        if let memorySnapshot {
            frameLines.append("memory ram:\(String(format: "%.1f", memorySnapshot.physicalFootprintMegabytes))MB")
        }
        appendSection(title: "Frame", body: frameLines, into: &lines)

        let tileLines = ["vis:\(diagnostics.counterValue(.visibleTiles))",
                         "ready:\(diagnostics.counterValue(.readyTiles))",
                         "req:\(diagnostics.counterValue(.requestedTiles))",
                         "draw:\(diagnostics.counterValue(.renderedTiles))"]
        appendSection(title: "Tiles", body: tileLines, into: &lines)

        let labelLines = ["base:\(diagnostics.counterValue(.baseLabelCount))",
                          "roadG:\(diagnostics.counterValue(.roadLabelGlyphCount))",
                          "roadI:\(diagnostics.counterValue(.roadLabelInstanceCount))",
                          "roadCull:\(diagnostics.counterValue(.roadLabelNearCameraCulledPathCount))/"
                              + "\(diagnostics.counterValue(.roadLabelNearCameraCulledAnchorCount))"]
        appendSection(title: "Labels", body: labelLines, into: &lines)

        // The frame's CPU time by subsystem (update plus prepareGPU), the
        // heaviest first: where a slow frame's milliseconds go.
        let cpuLines = diagnostics.subsystemDurations
            .sorted { lhs, rhs in lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key }
            .prefix(4)
            .map { "\($0.key):\(String(format: "%.2f", $0.value * 1000.0))" }
        appendSection(title: "CPU ms", body: Array(cpuLines), into: &lines)

        let resourcesLines = ["buffers:\(diagnostics.counterValue(.resourceBufferCount))",
                              "textures:\(diagnostics.counterValue(.resourceTextureCount))",
                              "pipelines:\(diagnostics.counterValue(.resourcePipelineCount))"]
        appendSection(title: "Resources", body: resourcesLines, into: &lines)

        let globeCullingMs = String(format: "%.2f", diagnostics.measurementValue(.globeCullingDurationMs))
        let globeCullingLines = ["ms:\(globeCullingMs)",
                                 "nodes:\(diagnostics.counterValue(.globeCullingVisitedNodes))",
                                 "frustum:\(diagnostics.counterValue(.globeCullingFrustumRejects))",
                                 "horizon:\(diagnostics.counterValue(.globeCullingHorizonRejects))",
                                 "placed:\(diagnostics.counterValue(.globeCullingPlacedTiles))",
                                 "subtree:\(diagnostics.counterValue(.globeCullingAcceptedWholeSubtrees))"]
        appendSection(title: "Globe culling", body: globeCullingLines, into: &lines)

        let skipBody: String
        if diagnostics.skipReasons.isEmpty {
            skipBody = "none"
        } else {
            let reasons = diagnostics.skipReasons.map(\.rawValue).sorted().joined(separator: ",")
            skipBody = reasons
        }
        appendSection(title: "Skip", body: [skipBody], into: &lines)
    }

    private static func appendSection(title: String, body: [String], into lines: inout [String]) {
        guard body.isEmpty == false else { return }
        if lines.isEmpty == false {
            lines.append("")
        }
        lines.append("[\(title)]")
        lines.append(contentsOf: body)
    }
}
