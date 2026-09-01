import XCTest
@testable import ZeroCopyFeed

final class KernelTests: XCTestCase {

    private func applying(
        _ input: [Int8],
        _ body: (UnsafeMutableBufferPointer<Int8>) -> Void
    ) -> [Int8] {
        var buffer = input
        buffer.withUnsafeMutableBufferPointer { body($0) }
        return buffer
    }

    // MARK: - requantize

    func testRequantizeProducesExactValuesAndSaturates() {
        let output = applying([0, 1, -1, 10, -10, 100, -100, Int8.max, Int8.min]) {
            FeedKernels.requantize($0, numerator: 3, denominator: 2)
        }
        // Swift integer division truncates toward zero, so -3/2 == -1.
        // Note the asymmetry at ±100: 150 clamps to 127 but -150 clamps to -128,
        // because Int8's range is not symmetric. A quantizer that assumed
        // symmetry would be off by one on every strongly negative component.
        XCTAssertEqual(output, [0, 1, -1, 15, -15, 127, -128, 127, -128])
    }

    func testRequantizeWithZeroDenominatorIsANoOpNotATrap() {
        // The stages clamp the denominator, but the kernel must be total on its
        // own: `x / 0` traps, and this is the path that would reach it.
        let output = applying([5, -5, 100]) {
            FeedKernels.requantize($0, numerator: 3, denominator: 0)
        }
        // Raised to 1, so the result is v * 3 clamped — not a division by zero.
        XCTAssertEqual(output, [15, -15, 127], "denominator 0 is raised to 1, not divided by")
    }

    func testRequantizeWithHugeNumeratorSaturatesInsteadOfOverflowing() {
        let output = applying([Int8.max, Int8.min, 0]) {
            FeedKernels.requantize($0, numerator: Int.max, denominator: 1)
        }
        XCTAssertEqual(output, [127, -128, 0])
    }

    // MARK: - zeroCenter

    func testZeroCenterRemovesTheTileMean() {
        let output = applying([1, 2, 3, 4, 10, 20, 30, 40]) {
            FeedKernels.zeroCenter($0, dimension: 4)
        }
        // Tile 0 mean = 10/4 = 2; tile 1 mean = 100/4 = 25.
        XCTAssertEqual(output, [-1, 0, 1, 2, -15, -5, 5, 15])
    }

    func testZeroCenterAtTheInt8Extremes() {
        let allMin = applying([Int8]( repeating: Int8.min, count: 4)) {
            FeedKernels.zeroCenter($0, dimension: 4)
        }
        XCTAssertEqual(allMin, [0, 0, 0, 0], "summing four -128s must not overflow Int8 arithmetic")

        let mixed = applying([Int8.min, Int8.max, Int8.min, Int8.max]) {
            FeedKernels.zeroCenter($0, dimension: 4)
        }
        // sum = -2, mean = 0 (truncating), so values pass through unchanged.
        XCTAssertEqual(mixed, [Int8.min, Int8.max, Int8.min, Int8.max])
    }

    func testZeroCenterHandlesARaggedFinalTile() {
        let output = applying([1, 2, 3, 4, 1, 2, 3]) {
            FeedKernels.zeroCenter($0, dimension: 4)
        }
        // The trailing 3-element tile is centered on its own mean (6/3 = 2),
        // not on a mean computed from bytes past the end.
        XCTAssertEqual(output, [-1, 0, 1, 2, -1, 0, 1])
    }

    func testZeroCenterWithDegenerateDimensionIsANoOp() {
        XCTAssertEqual(applying([1, 2, 3]) { FeedKernels.zeroCenter($0, dimension: 0) }, [1, 2, 3])
        XCTAssertEqual(applying([1, 2, 3]) { FeedKernels.zeroCenter($0, dimension: -4) }, [1, 2, 3])
        XCTAssertEqual(applying([]) { FeedKernels.zeroCenter($0, dimension: 4) }, [])
    }

    // MARK: - gate

    func testGateUsesWidenedMagnitudeSoInt8MinSurvives() {
        let output = applying([0, 3, -3, 4, -4, Int8.max, Int8.min]) {
            FeedKernels.gate($0, belowMagnitude: 4)
        }
        // -128 has magnitude 128. Computing that with `abs(Int8.min)` would trap
        // rather than return 128, which is why the kernel widens first.
        XCTAssertEqual(output, [0, 0, 0, 4, -4, 127, -128])
    }

    func testGateWithNonPositiveThresholdChangesNothing() {
        XCTAssertEqual(applying([0, 1, -1]) { FeedKernels.gate($0, belowMagnitude: 0) }, [0, 1, -1])
    }

    // MARK: - foldPairs

    private func folding(_ source: [Int8], tileCount: Int, dimension: Int, destinationCount: Int) -> ([Int8], Int) {
        var destination = [Int8](repeating: 0, count: destinationCount)
        var written = 0
        source.withUnsafeBufferPointer { input in
            destination.withUnsafeMutableBufferPointer { output in
                written = FeedKernels.foldPairs(
                    source: input, destination: output,
                    tileCount: tileCount, dimension: dimension
                )
            }
        }
        return (destination, written)
    }

    func testFoldPairsAveragesAdjacentTiles() {
        let (output, written) = folding([10, 20, 30, 40], tileCount: 2, dimension: 2, destinationCount: 2)
        XCTAssertEqual(output, [20, 30])
        XCTAssertEqual(written, 2)
    }

    func testFoldPairsPassesAnOddFinalTileThrough() {
        let (output, written) = folding(
            [10, 20, 30, 40, 50, 60], tileCount: 3, dimension: 2, destinationCount: 4
        )
        XCTAssertEqual(output, [20, 30, 50, 60], "the unpaired third tile is copied, not dropped or doubled")
        XCTAssertEqual(written, 4)
    }

    func testFoldPairsRoundsSymmetricallyAboutZero() {
        // Round-half-away-from-zero: +0.5 rounds up, -0.5 rounds down. A plain
        // `/ 2` would round both toward zero and bias a centered tile positive.
        let (positive, _) = folding([2, 3], tileCount: 2, dimension: 1, destinationCount: 1)
        XCTAssertEqual(positive, [3], "average of 2 and 3 is 2.5, which rounds away from zero to 3")
        let (negative, _) = folding([-2, -3], tileCount: 2, dimension: 1, destinationCount: 1)
        XCTAssertEqual(negative, [-3])
        let (wholeNegative, _) = folding([-2, -2], tileCount: 2, dimension: 1, destinationCount: 1)
        XCTAssertEqual(wholeNegative, [-2], "an exact average must not be nudged")
    }

    func testFoldPairsSaturatesAtTheInt8Extremes() {
        let (high, _) = folding([Int8.max, Int8.max], tileCount: 2, dimension: 1, destinationCount: 1)
        XCTAssertEqual(high, [127])
        let (low, _) = folding([Int8.min, Int8.min], tileCount: 2, dimension: 1, destinationCount: 1)
        XCTAssertEqual(low, [-128])
    }

    func testFoldPairsTruncatesRatherThanOverrunningAShortDestination() {
        // A geometry that disagrees with the real buffers must not write out of
        // bounds. It writes what fits and reports how much.
        let (output, written) = folding(
            [10, 20, 30, 40], tileCount: 2, dimension: 2, destinationCount: 1
        )
        XCTAssertEqual(output, [20])
        XCTAssertEqual(written, 1)
    }

    func testFoldPairsWithDegenerateGeometryWritesNothing() {
        XCTAssertEqual(folding([1, 2], tileCount: 0, dimension: 2, destinationCount: 2).1, 0)
        XCTAssertEqual(folding([1, 2], tileCount: 2, dimension: 0, destinationCount: 2).1, 0)
        XCTAssertEqual(folding([1, 2], tileCount: 2, dimension: 2, destinationCount: 0).1, 0)
    }

    func testFoldPairsSurvivesAnAbsurdGeometry() {
        // `(tileCount + 1) / 2` overflows at `Int.max`, and the per-tile offsets
        // `tile * dimension` overflow well before that. All of these used to
        // trap; the destination's length is now the real bound on the work.
        let (a, writtenA) = folding([1, 2, 3, 4], tileCount: Int.max, dimension: 1, destinationCount: 2)
        XCTAssertEqual(writtenA, 2)
        XCTAssertEqual(a.count, 2)

        let (_, writtenB) = folding([1, 2, 3, 4], tileCount: 2, dimension: Int.max, destinationCount: 2)
        XCTAssertEqual(writtenB, 2, "an absurd dimension truncates to the destination rather than spinning")

        let (_, writtenC) = folding([1, 2], tileCount: Int.max, dimension: Int.max, destinationCount: 1)
        XCTAssertEqual(writtenC, 1)
    }

    func testFoldPairsZeroesRatherThanLeavingStaleBytes() {
        // The geometry claims four tiles; the source only has one. On a recycled
        // pool buffer, skipping the write would surface a previous frame's bytes.
        var destination: [Int8] = [99, 99, 99, 99]
        var written = 0
        let source: [Int8] = [7, 7]
        source.withUnsafeBufferPointer { input in
            destination.withUnsafeMutableBufferPointer { output in
                written = FeedKernels.foldPairs(
                    source: input, destination: output, tileCount: 4, dimension: 2
                )
            }
        }
        XCTAssertEqual(written, 4)
        XCTAssertEqual(destination, [7, 7, 0, 0], "absent source tiles are zeroed, not left stale")
    }

    // MARK: - Synthetic source

    func testSyntheticFrameIsReproducibleAcrossProcesses() {
        // Hardcoded, not compared against a second in-process call — a
        // same-process comparison would pass even if the generator were seeded
        // from the clock, which is precisely the bug this guards.
        XCTAssertEqual(
            FeedKernels.syntheticFrame(byteCount: 8, seed: 0),
            [-12, 79, -20, -101, -22, -31, 60, -61]
        )
        XCTAssertEqual(
            FeedKernels.syntheticFrame(byteCount: 8, seed: 1),
            [103, 94, 11, -71, -128, -91, 117, -88]
        )
    }

    func testSyntheticFrameIsPrefixStableAndHandlesZeroLength() {
        let long = FeedKernels.syntheticFrame(byteCount: 16, seed: 0)
        let short = FeedKernels.syntheticFrame(byteCount: 8, seed: 0)
        XCTAssertEqual(Array(long.prefix(8)), short)
        XCTAssertEqual(FeedKernels.syntheticFrame(byteCount: 0, seed: 0), [])
        XCTAssertEqual(FeedKernels.syntheticFrame(byteCount: -5, seed: 0), [])
    }
}
