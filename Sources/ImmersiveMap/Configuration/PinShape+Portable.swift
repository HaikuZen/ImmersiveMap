// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// The pins' shape where there is no Core Graphics: the pins are drawn on
// Apple's platforms alone (`Pins/` is left out of the portable engine,
// PortableEngineExclusions.txt), where `PinShape` holds Core Graphics paths
// and images. Elsewhere the settings still carry a shape
// (`ImmersiveMapSettings.PinSettings.shape`), and this is it: a value with
// the one shape they name, drawn by nothing.

#if !canImport(CoreGraphics)
public struct PinShape: Equatable, Sendable {
    /// The settings' default, the built-in bubble on Apple's platforms.
    public static let bubble = PinShape()
}
#endif
