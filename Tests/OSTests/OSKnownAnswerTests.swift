// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import os
import XCTest

/// What the engine takes from `os`, run against Apple's module on Apple's
/// platforms and against the package's stand-in elsewhere. The lock is held
/// to its meaning. The logger and the signposter are only called the ways
/// the engine calls them: what they write is not the program's to read.
final class OSKnownAnswerTests: XCTestCase {
    func testTheLockKeepsItsState() {
        let lock = OSAllocatedUnfairLock(initialState: 0)
        lock.withLock { $0 += 5 }
        let doubled = lock.withLock { state -> Int in
            state *= 2
            return state
        }
        XCTAssertEqual(doubled, 10)
        XCTAssertEqual(lock.withLock { $0 }, 10)
    }

    func testACopyOfTheLockGuardsTheSameState() {
        let lock = OSAllocatedUnfairLock<Double>(initialState: 0)
        let copy = lock
        copy.withLock { $0 = 2.5 }
        XCTAssertEqual(lock.withLock { $0 }, 2.5)
    }

    func testTheLockLetsOneThroughAtATime() async {
        let lock = OSAllocatedUnfairLock(initialState: 0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<1000 {
                        lock.withLock { $0 += 1 }
                    }
                }
            }
        }
        XCTAssertEqual(lock.withLock { $0 }, 8000)
    }

    func testTheLockPassesAnErrorOn() {
        struct Refused: Error {}
        let lock = OSAllocatedUnfairLock(initialState: false)
        XCTAssertThrowsError(try lock.withLock { started in
            started = true
            throw Refused()
        })
        // The state the closure left stands, and the lock is free again.
        XCTAssertTrue(lock.withLock { $0 })
    }

    func testTheLoggerAndTheSignposterTakeTheEnginesCalls() {
        let logger = Logger(subsystem: "ImmersiveMap", category: "Tests")
        let tile = (z: 3, x: 4, y: 5)
        logger.warning("ImmersiveMap: test line for \(tile.z, privacy: .public)/\(tile.x, privacy: .public)")
        logger.error("ImmersiveMap: test line without values")
        logger.debug("ImmersiveMap: a debug line \(tile.y)")

        let signposter = OSSignposter(subsystem: "ImmersiveMap", category: "Tests")
        let whole = signposter.beginInterval("frame")
        let named = signposter.beginInterval("tileParse", id: signposter.makeSignpostID(), "\(tile.z)/\(tile.x)")
        let staged = signposter.beginInterval("stage", "\(tile.y)")
        signposter.endInterval("stage", staged)
        signposter.endInterval("tileParse", named)
        signposter.endInterval("frame", whole)
    }
}
