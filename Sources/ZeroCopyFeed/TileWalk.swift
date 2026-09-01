import Foundation

/// Batched borrowing over a frame's tiles.
///
/// ## What this stands in for
///
/// SE-0516's `Iterable` would hand a `for` loop a *span* of elements to borrow
/// in batches rather than yielding one element at a time, which is how a loop
/// over a container stops paying per-element bookkeeping. (SE-0516 is
/// **accepted**, not yet in a shipped release — unlike SE-0507's `borrow` /
/// `mutate` accessors, which are implemented in Swift 6.4.) `TileWalk` is that
/// idea at the granularity this feed actually has: the natural batch is one
/// embedding tile, not one byte, and every kernel worth writing wants the whole
/// tile in hand.
///
/// The API is a scoped closure taking an `UnsafeBufferPointer` slice because
/// that is what Swift 6.0 can express safely. If and when `Iterable` and
/// non-escapable `Span` ship, the same call sites become an ordinary `for` loop
/// and the unsafe pointer disappears — the batching decision, which is the part
/// that matters, does not change.
///
/// ## The invariant
///
/// A batched walk must produce exactly what an element-at-a-time walk produces.
/// `TileWalkTests` pins that against a deliberately naive reference
/// implementation, including the ragged final tile.
public enum TileWalk {

    /// Visits each complete-or-partial tile of `buffer` in order.
    ///
    /// A trailing partial tile is visited with its true, shorter length rather
    /// than being skipped or padded, so the walk never reads past the end.
    ///
    /// - Parameters:
    ///   - buffer: the frame's valid bytes.
    ///   - dimension: tile width in elements. Values below one make this a no-op
    ///     rather than an infinite loop.
    ///   - body: receives the tile index and a borrowed view of that tile.
    @inlinable
    public static func forEachTile(
        in buffer: UnsafeBufferPointer<Int8>,
        dimension: Int,
        _ body: (Int, UnsafeBufferPointer<Int8>) throws -> Void
    ) rethrows {
        guard dimension >= 1, buffer.count > 0 else { return }
        var start = 0
        var tileIndex = 0
        while start < buffer.count {
            // `start + dimension` overflows for a `dimension` near `Int.max`,
            // which the `>= 1` guard does not exclude.
            let end = min(Saturating.add(start, dimension), buffer.count)
            // `baseAddress` is non-nil because `buffer.count > 0` was checked
            // above; the `if let` is here so a debug build of an empty buffer
            // degrades to a no-op instead of trapping.
            if let base = buffer.baseAddress {
                let tile = UnsafeBufferPointer(start: base + start, count: end - start)
                try body(tileIndex, tile)
            }
            start = end
            tileIndex += 1
        }
    }

    /// Mutable counterpart of ``forEachTile(in:dimension:_:)``.
    @inlinable
    public static func forEachMutableTile(
        in buffer: UnsafeMutableBufferPointer<Int8>,
        dimension: Int,
        _ body: (Int, UnsafeMutableBufferPointer<Int8>) throws -> Void
    ) rethrows {
        guard dimension >= 1, buffer.count > 0 else { return }
        var start = 0
        var tileIndex = 0
        while start < buffer.count {
            let end = min(Saturating.add(start, dimension), buffer.count)
            // Same reasoning as `forEachTile(in:dimension:_:)`: `baseAddress` is
            // non-nil because `buffer.count > 0` was checked above, and the
            // `if let` keeps an empty buffer a no-op rather than a trap.
            if let base = buffer.baseAddress {
                let tile = UnsafeMutableBufferPointer(start: base + start, count: end - start)
                try body(tileIndex, tile)
            }
            start = end
            tileIndex += 1
        }
    }

    /// Squared L2 norm of every tile, computed by a batched walk.
    ///
    /// Squared rather than square-rooted so the result stays exact integer
    /// arithmetic — a float here would make the two boundary shapes' outputs
    /// comparable only up to a tolerance, and "up to a tolerance" is not a
    /// property this package wants to claim.
    ///
    /// The result array is the one allocation this function makes, and it is
    /// proportional to the tile count, not to the payload size.
    public static func tileEnergies(
        in buffer: UnsafeBufferPointer<Int8>,
        dimension: Int
    ) -> [Int] {
        guard dimension >= 1, buffer.count > 0 else { return [] }
        // `buffer.count + dimension - 1` overflows for a `dimension` near
        // `Int.max`. The result is then clamped to `buffer.count`, which is the
        // true upper bound on how many tiles a buffer can contain.
        let ceiling = Saturating.divide(
            Saturating.add(buffer.count, dimension - 1), by: dimension, fallback: 0
        )
        let tileCount = min(max(0, ceiling), buffer.count)
        var energies = [Int](repeating: 0, count: tileCount)
        forEachTile(in: buffer, dimension: dimension) { index, tile in
            guard index < energies.count else { return }
            var total = 0
            for element in tile {
                let widened = Int(element)
                total = Saturating.add(total, Saturating.multiply(widened, widened))
            }
            energies[index] = total
        }
        return energies
    }

    /// The deliberately naive reference: one element at a time, no batching.
    ///
    /// Exists only so the batched walk has something independent to be equal to.
    /// If you find yourself tempted to make this faster, it has stopped being a
    /// reference implementation.
    public static func referenceTileEnergies(
        in bytes: [Int8],
        dimension: Int
    ) -> [Int] {
        guard dimension >= 1, !bytes.isEmpty else { return [] }
        // Same overflow guard as the batched walk. A reference implementation is
        // allowed to be slow; it is not allowed to be the one that crashes.
        let ceiling = Saturating.divide(
            Saturating.add(bytes.count, dimension - 1), by: dimension, fallback: 0
        )
        let tileCount = min(max(0, ceiling), bytes.count)
        var energies = [Int](repeating: 0, count: tileCount)
        for index in 0..<bytes.count {
            let tile = index / dimension
            guard tile < energies.count else { continue }
            let widened = Int(bytes[index])
            energies[tile] = Saturating.add(energies[tile], Saturating.multiply(widened, widened))
        }
        return energies
    }
}

extension FrameStore {
    /// Squared L2 norm of each tile in this frame, without materialising the
    /// frame into an array first.
    public borrowing func tileEnergies(dimension: Int) -> [Int] {
        withInt8 { TileWalk.tileEnergies(in: $0, dimension: dimension) }
    }
}
