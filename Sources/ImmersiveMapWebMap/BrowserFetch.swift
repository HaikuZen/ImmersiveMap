// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// The archives' range requests through the page's `fetch`: the module asks
// with one import, the page answers with two exports, the response's bytes
// copied into a buffer the module gives it. The archive client
// (`PMTilesArchiveClient.hostFetcherMaker`) reads every archive over HTTP
// through it.

#if arch(wasm32)
import PMTiles
import PortableFoundation

/// Starts the request: `GET` of the URL with the headers (one `name: value`
/// a line) and `Range: bytes=start-(end - 1)`. The page answers with
/// `immersivemap_fetch_buffer` and `immersivemap_fetch_finish`, never
/// within this call.
@_extern(wasm, module: "immersivemap_fetch", name: "range")
private func hostFetchRange(_ id: UInt32,
                            _ url: UnsafePointer<UInt8>?, _ urlLength: Int32,
                            _ headers: UnsafePointer<UInt8>?, _ headersLength: Int32,
                            _ start: Double, _ end: Double)

/// The requests the page has not answered yet. One thread: plain state.
enum BrowserFetch {
    private struct Pending {
        let continuation: CheckedContinuation<PMTilesArchiveClient.RangeResponse, any Error>
        /// The page writes into these, so they are memory of their own,
        /// never a `Data`'s, whose bytes may move.
        var body: UnsafeMutableRawBufferPointer?
        var headers: UnsafeMutableRawBufferPointer?

        /// The buffer's bytes, and the buffer freed.
        static func take(_ buffer: UnsafeMutableRawBufferPointer?) -> Data {
            guard let buffer else { return Data() }
            defer { buffer.deallocate() }
            return Data(buffer)
        }
    }

    nonisolated(unsafe) private static var pending: [UInt32: Pending] = [:]
    nonisolated(unsafe) private static var nextID: UInt32 = 1

    /// The page's `fetch` failed (no network, a refused CORS request): the
    /// text is the page's error.
    struct NetworkFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// The fetcher of the archive at the URL, for
    /// `PMTilesArchiveClient.hostFetcherMaker`. The `If-Match` the client
    /// asks for is not sent: a browser sends no such header across origins
    /// without a preflight the archive's host may not answer, and the
    /// client checks the response's ETag itself.
    static func fetcher(archiveURL: URL, requestHeaders: [String: String]) -> PMTilesArchiveClient.RangeFetcher {
        let url = archiveURL.absoluteString
        let headers = requestHeaders.map { "\($0.key): \($0.value)\n" }.joined()
        return { range, _ in
            try await withCheckedThrowingContinuation { continuation in
                let id = nextID
                nextID &+= 1
                pending[id] = Pending(continuation: continuation)
                var url = url
                var headers = headers
                url.withUTF8 { url in
                    headers.withUTF8 { headers in
                        hostFetchRange(id, url.baseAddress, Int32(url.count), headers.baseAddress, Int32(headers.count),
                                       Double(range.lowerBound), Double(range.upperBound))
                    }
                }
            }
        }
    }

    /// Room for `length` bytes of the response: its body (`kind` 0) or its
    /// headers, one `name: value` a line, or the error's text (`kind` 1).
    /// Nil for a request that is not pending.
    static func buffer(id: UInt32, kind: Int32, length: Int) -> UnsafeMutableRawPointer? {
        guard var request = pending[id], length >= 0 else { return nil }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(length, 1), alignment: 1)
        let sized = UnsafeMutableRawBufferPointer(rebasing: buffer[0 ..< length])
        if kind == 0 {
            request.body?.deallocate()
            request.body = sized
        } else {
            request.headers?.deallocate()
            request.headers = sized
        }
        pending[id] = request
        return buffer.baseAddress
    }

    /// The page has the answer: an HTTP status, or 0 when `fetch` failed.
    static func finish(id: UInt32, status: Int32) {
        guard let request = pending.removeValue(forKey: id) else { return }
        let body = Pending.take(request.body)
        let text = String(decoding: Pending.take(request.headers), as: UTF8.self)
        guard status > 0 else {
            request.continuation.resume(throwing: NetworkFailure(description: text))
            return
        }
        var headers: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon])] = String(line[line.index(after: colon)...].drop { $0 == " " })
        }
        request.continuation.resume(returning: PMTilesArchiveClient.RangeResponse(statusCode: Int(status),
                                                                                  headers: headers,
                                                                                  body: body))
    }
}
#endif
