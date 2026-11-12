// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import XCTest

/// Every WGSL shader names the Metal source it is the twin of, with the
/// hash of that source when the two last agreed. A change to the Metal file
/// alone fails here: bring its WGSL twin level, then stamp it
/// (`node Tools/WGSLCheck/stamp.mjs <file.wgsl>`). This catches a copy
/// forgotten, not two copies that compute different things.
final class ShaderPortStampTests: XCTestCase {
    func testEveryWGSLFileNamesTheMetalSourceItWasPortedFrom() throws {
        let files = try WGSLSources.files()
        XCTAssertFalse(files.isEmpty, "The WGSL sources are found")
        for file in files {
            let stamps = WGSLSources.stamps(in: try String(contentsOf: file, encoding: .utf8))
            XCTAssertFalse(stamps.isEmpty, "\(file.lastPathComponent) has no \"// ported-from:\" line")
        }
    }

    func testEveryMetalSourceIsAsItWasWhenItsTwinWasPorted() throws {
        for file in try WGSLSources.files() {
            for stamp in WGSLSources.stamps(in: try String(contentsOf: file, encoding: .utf8)) {
                let metal = file.deletingLastPathComponent().appendingPathComponent(stamp.path)
                guard let bytes = FileManager.default.contents(atPath: metal.path) else {
                    XCTFail("\(file.lastPathComponent) names \(stamp.path), which does not exist")
                    continue
                }
                XCTAssertEqual(WGSLSources.fnv1a64(bytes), stamp.hash,
                               "\(stamp.path) changed since \(file.lastPathComponent) was ported from it: bring the WGSL level, "
                                   + "then run node Tools/WGSLCheck/stamp.mjs on it")
            }
        }
    }

    func testTheHashIsTheToolsHash() {
        XCTAssertEqual(WGSLSources.fnv1a64(Data()), "cbf29ce484222325")
        XCTAssertEqual(WGSLSources.fnv1a64(Data("a".utf8)), "af63dc4c8601ec8c")
    }
}
