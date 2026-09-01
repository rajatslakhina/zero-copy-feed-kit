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

    func testTheEqualityCheckIsSensitiveToTheWalkBeingWrong() {
        // Negative control for the test above. If `tileEnergies` and
        // `referenceTileEnergies` were both wrong in the same way — or if they
        // were the same function — the comparison would prove nothing. Feeding
        // them different tile widths must make them disagree.
        let bytes = FeedKernels.syntheticFrame(byteCount: 64, seed: 3)
        XCTAssertNotEqual(
            batchedEnergies(bytes, dimension: 8),
            TileWalk.referenceTileEnergies(in: bytes, dimension: 16)
        )
    }

    func testTileEnergiesAreExactForAKnownTile() {
        // 3² + 4² = 25, and (-5)² = 25.
        XCTAssertEqual(batchedEnergies([3, 4, -5, 0], dimension: 2), [25, 25])
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
