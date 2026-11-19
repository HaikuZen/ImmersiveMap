// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import PortableFoundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public struct PinImageSource: Sendable {
    private enum Storage: Sendable {
        case image(PinImage)
        case remote(URL, placeholder: PinImage?)
    }

    private let storage: Storage

    public var remoteURL: URL? {
        switch storage {
        case .image:
            return nil
        case .remote(let url, placeholder: _):
            return url
        }
    }

    var initialImage: PinImage {
        switch storage {
        case .image(let image):
            return image
        case .remote(_, let placeholder):
            return placeholder ?? PinImage.defaultPlaceholder
        }
    }

    /// A picture the app already has.
    public static func image(_ image: PinImage) -> PinImageSource {
        PinImageSource(storage: .image(image))
    }

    /// A picture loaded from `url`, with `placeholder` (or the built-in one)
    /// shown until it loads.
    public static func remote(_ url: URL, placeholder: PinImage? = nil) -> PinImageSource {
        PinImageSource(storage: .remote(url, placeholder: placeholder))
    }

    #if canImport(CoreGraphics)
    public static func cgImage(_ image: CGImage) -> PinImageSource {
        .image(PinImage(cgImage: image))
    }

    public static func remote(_ url: URL, placeholder: CGImage?) -> PinImageSource {
        .remote(url, placeholder: placeholder.map { PinImage(cgImage: $0) })
    }
    #endif
}
