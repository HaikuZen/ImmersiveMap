// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import PortableFoundation
import Testing

/// `FileManager.replaceFile`, the portable `replaceItemAt`, by known
/// answers.
struct FileReplacementTests {
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileReplacementTests-\(UInt64.random(in: 0...UInt64.max))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func aFileTakesTheOldOnesPlace() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("tile")
        let staged = folder.appendingPathComponent("tile.tmp")
        try Data([1, 2, 3]).write(to: destination)
        try Data([4, 5]).write(to: staged)
        try FileManager.default.replaceFile(at: destination, withFileAt: staged)
        #expect(FileManager.default.contents(atPath: destination.path) == Data([4, 5]))
        #expect(FileManager.default.fileExists(atPath: staged.path) == false)
    }

    @Test func aFileGoesWhereThereIsNoneYet() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("tile")
        let staged = folder.appendingPathComponent("tile.tmp")
        try Data([7]).write(to: staged)
        try FileManager.default.replaceFile(at: destination, withFileAt: staged)
        #expect(FileManager.default.contents(atPath: destination.path) == Data([7]))
    }

    @Test func aMissingSourceThrows() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: (any Error).self) {
            try FileManager.default.replaceFile(at: folder.appendingPathComponent("tile"),
                                                withFileAt: folder.appendingPathComponent("missing"))
        }
    }
}
