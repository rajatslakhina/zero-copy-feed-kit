import XCTest
@testable import ZeroCopyFeed

final class TileWalkTests: XCTestCase {

    private func batchedEnergies(_ bytes: [Int8], dimension: Int) -> [Int] {
        bytes.withUnsafeBufferPointer { TileWalk.tileEnergies(in: $0, dimension: dimension) }
    }

    func testBatchedWalkMatchesTheElementwiseReference() {
        // The batched walk exists to avoid per-element bookkeeping. It is only
        // allowed to do that if it computes the same answer, so it is pinned
        // against a deliberately naive implementation across ragged sizes.
        for byteCount in [1, 7, 8, 9, 63, 64, 65, 128] {
            for dimension in [1, 3, 8, 64] {
                let bytes = FeedKernels.syntheticFrame(byteCount: byteCount, seed: UInt64(byteCount))
                XCTAssertEqual(
                    batchedEnergies(bytes, dimension: dimension),
                    TileWalk.referenceTileEnergies(in: bytes, dimension: dimension),
                    "mismatch at byteCount=\(byteCount) dimension=\(dimension)"
                )
            }
        }
    }

    /// A deliberately broken batched walk: identical to the real one except that
    /// it drops the ragged final tile. This is what the sensitivity control
    /// below feeds in — a real *implementation* difference at identical
    /// parameters, which is the only kind that proves anything.
    private func brokenEnergiesDroppingRaggedTail(_ bytes: [Int8], dimension: Int) -> [Int] {
        guard dimension >= 1, !bytes.isEmpty else { return [] }
        let wholeTiles = bytes.count / dimension
        var energies = [Int](repeating: 0, count: wholeTiles)
        for tile in 0..<wholeTiles {
            var total = 0
            for offset in 0..<dimension {
                let widened = Int(bytes[tile * dimension + offset])
                total += widened * widened
            }
            energies[tile] = total
        }
        return energies
    }

    func testTheEqualityCheckIsSensitiveToARealImplementationDifference() {
        // 37 bytes at width 8 is four whole tiles plus a 5-element tail.
        let bytes = FeedKernels.syntheticFrame(byteCount: 37, seed: 3)
        let reference = TileWalk.referenceTileEnergies(in: bytes, dimension: 8)

        // Baseline: the real walk agrees, at these exact parameters.
        XCTAssertEqual(batchedEnergies(bytes, dimension: 8), reference)

        // Control: a wrong walk must disagree, at those same parameters. An
        // earlier version of this test compared *different* tile widths, which
        // made the arrays different lengths and so would have passed even if
        // both sides were literally the same function — a control that cannot
        // go red for the right reason.
        XCTAssertNotEqual(
            brokenEnergiesDroppingRaggedTail(bytes, dimension: 8),
            reference,
            "dropping the ragged tail must be detected; if it is not, the equality "
                + "check above is not testing the implementation"
        )
    }

    func testTileEnergiesAreExactForAKnownTile() {
        // Hardcoded, so the batched walk and its reference cannot both be wrong
        // in the same way and still agree.
        // 3² + 4² = 25, and (-5)² + 0² = 25.
        XCTAssertEqual(batchedEnergies([3, 4, -5, 0], dimension: 2), [25, 25])
        // Ragged tail: the third tile is one element wide, 1² = 1.
        XCTAssertEqual(batchedEnergies([3, 4, -5, 0, 1], dimension: 2), [25, 25, 1])
        XCTAssertEqual(TileWalk.referenceTileEnergies(in: [3, 4, -5, 0, 1], dimension: 2), [25, 25, 1])
    }

    func testWalksSurviveAnAbsurdDimension() {
        // `(count + dimension - 1) / dimension` overflows at `Int.max`, and
        // `start + dimension` overflows inside the walk. Both used to trap.
        let bytes: [Int8] = [1, 2, 3]
        XCTAssertEqual(batchedEnergies(bytes, dimension: Int.max), [1 + 4 + 9])
        XCTAssertEqual(TileWalk.referenceTileEnergies(in: bytes, dimension: Int.max), [1 + 4 + 9])
        var widths: [Int] = []
        bytes.withUnsafeBufferPointer { buffer in
            TileWalk.forEachTile(in: buffer, dimension: Int.max) { _, tile in
                widths.append(tile.count)
            }
        }
        XCTAssertEqual(widths, [3], "an absurd dimension yields one tile of everything, not a trap")
    }

    func testTileEnergiesHandleInt8MinWithoutTrapping() {
        // (-128)² = 16384. Squaring in Int8 would overflow; the kernel widens.
        XCTAssertEqual(batchedEnergies([Int8.min, Int8.min], dimension: 2), [32768])
        XCTAssertEqual(batchedEnergies([Int8.min], dimension: 1), [16384])
    }

    func testDegenerateInputsProduceEmptyResults() {
        XCTAssertEqual(batchedEnergies([], dimension: 8), [])
        XCTAssertEqual(batchedEnergies([1, 2, 3], dimension: 0), [])
        XCTAssertEqual(batchedEnergies([1, 2, 3], dimension: -1), [])
        XCTAssertEqual(TileWalk.referenceTileEnergies(in: [], dimension: 8), [])
        XCTAssertEqual(TileWalk.referenceTileEnergies(in: [1], dimension: 0), [])
    }

    func testWalkVisitsEveryByteExactlyOnceIncludingARaggedTail() {
        let bytes = FeedKernels.syntheticFrame(byteCount: 37, seed: 11)
        var visited: [Int8] = []
        var widths: [Int] = []
        bytes.withUnsafeBufferPointer { buffer in
            TileWalk.forEachTile(in: buffer, dimension: 8) { _, tile in
                widths.append(tile.count)
                visited.append(contentsOf: tile)
            }
        }
        XCTAssertEqual(visited, bytes, "every byte must be visited exactly once, in order")
        XCTAssertEqual(widths, [8, 8, 8, 8, 5], "the final tile reports its true, shorter width")
    }

    func testMutableWalkWritesThroughToTheOriginalBuffer() {
        var bytes: [Int8] = [1, 2, 3, 4, 5]
        bytes.withUnsafeMutableBufferPointer { buffer in
            TileWalk.forEachMutableTile(in: buffer, dimension: 2) { index, tile in
                for offset in tile.indices {
                    tile[offset] = Int8(clamping: index)
                }
            }
        }
        XCTAssertEqual(bytes, [0, 0, 1, 1, 2], "tiles are views of the buffer, not copies of it")
    }

    func testMutableWalkOnEmptyBufferIsANoOp() {
        var bytes: [Int8] = []
        var callCount = 0
        bytes.withUnsafeMutableBufferPointer { buffer in
            TileWalk.forEachMutableTile(in: buffer, dimension: 4) { _, _ in callCount += 1 }
        }
        XCTAssertEqual(callCount, 0)
    }
}
