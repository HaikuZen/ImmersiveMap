// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PortableFoundation
import Testing

/// The resource folder of the platforms without `Bundle`, by known answers.
struct ResourceDirectoryTests {
    private func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResourceDirectoryTests-\(UInt64.random(in: 0...UInt64.max))", isDirectory: true)
        let resources = root.appendingPathComponent("Pkg_Target.resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources.appendingPathComponent("Fixtures"),
                                                withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: resources.appendingPathComponent("atlas.json"))
        try Data([1]).write(to: resources.appendingPathComponent("overview.pmtiles"))
        try Data([2]).write(to: resources.appendingPathComponent("LICENSE"))
        try Data([3]).write(to: root.appendingPathComponent("program"))
        return root
    }

    @Test func aResourceIsFoundByNameAndExtension() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = ResourceDirectory(url: root.appendingPathComponent("Pkg_Target.resources"))
        #expect(directory.url(forResource: "atlas", withExtension: "json")?.lastPathComponent == "atlas.json")
        #expect(directory.url(forResource: "overview", withExtension: "pmtiles") != nil)
        #expect(directory.url(forResource: "LICENSE", withExtension: nil) != nil)
        #expect(directory.url(forResource: "LICENSE", withExtension: "") != nil)
        #expect(directory.url(forResource: "Fixtures", withExtension: nil) != nil)
        #expect(directory.url(forResource: "atlas", withExtension: "png") == nil)
        #expect(directory.url(forResource: "missing", withExtension: "json") == nil)
    }

    @Test func theFolderIsTheEnvironmentsThenTheOneBesideTheProgram() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let program = root.appendingPathComponent("program").path
        let resources = root.appendingPathComponent("Pkg_Target.resources", isDirectory: true)

        let beside = ResourceDirectory.locate(environmentVariable: "RES", folderName: "Pkg_Target.resources",
                                              environment: [:], programPath: program)
        #expect(beside?.url.standardizedFileURL.path == resources.standardizedFileURL.path)

        let named = ResourceDirectory.locate(environmentVariable: "RES", folderName: "Elsewhere.resources",
                                             environment: ["RES": resources.path], programPath: program)
        #expect(named?.url.standardizedFileURL.path == resources.standardizedFileURL.path)

        // A variable that names no folder is not passed over for the folder
        // beside the program: the person who set it meant it.
        #expect(ResourceDirectory.locate(environmentVariable: "RES", folderName: "Pkg_Target.resources",
                                         environment: ["RES": root.appendingPathComponent("nope").path],
                                         programPath: program) == nil)
        #expect(ResourceDirectory.locate(environmentVariable: "RES", folderName: "Absent.resources",
                                         environment: [:], programPath: program) == nil)
        #expect(ResourceDirectory.locate(environmentVariable: "RES", folderName: "Pkg_Target.resources",
                                         environment: [:], programPath: nil) == nil)
    }
}
