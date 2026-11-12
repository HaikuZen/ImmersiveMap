// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PortableFoundation
// `CACurrentMediaTime` is QuartzCore's where there is a QuartzCore.
#if canImport(QuartzCore)
import QuartzCore
#endif
import Testing

/// The geometry types the engine takes from Core Graphics, held to answers
/// worked out by hand. They are Core Graphics' own on Apple's platforms and
/// `PortableFoundation`'s elsewhere, so a difference between the two shows up
/// as a failure on one side.
///
/// Swift Testing and not XCTest, unlike the rest of the suite: XCTest shows a
/// test file the whole of Foundation, and in a slim build, where the types
/// are `PortableFoundation`'s own, Foundation's would be a second set under
/// the same names.
struct CoreGraphicsTypesTests {
    @Test func testTheTypesAreMadeOfTheScalar() {
        // The scalar's own size is the platform's: Foundation makes it a
        // `Float` on a 32-bit platform (WebAssembly) and a `Double` on the
        // rest, and a slim build's is a `Double` everywhere.
        let scalar = MemoryLayout<CGFloat>.size
        #expect(scalar == 8 || scalar == 4)
        #expect(MemoryLayout<CGPoint>.size == 2 * scalar)
        #expect(MemoryLayout<CGSize>.size == 2 * scalar)
        #expect(MemoryLayout<CGRect>.size == 4 * scalar)
        #expect(MemoryLayout<CFTimeInterval>.size == 8)
        let seconds: CFTimeInterval = 1.5
        #expect(Double(seconds) + Double(CGFloat(0.5)) == 2)
        #expect(Float(CGFloat(0.25)) == 0.25)
    }

    @Test func testTheMediaTimeOnlyGoesForward() {
        let first = CACurrentMediaTime()
        let second = CACurrentMediaTime()
        #expect(first > 0)
        #expect(second >= first)
    }

    @Test func testTheLockIsTakenAndLetGo() {
        // Taken and let go twice over: a lock that `withLock` or `unlock`
        // left held would stop the test here on a platform with threads.
        // On one thread (WebAssembly) every lock is free by nature.
        let lock = NSLock()
        lock.lock()
        lock.unlock()
        #expect(lock.withLock { 7 } == 7)
        lock.lock()
        lock.unlock()
        #expect(lock.withLock { "held" } == "held")
    }

    @Test func testZeroValuesAndEquality() {
        #expect(CGPoint.zero == CGPoint(x: 0, y: 0))
        #expect(CGSize.zero == CGSize(width: 0, height: 0))
        #expect(CGRect.zero == CGRect(origin: .zero, size: .zero))
        let byParts = CGRect(origin: CGPoint(x: 1, y: 2), size: CGSize(width: 3, height: 4))
        #expect(CGRect(x: 1, y: 2, width: 3, height: 4) == byParts)
        #expect(CGPoint(x: 1, y: 2) != CGPoint(x: 2, y: 1))
    }

    @Test func testEdgesAndExtents() {
        let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
        #expect(rect.minX == 10)
        #expect(rect.midX == 25)
        #expect(rect.maxX == 40)
        #expect(rect.minY == 20)
        #expect(rect.midY == 40)
        #expect(rect.maxY == 60)
        #expect(rect.width == 30)
        #expect(rect.height == 40)
        #expect(rect.origin == CGPoint(x: 10, y: 20))
        #expect(rect.size == CGSize(width: 30, height: 40))
    }

    @Test func testANegativeSizeExtendsBackFromTheOrigin() {
        let rect = CGRect(x: 10, y: 20, width: -4, height: -6)
        #expect(rect.minX == 6)
        #expect(rect.maxX == 10)
        #expect(rect.minY == 14)
        #expect(rect.maxY == 20)
        #expect(rect.width == 4)
        #expect(rect.height == 6)
        #expect(rect.midX == 8)
        #expect(rect.standardized == CGRect(x: 6, y: 14, width: 4, height: 6))
    }

    @Test func testEmptyAndNull() {
        #expect(CGRect.zero.isEmpty)
        #expect(!CGRect.zero.isNull)
        #expect(CGRect.null.isEmpty)
        #expect(CGRect.null.isNull)
        #expect(CGRect(x: 1, y: 1, width: 0, height: 5).isEmpty)
        #expect(!CGRect(x: 1, y: 1, width: 2, height: 5).isEmpty)
    }

    @Test func testAPointOnAMaximumEdgeIsOutside() {
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        #expect(rect.contains(CGPoint(x: 0, y: 0)))
        #expect(rect.contains(CGPoint(x: 9.5, y: 9.5)))
        #expect(!rect.contains(CGPoint(x: 10, y: 5)))
        #expect(!rect.contains(CGPoint(x: 5, y: 10)))
        #expect(!rect.contains(CGPoint(x: -0.5, y: 5)))
        #expect(!CGRect.null.contains(CGPoint(x: 0, y: 0)))
        #expect(!CGRect(x: 0, y: 0, width: 0, height: 10).contains(CGPoint(x: 0, y: 5)))
    }

    @Test func testAUnionCoversBothAndTheNullRectangleAddsNothing() {
        let a = CGRect(x: 0, y: 0, width: 10, height: 10)
        let b = CGRect(x: 20, y: -5, width: 5, height: 10)
        #expect(a.union(b) == CGRect(x: 0, y: -5, width: 25, height: 15))
        #expect(b.union(a) == CGRect(x: 0, y: -5, width: 25, height: 15))
        #expect(CGRect.null.union(a) == a)
        #expect(a.union(.null) == a)
        #expect(CGRect.null.union(.null).isNull)
    }

    @Test func testAnInsetMovesEveryEdgeAndPastTheMiddleIsNull() {
        let rect = CGRect(x: 0, y: 0, width: 10, height: 20)
        #expect(rect.insetBy(dx: 2, dy: 3) == CGRect(x: 2, y: 3, width: 6, height: 14))
        #expect(rect.insetBy(dx: -1, dy: -1) == CGRect(x: -1, y: -1, width: 12, height: 22))
        #expect(rect.insetBy(dx: 6, dy: 0).isNull)
        #expect(rect.offsetBy(dx: 5, dy: -5) == CGRect(x: 5, y: -5, width: 10, height: 20))
    }
}
