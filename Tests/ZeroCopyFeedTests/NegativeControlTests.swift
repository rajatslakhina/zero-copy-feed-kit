import XCTest
@testable import ZeroCopyFeed

/// Every assertion in this file is of the form "feed the check a deliberately
/// broken input and confirm it *fails*".
///
/// A test suite made entirely of passing green checks tells you nothing about
/// whether those checks can go red. Each property the README claims is
/// represented here twice: once positively, in the other test files, and once
/// here as a sensitivity test.
final class NegativeControlTests: XCTestCase {

    // MARK: - A deliberately wrong stage

    /// `gateWeak` with the wrong threshold. Same shape, same allocations, same
    /// geometry contract — one byte of behaviour different.
    private struct WrongThresholdGateStage: ValueFeedStage {
        let kind: FeedStageKind = .gateWeak

        func transform(_ input: FrameValue, geometry: FeedGeometry, ledger: AllocationLedger?) -> FrameValue {
            var output = input.bytes
            ledger?.recordAllocation(bytes: output.count)
            output.withUnsafeMutableBufferPointer { buffer in
                // The correct stage gates below magnitude 4.
                FeedKernels.gate(buffer, belowMagnitude: 5)
            }
            return FrameValue(bytes: output)
        }
    }

    func testOutputsMatchGoesFalseWhenOneStageIsWrong() throws {
        let geometry = try FeedGeometry(tileCount: 16, dimension: 32)
        let configuration = try FeedRunConfiguration(
            geometry: geometry, frameCount: 5, stageCount: 3
        )

        let owningLedger = AllocationLedger()
        let owning = try OwningPipeline.run(configuration: configuration, ledger: owningLedger)
        let consumingLedger = AllocationLedger()
        let consuming = try ConsumingValuePipeline.run(configuration: configuration, ledger: consumingLedger)

        // Correct value stages first: this must agree, or the negative control
        // below proves nothing.
        let goodLedger = AllocationLedger()
        let good = try ValuePipeline.run(configuration: configuration, ledger: goodLedger)
        XCTAssertTrue(
            BoundaryComparison(configuration: configuration, owning: owning, consumingValue: consuming, value: good).outputsMatch,
            "baseline must match before the broken variant means anything"
        )

        // Now swap stage 3 for the wrong one.
        let brokenStages: [any ValueFeedStage] = [
            FeedStageKind.requantizeUp.makeValueStage(),
            FeedStageKind.zeroCenter.makeValueStage(),
            WrongThresholdGateStage()
        ]
        let brokenLedger = AllocationLedger()
        let broken = try ValuePipeline.run(
            configuration: configuration, ledger: brokenLedger, stages: brokenStages
        )
        let brokenComparison = BoundaryComparison(
            configuration: configuration, owning: owning, consumingValue: consuming, value: broken
        )

        XCTAssertFalse(
            brokenComparison.outputsMatch,
            "the equality check must detect a one-threshold difference — if it cannot, it is decoration"
        )
        XCTAssertNotEqual(owning.combinedDigest, broken.combinedDigest)
        XCTAssertEqual(
            brokenComparison.headline, "Outputs diverged — the comparison is not valid.",
            "a diverged run must not print an allocation ratio as if it were meaningful"
        )
        // The broken run still allocates identically, which is the point: the
        // allocation numbers alone cannot tell you the outputs agree.
        XCTAssertEqual(broken.stats.allocationCount, good.stats.allocationCount)
    }

    // MARK: - The leak check can go red

    func testIsBalancedIsFalseWhileAFrameIsStillAlive() throws {
        let ledger = AllocationLedger()
        let pool = FramePool(bufferCapacity: 128, retentionLimit: 2, ledger: ledger)

        XCTAssertTrue(ledger.stats.isBalanced, "nothing allocated yet")

        do {
            let frame = try pool.acquire()
            XCTAssertFalse(
                ledger.stats.isBalanced,
                "with a buffer checked out the ledger must report an imbalance — otherwise "
                    + "`isBalanced` is true for every input and proves nothing"
            )
            XCTAssertEqual(ledger.stats.liveBytes, 128)
            XCTAssertEqual(frame.capacity, 128)
        }

        // The frame's deinit returned the buffer, but the pool still retains it,
        // so the ledger is still out of balance until the pool lets go.
        XCTAssertFalse(ledger.stats.isBalanced, "the pool still holds the buffer on its free list")
        pool.drain()
        XCTAssertTrue(ledger.stats.isBalanced)
        XCTAssertEqual(ledger.stats.liveBytes, 0)
    }

    // MARK: - "Constant allocations" is a property of pooling, not of the counter

    func testDisablingReuseMakesAllocationsScaleWithFrameCount() throws {
        // If the owning path reported two allocations no matter what, the flat
        // line in the other test file would be an artefact. Removing the free
        // list must make the same code allocate once per frame.
        let frameCount = 20
        let geometry = try FeedGeometry(tileCount: 8, dimension: 16)
        let configuration = try FeedRunConfiguration(
            geometry: geometry,
            frameCount: frameCount,
            stageCount: 3,
            poolRetentionLimit: 0
        )
        let ledger = AllocationLedger()
        let result = try OwningPipeline.run(configuration: configuration, ledger: ledger)

        XCTAssertEqual(
            result.stats.allocationCount, frameCount,
            "with retention disabled the owning path allocates per frame, proving the "
                + "flat count elsewhere comes from reuse and not from a stuck counter"
        )
        XCTAssertEqual(result.stats.reuseCount, 0)

        // Same configuration, reuse enabled: back to one.
        let pooled = try FeedRunConfiguration(
            geometry: geometry, frameCount: frameCount, stageCount: 3, poolRetentionLimit: 2
        )
        let pooledLedger = AllocationLedger()
        let pooledResult = try OwningPipeline.run(configuration: pooled, ledger: pooledLedger)
        XCTAssertEqual(pooledResult.stats.allocationCount, 1)
        XCTAssertEqual(
            pooledResult.combinedDigest, result.combinedDigest,
            "changing the pool policy must not change a single output byte"
        )
    }

    // MARK: - The digest is not seeded

    func testDigestOfDifferentBytesDiffers() {
        // Sensitivity control for the digest itself: if `digest()` returned a
        // constant, every `outputsMatch` in the suite would pass.
        let a = FeedKernels.syntheticFrame(byteCount: 64, seed: 1)
        var b = a
        b[31] = b[31] == 0 ? 1 : 0
        XCTAssertNotEqual(fnv1a64(a), fnv1a64(b), "a single flipped byte must change the digest")
    }

    // MARK: - Geometry validation actually rejects

    func testGeometryValidationRejectsRatherThanClamping() {
        // A validator that silently clamped would let a wrong geometry through
        // and produce a plausible-looking wrong answer.
        XCTAssertThrowsError(try FeedGeometry(tileCount: 0, dimension: 64)) { error in
            XCTAssertEqual(
                error as? FeedError,
                .invalidGeometry(reason: "tileCount must be at least 1, got 0")
            )
        }
    }
}
