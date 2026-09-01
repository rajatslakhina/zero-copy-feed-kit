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

    /// A consuming stage that deep-copies instead of mutating in place — the
    /// exact opposite of the property this file exists to demonstrate.
    private struct CopyingConsumingGateStage: ConsumingValueFeedStage {
        let kind: FeedStageKind = .gateWeak

        func transform(
            _ input: consuming FrameValue, geometry: FeedGeometry, ledger: AllocationLedger?
        ) -> FrameValue {
            var output = [Int8](repeating: 0, count: input.bytes.count)
            ledger?.recordAllocation(bytes: output.count)
            for i in 0..<output.count { output[i] = input.bytes[i] }
            output.withUnsafeMutableBufferPointer { FeedKernels.gate($0, belowMagnitude: 4) }
            return FrameValue(bytes: output)
        }
    }

    private func baseAddress(of value: FrameValue) -> UInt {
        value.bytes.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
    }

    /// The real proof, and the one the ledger cannot give.
    ///
    /// An earlier version of this file asserted `allocationCount == 0` for a
    /// three-stage run. That assertion was **vacuous**: no in-place consuming
    /// stage calls `recordAllocation`, so `0 == 0` held for every possible
    /// implementation — including one that deep-copies on every stage. Replacing
    /// all three in-place stages with copying ones left the whole suite green.
    ///
    /// Buffer identity is the property that actually distinguishes them, so test
    /// that. It is also build-dependent: `consuming` guarantees unique ownership,
    /// but the ARC optimiser is what removes the retain that would make
    /// copy-on-write fire, and that optimiser does not run at `-Onone`. Asserting
    /// it in a debug build would be asserting something false, so the assertion
    /// is release-only and CI runs `swift test -c release` to reach it.
    func testConsumingStagesMutateTheirInputBufferInPlace() throws {
        #if DEBUG
        throw XCTSkip(
            "copy-on-write elision needs the ARC optimiser; this is a release-mode property. "
                + "Run `swift test -c release`."
        )
        #else
        let geometry = try FeedGeometry(tileCount: 16, dimension: 32)
        var value = FrameValue(bytes: FeedKernels.syntheticFrame(byteCount: geometry.byteCount, seed: 7))
        let original = baseAddress(of: value)

        for kind in [FeedStageKind.requantizeUp, .zeroCenter, .gateWeak] {
            value = kind.makeConsumingValueStage()
                .transform(consume value, geometry: geometry, ledger: nil)
            XCTAssertEqual(
                baseAddress(of: value), original,
                "\(kind) reallocated instead of mutating in place"
            )
        }

        // Negative control: the copying stage must move the buffer, or the check
        // above is measuring nothing.
        var copied = FrameValue(bytes: FeedKernels.syntheticFrame(byteCount: geometry.byteCount, seed: 7))
        let beforeCopy = baseAddress(of: copied)
        copied = CopyingConsumingGateStage()
            .transform(consume copied, geometry: geometry, ledger: nil)
        XCTAssertNotEqual(
            baseAddress(of: copied), beforeCopy,
            "the control did not reallocate, so the in-place assertions prove nothing"
        )
        #endif
    }

    func testALedgerZeroDoesNotByItselfProveAnythingAboutCopying() throws {
        // Kept as documentation of the shape, and honest about its own weakness:
        // this number is zero because no in-place stage charges the ledger, in
        // every build and for every implementation. The assertion below is a
        // change-detector for the wiring, not evidence of copy elision — the
        // control that follows is what makes it worth anything.
        let comparison = try BoundaryBenchmark.compare(
            tileCount: 16, dimension: 32, frameCount: 5, stageCount: 3
        )
        XCTAssertTrue(comparison.outputsMatch)
        XCTAssertEqual(comparison.consumingValue.stats.allocationCount, 0)
        XCTAssertEqual(comparison.value.stats.allocationCount, 15, "5 frames × 3 stages")
        XCTAssertEqual(comparison.owning.stats.allocationCount, 1)

        // Substitute one copying stage through the public injection point: the
        // ledger must now report it. If this passed at 0 too, the ledger would
        // not be measuring the pipeline at all.
        let geometry = try FeedGeometry(tileCount: 16, dimension: 32)
        let configuration = try FeedRunConfiguration(geometry: geometry, frameCount: 5, stageCount: 3)
        let ledger = AllocationLedger()
        _ = try ConsumingValuePipeline.run(
            configuration: configuration,
            ledger: ledger,
            stages: [
                FeedStageKind.requantizeUp.makeConsumingValueStage(),
                FeedStageKind.zeroCenter.makeConsumingValueStage(),
                CopyingConsumingGateStage()
            ]
        )
        XCTAssertEqual(ledger.stats.allocationCount, 5, "one copy per frame, and the ledger saw it")
    }

    func testRepeatedFoldsAtTheSameOutputSizeStayBalanced() throws {
        // `(1 + 1) / 2 == 1`, so two folds at `tileCount == 1` produce the same
        // size. An earlier version released the previous buffer only when the
        // size changed, so this configuration allocated three times and released
        // once and `isBalanced` reported a leak that was not there. Reachable
        // only through the public `stages:` parameter, which is exactly why that
        // parameter is public.
        let geometry = try FeedGeometry(tileCount: 1, dimension: 64)
        let configuration = try FeedRunConfiguration(geometry: geometry, frameCount: 3, stageCount: 0)

        for kinds in [
            [FeedStageKind.foldPairs, .foldPairs],
            [.foldPairs, .foldPairs, .foldPairs],
            [.foldPairs, .gateWeak, .foldPairs]
        ] {
            let ledger = AllocationLedger()
            _ = try ConsumingValuePipeline.run(
                configuration: configuration,
                ledger: ledger,
                stages: kinds.map { $0.makeConsumingValueStage() }
            )
            let stats = ledger.stats
            let folds = kinds.filter { $0 == .foldPairs }.count
            XCTAssertEqual(stats.allocationCount, folds * 3, "\(kinds): one per fold per frame")
            XCTAssertEqual(stats.deallocationCount, stats.allocationCount, "\(kinds) leaked a charge")
            XCTAssertEqual(stats.liveBytes, 0, "\(kinds)")
            XCTAssertTrue(stats.isBalanced, "\(kinds)")
        }
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
