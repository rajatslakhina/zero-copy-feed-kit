import Foundation

/// The transforms a feed stage can apply to a batch of quantized embedding
/// tiles.
///
/// These are deliberately real, if small: integer requantisation, per-tile mean
/// removal, magnitude gating, and pairwise tile folding are the shapes that
/// actually appear between a capture buffer and an on-device model's input. Two
/// properties matter more than the arithmetic:
///
/// 1. Three of the four are **in-place** — the output is the same size as the
///    input, so an owning boundary can apply them with no destination buffer at
///    all, while a value boundary has to produce a new value regardless.
/// 2. One of them, ``foldPairs``, **changes the payload size**, which is the
///    case that forces a real destination buffer and is where a naive pool
///    design falls over.
public enum FeedStageKind: String, Sendable, CaseIterable, Codable {

    /// `v' = clamp((v * numerator) / denominator)` with numerator 3, denominator 2.
    case requantizeUp

    /// Subtracts each tile's integer mean from its own elements.
    case zeroCenter

    /// Zeroes elements whose magnitude is below 4.
    case gateWeak

    /// Averages adjacent tile pairs, halving the tile count.
    case foldPairs

    /// `v' = clamp((v * 5) / 4)`.
    case requantizeFine

    /// Zeroes elements whose magnitude is below 2.
    case gateResidual

    /// Whether this stage writes its output over its input.
    public var isInPlace: Bool {
        self != .foldPairs
    }

    /// A short label for UI.
    public var displayName: String {
        switch self {
        case .requantizeUp:    return "Requantize ×3/2"
        case .zeroCenter:      return "Zero-center"
        case .gateWeak:        return "Gate |v| < 4"
        case .foldPairs:       return "Fold tile pairs"
        case .requantizeFine:  return "Requantize ×5/4"
        case .gateResidual:    return "Gate |v| < 2"
        }
    }

    /// The canonical ladder. A pipeline of length *n* is the first *n* of these.
    public static let ladder: [FeedStageKind] = [
        .requantizeUp, .zeroCenter, .gateWeak, .foldPairs, .requantizeFine, .gateResidual
    ]

    /// The geometry this stage produces from `input`.
    ///
    /// - Throws: ``FeedError/invalidGeometry(reason:)`` if the folded geometry
    ///   is not constructible.
    public func outputGeometry(from input: FeedGeometry) throws -> FeedGeometry {
        guard self == .foldPairs else { return input }
        // Odd tile counts round up: the last unpaired tile passes through.
        let folded = (input.tileCount + 1) / 2
        return try FeedGeometry(tileCount: max(1, folded), dimension: input.dimension)
    }
}

/// The arithmetic itself, expressed once over raw buffers.
///
/// Both boundary shapes call exactly these functions on exactly these bytes.
/// That is what makes the comparison honest: the only difference between the
/// two pipelines is how the bytes get to the kernel, not what the kernel does.
public enum FeedKernels {

    /// In-place `v' = clamp((v * numerator) / denominator)`.
    ///
    /// `denominator` is clamped to at least 1 by the caller-facing stages, and
    /// the division goes through ``Saturating/divide(_:by:fallback:)`` so a zero
    /// slipping through is a no-op rather than a trap.
    public static func requantize(
        _ buffer: UnsafeMutableBufferPointer<Int8>,
        numerator: Int,
        denominator: Int
    ) {
        let safeDenominator = max(1, denominator)
        for index in buffer.indices {
            let scaled = Saturating.multiply(Int(buffer[index]), numerator)
            let divided = Saturating.divide(scaled, by: safeDenominator, fallback: 0)
            buffer[index] = Saturating.clampToInt8(divided)
        }
    }

    /// In-place per-tile mean removal.
    ///
    /// Tiles are `dimension` elements wide. A trailing partial tile — which a
    /// caller should not produce, but which costs nothing to tolerate — is
    /// centered on its own shorter mean rather than reading past the end.
    public static func zeroCenter(
        _ buffer: UnsafeMutableBufferPointer<Int8>,
        dimension: Int
    ) {
        guard dimension >= 1, buffer.count > 0 else { return }
        var start = 0
        while start < buffer.count {
            let end = min(start + dimension, buffer.count)
            let width = end - start
            var sum = 0
            for index in start..<end {
                sum = Saturating.add(sum, Int(buffer[index]))
            }
            let mean = Saturating.divide(sum, by: width, fallback: 0)
            for index in start..<end {
                buffer[index] = Saturating.clampToInt8(Int(buffer[index]) - mean)
            }
            start = end
        }
    }

    /// In-place magnitude gate.
    ///
    /// Uses ``Saturating/magnitude(ofInt8:)`` because `abs(Int8.min)` traps —
    /// a quantized feed reaches `-128` routinely, so this is not a theoretical
    /// edge case.
    public static func gate(
        _ buffer: UnsafeMutableBufferPointer<Int8>,
        belowMagnitude threshold: Int
    ) {
        for index in buffer.indices where Saturating.magnitude(ofInt8: buffer[index]) < threshold {
            buffer[index] = 0
        }
    }

    /// Averages adjacent tile pairs from `source` into `destination`.
    ///
    /// `destination` should hold `((tileCount + 1) / 2) * dimension` elements. An
    /// odd final tile is copied through unchanged.
    ///
    /// ## Totality
    ///
    /// `tileCount` and `dimension` arrive from a caller, not from a validated
    /// `FeedGeometry`, so this function treats them as hostile. Every index is
    /// computed with saturating arithmetic and then bounds-checked against the
    /// *real* buffer lengths:
    ///
    /// - `(tileCount + 1)` overflows at `Int.max`, which the `>= 1` guard does
    ///   not exclude — so the halving goes through ``Saturating``.
    /// - The per-tile offsets `tile * dimension` overflow for large-but-legal
    ///   `Int` arguments.
    /// - The inner loop is bounded by the destination's remaining length rather
    ///   than by `dimension`, so an absurd `dimension` truncates instead of
    ///   spinning.
    ///
    /// - Returns: the number of elements written.
    @discardableResult
    public static func foldPairs(
        source: UnsafeBufferPointer<Int8>,
        destination: UnsafeMutableBufferPointer<Int8>,
        tileCount: Int,
        dimension: Int
    ) -> Int {
        guard tileCount >= 1, dimension >= 1, destination.count > 0 else { return 0 }
        let outputTiles = Saturating.divide(Saturating.add(tileCount, 1), by: 2, fallback: 0)
        var written = 0
        for outputTile in 0..<outputTiles {
            let outBase = Saturating.multiply(outputTile, dimension)
            // The destination is the real limit on how much work exists. Once
            // it is full there is nothing left to write, however many tiles the
            // caller's geometry claims.
            guard outBase < destination.count else { break }
            let firstTile = Saturating.multiply(outputTile, 2)
            let secondTile = Saturating.add(firstTile, 1)
            let firstBase = Saturating.multiply(firstTile, dimension)
            let secondBase = Saturating.multiply(secondTile, dimension)
            let hasSecond = secondTile < tileCount
            let width = min(dimension, destination.count - outBase)
            for component in 0..<width {
                let outIndex = outBase + component
                let firstIndex = Saturating.add(firstBase, component)
                guard firstIndex < source.count else {
                    // The geometry promised a tile the source does not contain.
                    // Zero it rather than leaving whatever the recycled pool
                    // buffer happened to hold from a previous frame.
                    destination[outIndex] = 0
                    written = Saturating.add(written, 1)
                    continue
                }
                let first = Int(source[firstIndex])
                let secondIndex = Saturating.add(secondBase, component)
                if hasSecond, secondIndex < source.count {
                    let second = Int(source[secondIndex])
                    // Round-half-away-from-zero so the fold is symmetric about 0
                    // and does not bias a centered tile negative.
                    let total = Saturating.add(first, second)
                    let rounded = total >= 0
                        ? Saturating.divide(Saturating.add(total, 1), by: 2, fallback: 0)
                        : Saturating.divide(Saturating.add(total, -1), by: 2, fallback: 0)
                    destination[outIndex] = Saturating.clampToInt8(rounded)
                } else {
                    destination[outIndex] = Saturating.clampToInt8(first)
                }
                written = Saturating.add(written, 1)
            }
        }
        return written
    }

    // MARK: - Synthetic source

    /// Deterministic pseudo-random feed bytes.
    ///
    /// SplitMix64, seeded per frame index, so every run of the demo and every
    /// run of the test suite sees byte-identical input on both boundary shapes.
    /// A comparison fed by `random()` would prove nothing.
    public static func syntheticFrame(byteCount: Int, seed: UInt64) -> [Int8] {
        guard byteCount > 0 else { return [] }
        var state = seed &+ 0x9E37_79B9_7F4A_7C15
        var output = [Int8](repeating: 0, count: byteCount)
        for index in 0..<byteCount {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z = z ^ (z >> 31)
            output[index] = Int8(bitPattern: UInt8(truncatingIfNeeded: z))
        }
        return output
    }
}
