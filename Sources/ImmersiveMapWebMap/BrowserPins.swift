// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// The pins' side of the page: what Core Graphics draws on Apple's platforms
// drawn by the page with a 2D canvas (`PinPictureDrawing`), a remote
// picture loaded by the page's `fetch` and `createImageBitmap`
// (`PinRemoteImages.hostLoader`), and the pictures the page hands the
// module, kept by an id so pins that show the same one share an atlas cell.

#if arch(wasm32)
import ImmersiveMap
import PortableFoundation

/// The shape's parts, as JSON (`BrowserPins.json(of:)`), filled white on
/// black on a `side` square canvas inside `margin` (a fraction of the side)
/// by the nonzero rule: the page writes `side * side` bytes at `out`, 1
/// where a sample is at least half white. Returns 1 when it drew.
@_extern(wasm, module: "immersivemap_pins", name: "coverage")
private func hostCoverage(_ json: UnsafePointer<UInt8>?, _ jsonLength: Int32,
                          _ side: Int32, _ margin: Double,
                          _ out: UnsafeMutablePointer<UInt8>?) -> Int32

/// A merged pin's counter reading the text, `side` pixels square, as
/// `PinPictureDrawing.countBadge` describes it: the page writes
/// `side * side * 4` bytes of premultiplied BGRA at `out`. Returns 1 when
/// it drew.
@_extern(wasm, module: "immersivemap_pins", name: "badge")
private func hostBadge(_ text: UnsafePointer<UInt8>?, _ textLength: Int32,
                       _ side: Int32, _ out: UnsafeMutablePointer<UInt8>?) -> Int32

/// The placeholder, `side` pixels square, as `PinPictureDrawing.placeholder`
/// describes it, in premultiplied BGRA at `out`. Returns 1 when it drew.
@_extern(wasm, module: "immersivemap_pins", name: "placeholder")
private func hostPlaceholder(_ side: Int32, _ out: UnsafeMutablePointer<UInt8>?) -> Int32

/// Starts loading the picture at the URL. The page answers with
/// `immersivemap_pins_image_buffer` and `immersivemap_pins_image_finish`,
/// never within this call.
@_extern(wasm, module: "immersivemap_pins", name: "image")
private func hostImage(_ id: UInt32, _ url: UnsafePointer<UInt8>?, _ urlLength: Int32)

/// The page's 2D canvas as the pins' drawer.
struct BrowserPinDrawer: PinPictureDrawing {
    func coverage(of parts: [PinShapePath], side: Int, margin: Double) -> [Bool]? {
        var json = BrowserPins.json(of: parts)
        var bytes = [UInt8](repeating: 0, count: side * side)
        let drew = json.withUTF8 { json in
            bytes.withUnsafeMutableBufferPointer { out in
                hostCoverage(json.baseAddress, Int32(json.count), Int32(side), margin, out.baseAddress)
            }
        }
        return drew == 1 ? bytes.map { $0 != 0 } : nil
    }

    func countBadge(text: String, side: Int) -> PinImage? {
        var text = text
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drew = text.withUTF8 { text in
            pixels.withUnsafeMutableBufferPointer { out in
                hostBadge(text.baseAddress, Int32(text.count), Int32(side), out.baseAddress)
            }
        }
        return drew == 1 ? PinImage(width: side, height: side, premultipliedBGRA: pixels) : nil
    }

    func placeholder(side: Int) -> PinImage? {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drew = pixels.withUnsafeMutableBufferPointer { out in
            hostPlaceholder(Int32(side), out.baseAddress)
        }
        return drew == 1 ? PinImage(width: side, height: side, premultipliedBGRA: pixels) : nil
    }
}

/// One thread: plain state.
enum BrowserPins {
    /// The page could not load or decode a remote picture.
    struct ImageUnavailable: Error, CustomStringConvertible {
        let url: String
        var description: String { "The page could not load the pin's picture at \(url)." }
    }

    private struct PendingImage {
        let url: String
        let continuation: CheckedContinuation<PinImage, any Error>
        var width = 0
        var height = 0
        var pixels: UnsafeMutableRawBufferPointer?
    }

    nonisolated(unsafe) private static var pendingImages: [UInt32: PendingImage] = [:]
    nonisolated(unsafe) private static var nextImageID: UInt32 = 1
    /// The pictures the page handed over, by the ids it was given.
    nonisolated(unsafe) static var pictures: [UInt32: PinImage] = [:]
    nonisolated(unsafe) private static var nextPictureID: UInt32 = 1

    /// Sets the drawer and the loader, before the map makes its pins
    /// controller: the loader where the page loads pictures, the drawer
    /// where it has a 2D canvas.
    static func start(drawsPictures: Bool, loadsImages: Bool) {
        PinPictureHost.drawer = drawsPictures ? BrowserPinDrawer() : nil
        if loadsImages {
            let loader: PinRemoteImages.Load = { url in try await BrowserPins.load(url) }
            PinRemoteImages.hostLoader = loader
        } else {
            PinRemoteImages.hostLoader = nil
        }
    }

    static func load(_ url: URL) async throws -> PinImage {
        let text = url.absoluteString
        return try await withCheckedThrowingContinuation { continuation in
            let id = nextImageID
            nextImageID &+= 1
            pendingImages[id] = PendingImage(url: text, continuation: continuation)
            var text = text
            text.withUTF8 { url in hostImage(id, url.baseAddress, Int32(url.count)) }
        }
    }

    /// Room for a loaded picture of the size, straight RGBA, nil for a
    /// request that is not pending or a size of no pixels.
    static func imageBuffer(id: UInt32, width: Int, height: Int) -> UnsafeMutableRawPointer? {
        guard var request = pendingImages[id], width > 0, height > 0 else { return nil }
        request.pixels?.deallocate()
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: width * height * 4, alignment: 4)
        request.pixels = buffer
        request.width = width
        request.height = height
        pendingImages[id] = request
        return buffer.baseAddress
    }

    /// The page has the picture in the buffer (`loaded`), or could not load
    /// it.
    static func finishImage(id: UInt32, loaded: Bool) {
        guard let request = pendingImages.removeValue(forKey: id) else { return }
        defer { request.pixels?.deallocate() }
        guard loaded, let pixels = request.pixels else {
            request.continuation.resume(throwing: ImageUnavailable(url: request.url))
            return
        }
        request.continuation.resume(returning: PinImage(width: request.width, height: request.height,
                                                        rgba: Array(pixels)))
    }

    /// A picture of the page's, straight RGBA, kept under a new id.
    static func addPicture(width: Int, height: Int, rgba: UnsafePointer<UInt8>) -> UInt32 {
        let picture = PinImage(width: width, height: height,
                               rgba: Array(UnsafeBufferPointer(start: rgba, count: width * height * 4)))
        let id = nextPictureID
        nextPictureID &+= 1
        pictures[id] = picture
        return id
    }

    /// The parts as JSON for the page: an array of parts, each an array of
    /// commands, `["M", x, y]`, `["L", x, y]`, `["Q", cx, cy, x, y]`,
    /// `["C", c1x, c1y, c2x, c2y, x, y]` and `["Z"]`, as a canvas's path
    /// takes them, in the unit square, y down.
    static func json(of parts: [PinShapePath]) -> String {
        func number(_ value: CGFloat) -> String {
            "\(Double(value))"
        }
        let encoded = parts.map { part in
            "[" + part.elements.map { element -> String in
                switch element {
                case .move(let to):
                    return "[\"M\",\(number(to.x)),\(number(to.y))]"
                case .line(let to):
                    return "[\"L\",\(number(to.x)),\(number(to.y))]"
                case .quadCurve(let to, let control):
                    return "[\"Q\",\(number(control.x)),\(number(control.y)),\(number(to.x)),\(number(to.y))]"
                case .curve(let to, let control1, let control2):
                    return "[\"C\",\(number(control1.x)),\(number(control1.y)),\(number(control2.x)),\(number(control2.y)),\(number(to.x)),\(number(to.y))]"
                case .close:
                    return "[\"Z\"]"
                }
            }.joined(separator: ",") + "]"
        }
        return "[" + encoded.joined(separator: ",") + "]"
    }
}
#endif
