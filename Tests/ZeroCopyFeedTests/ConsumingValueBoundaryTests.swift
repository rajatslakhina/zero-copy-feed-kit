import XCTest
@testable import ZeroCopyFeed

/// The counter-example, made permanent.
///
/// An earlier version of this package compared only `inout FrameStore` against
/// a *borrowing* `FrameValue -> FrameValue`, and concluded that erasure costs
/// you the copies. That conclusion was wrong, and these tests are what stops it
/// coming back: the same erased, injectable, `Sendable` signature with
/// `consuming` instead of `borrowing` allocates 6× less, and for a pipeline with
/// no size-changing stage it allocates **nothing at all**.
final class ConsumingValueBoundaryTests: XCTestCase {

    func testConsumingAvoidsCopyOnWriteEntirelyWhenNoStageChangesSize() throws {
        // Stages 1-3 of the ladder are all in-place. With `consuming`, the array
        // is uniquely referenced at the point of mutation, so copy-on-write never
        // fires and the whole run is allocation-free.
        let comparison = try BoundaryBenchmark.compare(
            tileCount: 16, dimension: 32, frameCount: 5, stageCount: 3
        )
        XCTAssertTrue(comparison.outputsMatch)
        XCTAssertEqual(
            comparison.consumingValue.stats.allocationCount, 0,
            "an erased value boundary CAN be allocation-free — this is the claim the "
                + "two-way comparison used to get wrong"
        )
        XCTAssertEqual(comparison.value.stats.allocationCount, 15, "5 frames × 3 stages")
        XCTAssertEqual(comparison.owning.stats.allocationCount, 1)
    }

    func testConsumingStillPaysOncePerFrameForTheSizeChangingStage() throws {
        // `foldPairs` produces a different-sized output, so there is no in-place
        // form and no pool to recycle into. This is the irreducible gap between
        // any value boundary and a pooled owning one — and it is the honest
        // reason the owning boundary still wins.
        let comparison = try BoundaryBenchmark.compare(
            tileCount: 32, dimension: 64, frameCount: 20, stageCount: 6
        )
        XCTAssertTrue(comparison.outputsMatch)
        XCTAssertEqual(comparison.owning.stats.allocationCount, 2)
        XCTAssertEqual(
            comparison.consumingValue.stats.allocationCount, 20,
            "exactly one per frame — the fold, and only the fold"
        )
        XCTAssertEqual(comparison.value.stats.allocationCount, 120)

        // 20 frames × one 1,024-byte folded output each.
        XCTAssertEqual(comparison.consumingValue.stats.bytesAllocated, 20 * 1024)
        XCTAssertEqual(comparison.consumingAllocationRatio, 10.0)
        XCTAssertEqual(comparison.allocationRatio, 60.0)
    }

    func testOnlyTheOwningBoundaryIsConstantInFrameCount() throws {
        // The durable claim, and the one that survives the counter-example:
        // owning is O(1) in frames; BOTH value shapes are O(frames).
        for frameCount in [1, 20, 200] {
            let comparison = try BoundaryBenchmark.compare(
                tileCount: 8, dimension: 16, frameCount: frameCount, stageCount: 6
            )
            XCTAssertEqual(comparison.owning.stats.allocationCount, 2,
                           "owning is flat at frameCount=\(frameCount)")
            XCTAssertEqual(comparison.consumingValue.stats.allocationCount, frameCount,
                           "consuming is linear at frameCount=\(frameCount)")
            XCTAssertEqual(comparison.value.stats.allocationCount, frameCount * 6,
                           "borrowing is linear × stages at frameCount=\(frameCount)")
            XCTAssertTrue(comparison.outputsMatch)
        }
    }

    func testAllThreeBoundariesAgreeByteForByte() throws {
        // The digest check inside `outputsMatch` is a 64-bit fold. This asserts
        // the stronger property directly, outside the measured region, so
        // "identical output" is not resting on a hash alone.
        let geometry = try FeedGeometry(tileCount: 6, dimension: 8)
        let configuration = try FeedRunConfiguration(geometry: geometry, frameCount: 4, stageCount: 6)
        let source = FeedKernels.syntheticFrame(byteCount: geometry.byteCount, seed: 0)

        // Owning path, materialised at the end.
        let ledger = AllocationLedger()
        let pool = FramePool(bufferCapacity: geometry.byteCount, retentionLimit: 2, ledger: ledger)
        var owningBytes: [Int8] = []
        do {
            var frame = try pool.acquire()
            try frame.write(source, ledger: nil)
            var running = geometry
            for kind in configuration.stages {
                switch kind {
                case .foldPairs:
                    let next = try kind.outputGeometry(from: running)
                    var destination = try pool.acquire()
                    try destination.resize(to: next.byteCount)
                    let tiles = running.tileCount
                    let dim = running.dimension
                    frame.withInt8 { s in
                        destination.withMutableInt8 { d in
                            _ = FeedKernels.foldPairs(source: s, destination: d, tileCount: tiles, dimension: dim)
                        }
                    }
                    frame = consume destination
                    running = next
                case .requantizeUp:
                    frame.withMutableInt8 { FeedKernels.requantize($0, numerator: 3, denominator: 2) }
                case .requantizeFine:
                    frame.withMutableInt8 { FeedKernels.requantize($0, numerator: 5, denominator: 4) }
                case .zeroCenter:
                    let dim = running.dimension
                    frame.withMutableInt8 { FeedKernels.zeroCenter($0, dimension: dim) }
                case .gateWeak:
                    frame.withMutableInt8 { FeedKernels.gate($0, belowMagnitude: 4) }
                case .gateResidual:
                    frame.withMutableInt8 { FeedKernels.gate($0, belowMagnitude: 2) }
                }
            }
            owningBytes = frame.snapshot()
        }
        pool.drain()

        // Consuming value path.
        var consumingValue = FrameValue(bytes: source)
        var consumingGeometry = geometry
        for kind in configuration.stages {
            consumingValue = kind.makeConsumingValueStage()
                .transform(consume consumingValue, geometry: consumingGeometry, ledger: nil)
            consumingGeometry = try kind.outputGeometry(from: consumingGeometry)
        }

        // Borrowing value path.
        var borrowingValue = FrameValue(bytes: source)
        var borrowingGeometry = geometry
        for kind in configuration.stages {
            borrowingValue = kind.makeValueStage()
                .transform(borrowingValue, geometry: borrowingGeometry, ledger: nil)
            borrowingGeometry = try kind.outputGeometry(from: borrowingGeometry)
        }

        XCTAssertFalse(owningBytes.isEmpty)
        XCTAssertEqual(consumingValue.bytes, owningBytes, "consuming value diverged from owning")
        XCTAssertEqual(borrowingValue.bytes, owningBytes, "borrowing value diverged from owning")
    }

    /// A deliberately wrong consuming stage — the sensitivity control for the
    /// three-way agreement above.
    private struct WrongConsumingGateStage: ConsumingValueFeedStage {
        let kind: FeedStageKind = .gateWeak

        func transform(
            _ input: consuming FrameValue, geometry: FeedGeometry, ledger: AllocationLedger?
        ) -> FrameValue {
            var output = input.bytes
            output.withUnsafeMutableBufferPointer { buffer in
                FeedKernels.gate(buffer, belowMagnitude: 5)  // correct value is 4
            }
            return FrameValue(bytes: output)
        }
    }

    func testOutputsMatchDetectsABrokenConsumingStage() throws {
        let geometry = try FeedGeometry(tileCount: 16, dimension: 32)
        let configuration = try FeedRunConfiguration(geometry: geometry, frameCount: 5, stageCount: 3)

        let owning = try OwningPipeline.run(configuration: configuration, ledger: AllocationLedger())
        let value = try ValuePipeline.run(configuration: configuration, ledger: AllocationLedger())

        let good = try ConsumingValuePipeline.run(configuration: configuration, ledger: AllocationLedger())
        XCTAssertTrue(
            BoundaryComparison(configuration: configuration, owning: owning,
                               consumingValue: good, value: value).outputsMatch,
            "baseline must agree or the control below proves nothing"
        )

        let brokenStages: [any ConsumingValueFeedStage] = [
            FeedStageKind.requantizeUp.makeConsumingValueStage(),
            FeedStageKind.zeroCenter.makeConsumingValueStage(),
            WrongConsumingGateStage()
        ]
        let broken = try ConsumingValuePipeline.run(
            configuration: configuration, ledger: AllocationLedger(), stages: brokenStages
        )
        let comparison = BoundaryComparison(
            configuration: configuration, owning: owning, consumingValue: broken, value: value
        )
        XCTAssertFalse(
            comparison.outputsMatch,
            "adding a third boundary must not weaken the equality gate — it has to check all three"
        )
        XCTAssertEqual(comparison.headline, "Outputs diverged — the comparison is not valid.")
    }

    func testConsumingPathEndsBalanced() throws {
        let comparison = try BoundaryBenchmark.compare(
            tileCount: 10, dimension: 10, frameCount: 15, stageCount: 6
        )
        XCTAssertTrue(comparison.consumingValue.stats.isBalanced, "consuming path accounting is unbalanced")
        XCTAssertEqual(comparison.consumingValue.stats.liveBytes, 0)
    }
}
