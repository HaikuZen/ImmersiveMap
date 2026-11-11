// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import PMTiles
import PMTilesTestSupport
import XCTest

/// The archive client over a fetcher in place of a session, which is how a
/// platform without `URLSession` reads an archive: the host hands the client
/// a function that fetches a byte range. These run everywhere the format
/// tests run. The client over a real session and a local server is tested in
/// `ImmersiveMapTests/PMTilesArchiveClientTests`.
final class PMTilesArchiveClientFetcherTests: XCTestCase {
    private static let archiveURL = URL(string: "https://tiles.invalid/fixture.pmtiles")!

    private static func tileData(_ z: Int, _ x: Int, _ y: Int) -> Data {
        Data("tile \(z)/\(x)/\(y)".utf8)
    }

    /// Zooms 0 to 3 whole, with few enough root entries that the tiles of the
    /// deeper zooms are reached through leaf directories.
    private static func makeArchive() -> Data {
        var writer = PMTilesArchiveWriter()
        for z in 0...3 {
            for x in 0..<(1 << z) {
                for y in 0..<(1 << z) {
                    writer.tiles.append(.init(z: z, x: x, y: y, data: tileData(z, x, y)))
                }
            }
        }
        writer.maximumRootEntries = 8
        writer.maxZoom = 3
        return writer.serializedData()
    }

    /// Answers a range of the archive the way an HTTP server does.
    private static func fetcher(over archive: Data,
                                etag: String? = "\"v1\"") -> PMTilesArchiveClient.RangeFetcher {
        { range, _ in
            let end = min(UInt64(archive.count), range.upperBound)
            guard range.lowerBound < end else {
                return .init(statusCode: 416)
            }
            var headers = ["Content-Range": "bytes \(range.lowerBound)-\(end - 1)/\(archive.count)"]
            if let etag {
                headers["ETag"] = etag
            }
            return .init(statusCode: 206,
                         headers: headers,
                         body: archive.subdata(in: Int(range.lowerBound)..<Int(end)))
        }
    }

    /// The bytes of a tile outcome, nil for any other. The ETag beside them
    /// is the client's own business and is not compared here.
    private static func data(of outcome: PMTilesArchiveClient.Outcome) -> Data? {
        if case let .tile(data, _) = outcome {
            return data
        }
        return nil
    }

    private func makeClient(_ fetchRange: @escaping PMTilesArchiveClient.RangeFetcher) -> PMTilesArchiveClient {
        PMTilesArchiveClient(archiveURL: Self.archiveURL, requestHeaders: [:], fetchRange: fetchRange)
    }

    func testEveryTileOfTheArchiveIsRead() async throws {
        let client = makeClient(Self.fetcher(over: Self.makeArchive()))
        for z in 0...3 {
            for x in 0..<(1 << z) {
                for y in 0..<(1 << z) {
                    let outcome = try await client.tileBytes(z: z, x: x, y: y)
                    XCTAssertEqual(Self.data(of: outcome), Self.tileData(z, x, y), "\(z)/\(x)/\(y)")
                }
            }
        }
    }

    func testTheHeaderGivesTheETagAndTheDeepestZoom() async throws {
        let client = makeClient(Self.fetcher(over: Self.makeArchive()))
        let etag = try await client.archiveETag()
        let maximumZoom = try await client.maximumZoom()
        XCTAssertEqual(etag, "\"v1\"")
        XCTAssertEqual(maximumZoom, 3)
    }

    func testATileBelowTheDeepestZoomIsOutsideTheZoomRange() async throws {
        let client = makeClient(Self.fetcher(over: Self.makeArchive()))
        let outcome = try await client.tileBytes(z: 4, x: 0, y: 0)
        XCTAssertEqual(outcome, .outsideZoomRange)
    }

    func testATileTheArchiveDoesNotCarryIsMissing() async throws {
        var writer = PMTilesArchiveWriter()
        writer.tiles = [.init(z: 1, x: 0, y: 0, data: Self.tileData(1, 0, 0))]
        writer.maxZoom = 1
        let client = makeClient(Self.fetcher(over: writer.serializedData()))
        let present = try await client.tileBytes(z: 1, x: 0, y: 0)
        let absent = try await client.tileBytes(z: 1, x: 1, y: 1)
        XCTAssertEqual(Self.data(of: present), Self.tileData(1, 0, 0))
        XCTAssertEqual(absent, .missing)
    }

    func testAFailingHostIsAnHTTPFailure() async {
        let client = makeClient { _, _ in .init(statusCode: 503, headers: ["Retry-After": "7"]) }
        do {
            _ = try await client.tileBytes(z: 0, x: 0, y: 0)
            XCTFail("a 503 gave a tile")
        } catch {
            XCTAssertEqual(error as? PMTilesArchiveClient.Failure,
                           .http(statusCode: 503, body: Data(), retryAfter: 7))
        }
    }

    func testBytesThatAreNoArchiveAreUnreadable() async {
        let client = makeClient(Self.fetcher(over: Data("<html>not an archive</html>".utf8)))
        do {
            _ = try await client.tileBytes(z: 0, x: 0, y: 0)
            XCTFail("a web page gave a tile")
        } catch {
            guard case .archiveUnreadable = error as? PMTilesArchiveClient.Failure else {
                return XCTFail("expected an unreadable archive, got \(error)")
            }
        }
    }
}
