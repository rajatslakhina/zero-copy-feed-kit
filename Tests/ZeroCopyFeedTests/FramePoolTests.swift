import Dispatch
import XCTest
@testable import ZeroCopyFeed

final class FramePoolTests: XCTestCase {

    // MARK: - Concurrency

    func testPoolAndLedgerStayConsistentUnderConcurrentWriters() {
        // `FramePool` and `AllocationLedger` are both `@unchecked Sendable` with
        // hand-rolled `NSLock` discipline, which is a claim the suite should be
        // able to fail rather than one it merely states. Eight threads actually
        // contend here — a "concurrency test" with a single writer proves
        // nothing about a lock.
        let ledger = AllocationLedger()
        let pool = FramePool(bufferCapacity: 64, retentionLimit: 4, ledger: ledger)
        let threads = 8
        let perThread = 250

        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            for _ in 0..<perThread {
                do {
                    var frame = try pool.acquire()
                    try frame.write([1, 2, 3, 4], ledger: nil)
                    XCTAssertEqual(frame.count, 4)
                } catch {
                    XCTFail("unlimited pool must not refuse: \(error)")
                }
            }
        }

        // Every checkout is either a fresh allocation or a reuse, never both and
        // never neither — so this total is exact, not a bound.
        XCTAssertEqual(pool.allocationCount + pool.reuseCount, threads * perThread)
        XCTAssertEqual(pool.liveCount, 0, "every frame's deinit ran")
        XCTAssertEqual(pool.allocationCount, ledger.stats.allocationCount,
                       "pool and ledger disagree after contention")
        XCTAssertEqual(pool.reuseCount, ledger.stats.reuseCount)
        XCTAssertLessThanOrEqual(pool.allocationCount, threads,
                                 "contention should not allocate more than one buffer per thread")
        pool.drain()
        XCTAssertTrue(ledger.stats.isBalanced, "concurrent run leaked")
    }

    /// `XCTAssertThrowsError` is generic over a `Copyable` result, and
    /// `acquire()` returns a `~Copyable` `FrameStore` — so it does not type-check
    /// here at all. This is a small, concrete example of the same trade the
    /// package is about: noncopyability costs you the generic helpers that
    /// assume values can be duplicated, including the ones in XCTest.
    private func assertAcquireThrows(
        _ pool: FramePool,
        _ expected: FeedError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try pool.acquire()
            XCTFail("expected \(expected) but acquire() succeeded", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? FeedError, expected, file: file, line: line)
        }
    }

    func testSequentialFramesReuseOneBuffer() throws {
        let ledger = AllocationLedger()
        let pool = FramePool(bufferCapacity: 128, retentionLimit: 2, ledger: ledger)
        for _ in 0..<50 {
            let frame = try pool.acquire()
            XCTAssertEqual(frame.capacity, 128)
        }
        XCTAssertEqual(pool.allocationCount, 1, "50 sequential frames must not allocate 50 buffers")
        XCTAssertEqual(pool.reuseCount, 49)
        XCTAssertEqual(pool.liveCount, 0)
        XCTAssertEqual(pool.peakLiveCount, 1)
        pool.drain()
        XCTAssertTrue(ledger.stats.isBalanced)
    }

    func testOverlappingFramesAllocateTwoBuffers() throws {
        let ledger = AllocationLedger()
        let pool = FramePool(bufferCapacity: 128, retentionLimit: 2, ledger: ledger)
        do {
            let first = try pool.acquire()
            let second = try pool.acquire()
            XCTAssertEqual(pool.liveCount, 2)
            XCTAssertEqual(first.capacity, second.capacity)
        }
        XCTAssertEqual(pool.allocationCount, 2)
        XCTAssertEqual(pool.peakLiveCount, 2)
        XCTAssertEqual(pool.liveCount, 0)
        pool.drain()
        XCTAssertTrue(ledger.stats.isBalanced)
    }

    func testLiveLimitProvidesBackpressure() throws {
        let ledger = AllocationLedger()
        let pool = FramePool(bufferCapacity: 32, retentionLimit: 2, liveLimit: 2, ledger: ledger)
        let first = try pool.acquire()
        let second = try pool.acquire()
        assertAcquireThrows(pool, .poolExhausted(live: 2, limit: 2))
        // Keep both alive across the assertion so the limit is genuinely hit.
        XCTAssertEqual(first.capacity, 32)
        XCTAssertEqual(second.capacity, 32)
    }

    func testRefusedAcquireDoesNotLeakOccupancy() throws {
        // A throwing `acquire` must not leave `live` incremented, or the pool
        // deadlocks itself after one refusal.
        let ledger = AllocationLedger()
        let pool = FramePool(bufferCapacity: 32, retentionLimit: 1, liveLimit: 1, ledger: ledger)
        do {
            let held = try pool.acquire()
            assertAcquireThrows(pool, .poolExhausted(live: 1, limit: 1))
            XCTAssertEqual(pool.liveCount, 1, "the refused acquire must not count as live")
            XCTAssertEqual(held.capacity, 32)
        }
        XCTAssertEqual(pool.liveCount, 0)
        let again = try pool.acquire()
        XCTAssertEqual(again.capacity, 32)
    }

    func testRetentionLimitZeroDeallocatesEveryRelease() throws {
        let ledger = AllocationLedger()
        let pool = FramePool(bufferCapacity: 64, retentionLimit: 0, ledger: ledger)
        for _ in 0..<10 {
            _ = try pool.acquire()
        }
        XCTAssertEqual(pool.allocationCount, 10, "with no free list every frame must allocate")
        XCTAssertEqual(pool.reuseCount, 0)
        XCTAssertTrue(ledger.stats.isBalanced, "released buffers are deallocated immediately")
    }

    func testDegenerateCapacityIsRaisedToOne() {
        let ledger = AllocationLedger()
        let pool = FramePool(bufferCapacity: 0, retentionLimit: 1, ledger: ledger)
        // `allocate(byteCount: 0)` is legal but yields a pointer no frame can
        // safely index; the pool raises it so `capacity` is always usable.
        XCTAssertEqual(pool.bufferCapacity, 1)
        let negative = FramePool(bufferCapacity: -10, retentionLimit: -3, liveLimit: 0, ledger: ledger)
        XCTAssertEqual(negative.bufferCapacity, 1)
        XCTAssertEqual(negative.retentionLimit, 0)
        XCTAssertEqual(negative.liveLimit, 1, "a live limit of zero would make the pool unusable")
    }

    func testDrainIsIdempotent() throws {
        let ledger = AllocationLedger()
        let pool = FramePool(bufferCapacity: 64, retentionLimit: 4, ledger: ledger)
        do {
            _ = try pool.acquire()
            _ = try pool.acquire()
        }
        pool.drain()
        let afterFirst = ledger.stats
        pool.drain()
        XCTAssertEqual(ledger.stats, afterFirst, "a second drain must not double-count deallocations")
    }
}
