import XCTest
@testable import ZeroCopyFeed

final class FrameStoreTests: XCTestCase {

    private func makePool(capacity: Int, ledger: AllocationLedger) -> FramePool {
        FramePool(bufferCapacity: capacity, retentionLimit: 2, ledger: ledger)
    }

    func testWriteThenSnapshotRoundTrips() throws {
        let ledger = AllocationLedger()
        let pool = makePool(capacity: 64, ledger: ledger)
        let payload: [Int8] = [1, -2, 3, -4, 127, -128]
        do {
            var frame = try pool.acquire()
            try frame.write(payload, ledger: ledger)
            XCTAssertEqual(frame.count, payload.count)
            XCTAssertEqual(frame.snapshot(), payload)
        }
        pool.drain()
    }

    func testEmptyFrameIsSafe() throws {
        let ledger = AllocationLedger()
        let pool = makePool(capacity: 64, ledger: ledger)
        do {
            let frame = try pool.acquire()
            // Zero-length frame: every accessor must be a no-op, not a crash.
            XCTAssertEqual(frame.count, 0)
            XCTAssertEqual(frame.snapshot(), [])
            XCTAssertEqual(frame.digest(), 0xcbf2_9ce4_8422_2325, "empty digest is the FNV-1a offset basis")
            XCTAssertEqual(frame.tileEnergies(dimension: 8), [])
        }
        pool.drain()
    }

    func testWriteBeyondCapacityThrowsRatherThanOverruns() throws {
        let ledger = AllocationLedger()
        let pool = makePool(capacity: 4, ledger: ledger)
        var frame = try pool.acquire()
        let tooBig: [Int8] = [1, 2, 3, 4, 5]
        XCTAssertThrowsError(try frame.write(tooBig, ledger: ledger)) { error in
            XCTAssertEqual(error as? FeedError, .capacityExceeded(needed: 5, capacity: 4))
        }
        // The failed write must not have changed the frame.
        XCTAssertEqual(frame.count, 0)
    }

    func testResizeIsClampedAndBounded() throws {
        let ledger = AllocationLedger()
        let pool = makePool(capacity: 8, ledger: ledger)
        var frame = try pool.acquire()
        try frame.resize(to: 8)
        XCTAssertEqual(frame.count, 8)
        // Negative counts are treated as zero rather than trapping on a negative
        // buffer length.
        try frame.resize(to: -5)
        XCTAssertEqual(frame.count, 0)
        XCTAssertThrowsError(try frame.resize(to: 9)) { error in
            XCTAssertEqual(error as? FeedError, .capacityExceeded(needed: 9, capacity: 8))
        }
    }

    func testDigestMatchesTheValuePathDigestForTheSameBytes() throws {
        // The whole comparison rests on these two digests being computed the
        // same way over the same bytes. If they ever diverge, `outputsMatch`
        // becomes meaningless — so pin it directly.
        let ledger = AllocationLedger()
        let pool = makePool(capacity: 256, ledger: ledger)
        let payload = FeedKernels.syntheticFrame(byteCount: 173, seed: 4)
        do {
            var frame = try pool.acquire()
            try frame.write(payload, ledger: ledger)
            XCTAssertEqual(frame.digest(), fnv1a64(payload))
        }
        pool.drain()
    }

    func testDigestIsFixedAcrossProcessesNotSeeded() {
        // Hardcoded expected values. `Hasher` would make these unreproducible
        // between runs; FNV-1a makes them constants, which is the point of
        // choosing it. A test that only compared two in-process hashes would
        // pass for `Hasher` too — that is exactly the vacuous shape being
        // avoided here.
        XCTAssertEqual(fnv1a64([]), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(fnv1a64([0]), 0xaf63_bd4c_8601_b7df)
        XCTAssertEqual(fnv1a64([-1]), 0xaf64_724c_8602_eb6e, "Int8(-1) must hash as the unsigned byte 0xFF")
    }

    func testBoundaryCopiesAreCharged() throws {
        let ledger = AllocationLedger()
        let pool = makePool(capacity: 64, ledger: ledger)
        let payload = FeedKernels.syntheticFrame(byteCount: 40, seed: 1)
        do {
            var frame = try pool.acquire()
            try frame.write(payload, ledger: ledger)
            XCTAssertEqual(ledger.stats.boundaryCopyCount, 1)
            XCTAssertEqual(ledger.stats.bytesCopied, 40)
            _ = frame.snapshot(ledger: ledger)
            XCTAssertEqual(ledger.stats.boundaryCopyCount, 2)
            XCTAssertEqual(ledger.stats.bytesCopied, 80)
            // A snapshot with no ledger is not charged.
            _ = frame.snapshot()
            XCTAssertEqual(ledger.stats.boundaryCopyCount, 2)
        }
        pool.drain()
    }
}
