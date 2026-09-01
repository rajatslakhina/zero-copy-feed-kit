import XCTest
@testable import ZeroCopyFeed

/// The numbers in this file are the numbers the README quotes. They are exact,
/// not bounds, because both pipelines are deterministic — if a change makes the
/// owning path allocate three buffers instead of two, that is a design
/// regression and the suite should say so rather than shrug at an inequality.
final class BoundaryComparisonTests: XCTestCase {

    // 32 tiles × 64 dimensions = 2048 bytes per frame.
    private let tileCount = 32
    private let dimension = 64
    private let bytesPerFrame = 2048

    // MARK: - The equality gate itself

    /// `outputsMatch` checks three things, and a review found only one of them
    /// covered: deleting the `finalGeometry` and `framesProcessed` arms left the
    /// whole suite green. A gate with untested arms is a gate that can quietly
    /// stop gating.
    func testOutputsMatchRejectsAgreementOnDigestAlone() throws {
        let geometry = try FeedGeometry(tileCount: 16, dimension: 32)
        let configuration = try FeedRunConfiguration(geometry: geometry, frameCount: 4, stageCount: 6)

        let owning = try OwningPipeline.run(configuration: configuration, ledger: AllocationLedger())
        let consuming = try ConsumingValuePipeline.run(
            configuration: configuration, ledger: AllocationLedger()
        )
        let value = try ValuePipeline.run(configuration: configuration, ledger: AllocationLedger())

        XCTAssertTrue(
            BoundaryComparison(
                configuration: configuration, owning: owning,
                consumingValue: consuming, value: value
            ).outputsMatch,
            "baseline must agree or neither control below proves anything"
        )

        // Same digest, wrong output geometry. A path that ends up claiming a
        // different shape has not done the same work, whatever the fold says.
        let wrongGeometry = BoundaryRunResult(
            shape: value.shape,
            stats: value.stats,
            poolAllocationCount: nil,
            poolReuseCount: nil,
            peakLiveFrames: nil,
            combinedDigest: owning.combinedDigest,
            framesProcessed: owning.framesProcessed,
            finalGeometry: try FeedGeometry(tileCount: 3, dimension: 5)
        )
        XCTAssertFalse(
            BoundaryComparison(
                configuration: configuration, owning: owning,
                consumingValue: consuming, value: wrongGeometry
            ).outputsMatch,
            "a matching digest over a different geometry must not pass the gate"
        )

        // Same digest, fewer frames. This is the cheapest way to fake a low
        // allocation count, so it is the one the gate most needs to catch.
        let wrongFrames = BoundaryRunResult(
            shape: consuming.shape,
            stats: consuming.stats,
            poolAllocationCount: nil,
            poolReuseCount: nil,
            peakLiveFrames: nil,
            combinedDigest: owning.combinedDigest,
            framesProcessed: owning.framesProcessed - 1,
            finalGeometry: owning.finalGeometry
        )
        XCTAssertFalse(
            BoundaryComparison(
                configuration: configuration, owning: owning,
                consumingValue: wrongFrames, value: value
            ).outputsMatch,
            "a path that processed fewer frames must not pass the gate"
        )
    }

    // MARK: - The headline configuration

    func testSixStageRunAllocatesTwoBuffersRegardlessOfFrameCount() throws {
        let comparison = try BoundaryBenchmark.compare(
            tileCount: tileCount, dimension: dimension, frameCount: 20, stageCount: 6
        )

        XCTAssertTrue(comparison.outputsMatch, "the comparison is only meaningful if both paths agree")

        // Owning: one buffer for the frame, one for the fold destination. Not
        // one per frame, and not one per stage.
        XCTAssertEqual(comparison.owning.stats.allocationCount, 2)
        XCTAssertEqual(comparison.owning.stats.bytesAllocated, 2 * bytesPerFrame)
        XCTAssertEqual(comparison.owning.stats.reuseCount, 38)

        // Value: one allocation per stage per frame.
        XCTAssertEqual(comparison.value.stats.allocationCount, 120, "20 frames × 6 stages")
        // 3 full-size stages then 3 half-size stages, after the fold halves the
        // tile count: 20 × (3 × 2048 + 3 × 1024).
        XCTAssertEqual(comparison.value.stats.bytesAllocated, 20 * (3 * 2048 + 3 * 1024))

        XCTAssertEqual(comparison.allocationsAvoided, 118)
        XCTAssertEqual(comparison.allocationRatio, 60.0)
    }

    func testAllocationCountIsFlatInFrameCountOnTheOwningPath() throws {
        // The claim is not "fewer allocations" but "a constant number of them".
        // Three different frame counts, same answer.
        for frameCount in [1, 20, 200] {
            let comparison = try BoundaryBenchmark.compare(
                tileCount: 8, dimension: 16, frameCount: frameCount, stageCount: 6
            )
            XCTAssertEqual(
                comparison.owning.stats.allocationCount, 2,
                "owning allocations must not scale with frameCount (\(frameCount))"
            )
            XCTAssertEqual(
                comparison.value.stats.allocationCount, frameCount * 6,
                "value allocations scale linearly with frameCount (\(frameCount))"
            )
            XCTAssertTrue(comparison.outputsMatch)
        }
    }

    func testAStagelessPipelineIsWhereOwnershipStopsPayingForItself() throws {
        // Honest edge of the claim: with no stages the value path allocates
        // nothing at all and the owning path still needs its one buffer. The
        // ownership machinery is not free, and the README says so.
        let comparison = try BoundaryBenchmark.compare(
            tileCount: 4, dimension: 4, frameCount: 10, stageCount: 0
        )
        XCTAssertEqual(comparison.owning.stats.allocationCount, 1)
        XCTAssertEqual(comparison.value.stats.allocationCount, 0)
        XCTAssertEqual(comparison.allocationsAvoided, 0)
        XCTAssertEqual(comparison.allocationRatio, 0.0)
        XCTAssertTrue(comparison.outputsMatch)
    }

    func testPeakFootprintIsComparableEvenThoughAllocationTrafficIsNot() throws {
        // The win is allocator traffic and determinism, not resident size. Both
        // paths hold about two buffers at their peak. Overstating this would be
        // the easiest way to make the repo dishonest.
        let comparison = try BoundaryBenchmark.compare(
            tileCount: tileCount, dimension: dimension, frameCount: 20, stageCount: 6
        )
        XCTAssertEqual(comparison.owning.stats.peakLiveBytes, 2 * bytesPerFrame)
        XCTAssertEqual(comparison.value.stats.peakLiveBytes, 2 * bytesPerFrame)
    }

    // MARK: - Cross-checks

    func testPoolCountersAgreeWithTheLedger() throws {
        // The pool counts allocations because it makes them; the ledger counts
        // them because it was told to. Agreement between two independently
        // maintained counters is the check that the harness is not simply
        // reporting its own assumptions.
        for stageCount in 0...6 {
            let comparison = try BoundaryBenchmark.compare(
                tileCount: 6, dimension: 12, frameCount: 7, stageCount: stageCount
            )
            XCTAssertEqual(
                comparison.owning.poolAllocationCount,
                comparison.owning.stats.allocationCount,
                "pool and ledger disagree at stageCount=\(stageCount)"
            )
            XCTAssertEqual(comparison.owning.poolReuseCount, comparison.owning.stats.reuseCount)
        }
    }

    func testBothPathsEndBalanced() throws {
        let comparison = try BoundaryBenchmark.compare(
            tileCount: 10, dimension: 10, frameCount: 15, stageCount: 6
        )
        XCTAssertTrue(comparison.owning.stats.isBalanced, "owning path leaked")
        XCTAssertTrue(comparison.value.stats.isBalanced, "value path accounting is unbalanced")
        XCTAssertEqual(comparison.owning.stats.liveBytes, 0)
        XCTAssertEqual(comparison.value.stats.liveBytes, 0)
    }

    func testOneBoundaryCopyPerFrameOnTheOwningPathAndNoneOnTheValuePath() throws {
        // Stated plainly because it is the one metric where the value boundary
        // wins: entering the owning world costs a copy, and the value world is
        // already there.
        let comparison = try BoundaryBenchmark.compare(
            tileCount: 4, dimension: 8, frameCount: 9, stageCount: 3
        )
        XCTAssertEqual(comparison.owning.stats.boundaryCopyCount, 9)
        XCTAssertEqual(comparison.owning.stats.bytesCopied, 9 * 32)
        XCTAssertEqual(comparison.value.stats.boundaryCopyCount, 0)
        XCTAssertEqual(comparison.value.stats.bytesCopied, 0)
    }

    // MARK: - Geometry

    func testFoldHalvesTheTileCountOnBothPathsIdentically() throws {
        let comparison = try BoundaryBenchmark.compare(
            tileCount: 32, dimension: 64, frameCount: 3, stageCount: 4
        )
        XCTAssertEqual(comparison.owning.finalGeometry.tileCount, 16)
        XCTAssertEqual(comparison.owning.finalGeometry.dimension, 64)
        XCTAssertEqual(comparison.owning.finalGeometry, comparison.value.finalGeometry)
    }

    func testOddTileCountRoundsUpWhenFolded() throws {
        let comparison = try BoundaryBenchmark.compare(
            tileCount: 7, dimension: 4, frameCount: 2, stageCount: 4
        )
        XCTAssertEqual(comparison.owning.finalGeometry.tileCount, 4, "(7 + 1) / 2")
        XCTAssertTrue(comparison.outputsMatch)
    }

    func testSingleTileSingleDimensionRunsWithoutTrapping() throws {
        let comparison = try BoundaryBenchmark.compare(
            tileCount: 1, dimension: 1, frameCount: 1, stageCount: 6
        )
        XCTAssertTrue(comparison.outputsMatch)
        XCTAssertEqual(comparison.owning.finalGeometry.tileCount, 1)
    }

    // MARK: - Validation

    func testInvalidGeometryIsRejected() {
        XCTAssertThrowsError(try FeedGeometry(tileCount: 0, dimension: 8))
        XCTAssertThrowsError(try FeedGeometry(tileCount: 8, dimension: 0))
        XCTAssertThrowsError(try FeedGeometry(tileCount: -1, dimension: -1))
        XCTAssertThrowsError(try FeedGeometry(tileCount: Int.max, dimension: 2)) { error in
            guard case .invalidGeometry = (error as? FeedError) else {
                return XCTFail("expected invalidGeometry, got \(error)")
            }
        }
    }

    func testFrameCountBelowOneIsRejected() throws {
        let geometry = try FeedGeometry(tileCount: 2, dimension: 2)
        XCTAssertThrowsError(
            try FeedRunConfiguration(geometry: geometry, frameCount: 0, stageCount: 1)
        )
    }

    func testStageCountIsClampedToTheLadder() throws {
        let geometry = try FeedGeometry(tileCount: 2, dimension: 2)
        let tooMany = try FeedRunConfiguration(geometry: geometry, frameCount: 1, stageCount: 99)
        XCTAssertEqual(tooMany.stages.count, FeedStageKind.ladder.count)
        let negative = try FeedRunConfiguration(geometry: geometry, frameCount: 1, stageCount: -3)
        XCTAssertEqual(negative.stages.count, 0)
    }

    func testLiveLimitOfOneRefusesAPipelineContainingAFold() {
        // `foldPairs` needs a source and a destination checked out at once, so a
        // live limit of one is genuinely unsatisfiable — and must surface as
        // backpressure rather than as a silently wrong result.
        XCTAssertThrowsError(
            try BoundaryBenchmark.compare(
                tileCount: 8, dimension: 8, frameCount: 3, stageCount: 6, poolLiveLimit: 1
            )
        ) { error in
            XCTAssertEqual(error as? FeedError, .poolExhausted(live: 1, limit: 1))
        }
    }

    func testLiveLimitOfTwoIsEnoughForAFold() throws {
        let comparison = try BoundaryBenchmark.compare(
            tileCount: 8, dimension: 8, frameCount: 3, stageCount: 6, poolLiveLimit: 2
        )
        XCTAssertTrue(comparison.outputsMatch)
        XCTAssertEqual(comparison.owning.peakLiveFrames, 2)
    }

    func testHeadlineDescribesTheRun() throws {
        let comparison = try BoundaryBenchmark.compare(
            tileCount: 32, dimension: 64, frameCount: 20, stageCount: 6
        )
        XCTAssertEqual(
            comparison.headline,
            "20 frames · 6 stages · 2 / 20 / 120 allocations (owning / consuming / borrowing)"
        )
    }
}
