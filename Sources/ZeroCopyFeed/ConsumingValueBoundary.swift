import Foundation

/// A stage on the **consuming value** boundary — the strongest form of the
/// value-in/value-out signature.
///
/// ## Why this type exists
///
/// The obvious comparison is `inout FrameStore` (owning) against
/// `FrameValue -> FrameValue` (value), and it makes the owning boundary look
/// like the only way to avoid per-stage allocation. That comparison is against
/// a strawman, and this protocol is the counter-example that proves it:
///
/// ```swift
/// func transform(_ input: borrowing FrameValue) -> FrameValue   // allocates, always
/// func transform(_ input: consuming FrameValue) -> FrameValue   // does not have to
/// ```
///
/// One keyword. The signature is still value-in/value-out, still `Sendable`,
/// still erases into `[any ConsumingValueFeedStage]`, still injectable and
/// mockable. But `consuming` ends the caller's ownership at the call, so the
/// array inside is uniquely referenced and the in-place mutation *does not*
/// trigger copy-on-write.
///
/// ## What this costs the headline claim
///
/// It costs it the dramatic version. Measured at 20 frames × 6 stages × 2 KB:
///
/// | boundary | allocations |
/// |---|---:|
/// | owning (`inout FrameStore`) | 2 |
/// | consuming value | 20 |
/// | borrowing value | 120 |
///
/// So erasure is *not* what costs you the copies — the ownership annotation on
/// the parameter is. What survives, and is the durable claim, is the **shape**:
/// the owning boundary's allocation count is constant in frame count; both value
/// boundaries are linear in it, because a size-changing stage has to produce new
/// storage and a value type has nowhere to recycle it to.
///
/// `ZeroCopyFeed` ships all three so the comparison is against the best
/// alternative rather than the most convenient one.
///
/// ## The build mode this is true in
///
/// **These numbers describe an optimised build.** `consuming` is a semantic
/// guarantee about ownership, not an instruction to the code generator: it
/// makes the array *provably* uniquely referenced at the mutation, and the ARC
/// optimiser is what then removes the retain that would otherwise make
/// copy-on-write fire. At `-Onone` that optimiser does not run, the retain
/// survives, and the consuming path allocates on every stage exactly like the
/// borrowing one — measured, in a debug build of this package, at the same
/// 20,750 `malloc` calls for both.
///
/// The ledger cannot see that difference, because it counts the allocations the
/// *library* asks for and this one is a copy-on-write copy the runtime makes on
/// the library's behalf. So the table above is a release-mode measurement, and
/// `swift test -c release` is what enforces it — the CI job runs both.
///
/// This is stated rather than buried because the package's own documentation
/// says the ledger reports "numbers that came out of here", and here is a case
/// where the ledger's number and the machine's number agree only at `-O`.
public protocol ConsumingValueFeedStage: Sendable {

    var kind: FeedStageKind { get }

    /// Applies the stage, taking ownership of `input`.
    func transform(
        _ input: consuming FrameValue,
        geometry: FeedGeometry,
        ledger: AllocationLedger?
    ) -> FrameValue
}

// MARK: - Concrete stages

/// `v' = clamp((v * numerator) / denominator)`, in place.
public struct ConsumingRequantizeStage: ConsumingValueFeedStage {
    public let kind: FeedStageKind
    public let numerator: Int
    public let denominator: Int

    public init(kind: FeedStageKind, numerator: Int, denominator: Int) {
        self.kind = kind
        self.numerator = numerator
        self.denominator = max(1, denominator)
    }

    public func transform(
        _ input: consuming FrameValue, geometry: FeedGeometry, ledger: AllocationLedger?
    ) -> FrameValue {
        // `input` is consumed, so this is the array's last reference: the
        // mutation below is semantically in place and the library asks for no
        // allocation, which is the whole point of the type. In an optimised
        // build no allocation happens at all. At `-Onone` the ARC optimiser
        // does not run, the extra retain survives, and copy-on-write fires
        // anyway — see the note on `ConsumingValueFeedStage`.
        var output = input.bytes
        output.withUnsafeMutableBufferPointer { buffer in
            FeedKernels.requantize(buffer, numerator: numerator, denominator: denominator)
        }
        return FrameValue(bytes: output)
    }
}

/// Per-tile mean removal, in place.
public struct ConsumingZeroCenterStage: ConsumingValueFeedStage {
    public let kind: FeedStageKind = .zeroCenter

    public init() {}

    public func transform(
        _ input: consuming FrameValue, geometry: FeedGeometry, ledger: AllocationLedger?
    ) -> FrameValue {
        var output = input.bytes
        output.withUnsafeMutableBufferPointer { buffer in
            FeedKernels.zeroCenter(buffer, dimension: geometry.dimension)
        }
        return FrameValue(bytes: output)
    }
}

/// Magnitude gate, in place.
public struct ConsumingGateStage: ConsumingValueFeedStage {
    public let kind: FeedStageKind
    public let threshold: Int

    public init(kind: FeedStageKind, threshold: Int) {
        self.kind = kind
        self.threshold = threshold
    }

    public func transform(
        _ input: consuming FrameValue, geometry: FeedGeometry, ledger: AllocationLedger?
    ) -> FrameValue {
        var output = input.bytes
        output.withUnsafeMutableBufferPointer { buffer in
            FeedKernels.gate(buffer, belowMagnitude: threshold)
        }
        return FrameValue(bytes: output)
    }
}

/// Pairwise tile fold — the one stage `consuming` cannot save.
///
/// The output is a different size from the input, so there is no in-place form.
/// A value type has nowhere to recycle the old buffer to, so this allocates once
/// per frame no matter how the parameter is annotated. It is the irreducible
/// gap between a value boundary and a pooled owning one.
public struct ConsumingFoldPairsStage: ConsumingValueFeedStage {
    public let kind: FeedStageKind = .foldPairs

    public init() {}

    public func transform(
        _ input: consuming FrameValue, geometry: FeedGeometry, ledger: AllocationLedger?
    ) -> FrameValue {
        let outputTiles = (geometry.tileCount + 1) / 2
        let outputCount = Saturating.multiply(max(1, outputTiles), geometry.dimension)
        guard outputCount > 0, outputCount <= Saturating.maximumElementCount else {
            return input
        }
        var output = [Int8](repeating: 0, count: outputCount)
        ledger?.recordAllocation(bytes: outputCount)
        input.bytes.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                _ = FeedKernels.foldPairs(
                    source: source,
                    destination: destination,
                    tileCount: geometry.tileCount,
                    dimension: geometry.dimension
                )
            }
        }
        return FrameValue(bytes: output)
    }
}

extension FeedStageKind {
    /// The consuming-value implementation of this stage.
    public func makeConsumingValueStage() -> any ConsumingValueFeedStage {
        switch self {
        case .requantizeUp:   return ConsumingRequantizeStage(kind: .requantizeUp, numerator: 3, denominator: 2)
        case .zeroCenter:     return ConsumingZeroCenterStage()
        case .gateWeak:       return ConsumingGateStage(kind: .gateWeak, threshold: 4)
        case .foldPairs:      return ConsumingFoldPairsStage()
        case .requantizeFine: return ConsumingRequantizeStage(kind: .requantizeFine, numerator: 5, denominator: 4)
        case .gateResidual:   return ConsumingGateStage(kind: .gateResidual, threshold: 2)
        }
    }
}

/// Runs a feed through the consuming value boundary.
public enum ConsumingValuePipeline {

    public static func run(
        configuration: FeedRunConfiguration,
        ledger: AllocationLedger
    ) throws -> BoundaryRunResult {
        try run(
            configuration: configuration,
            ledger: ledger,
            stages: configuration.stages.map { $0.makeConsumingValueStage() }
        )
    }

    /// Runs with caller-supplied stage implementations, so a test can substitute
    /// a deliberately wrong one.
    public static func run(
        configuration: FeedRunConfiguration,
        ledger: AllocationLedger,
        stages: [any ConsumingValueFeedStage]
    ) throws -> BoundaryRunResult {

        var combinedDigest: UInt64 = 0xcbf2_9ce4_8422_2325
        var finalGeometry = configuration.geometry

        for frameIndex in 0..<configuration.frameCount {
            let source = FeedKernels.syntheticFrame(
                byteCount: configuration.geometry.byteCount,
                seed: UInt64(truncatingIfNeeded: frameIndex)
            )
            var value = FrameValue(bytes: source)
            var geometry = configuration.geometry
            var chargedBytes: Int?

            for stage in stages {
                let produced = stage.transform(consume value, geometry: geometry, ledger: ledger)
                // Only the fold allocates, so only the fold replaces the buffer
                // that is currently charged — an in-place stage hands the same
                // storage straight back and nothing is released.
                //
                // Release is keyed on "a new allocation replaced it", not on
                // "the output size changed". Those look equivalent and are not:
                // two folds in a row produce the same size whenever
                // `tileCount == 1`, because `(1 + 1) / 2 == 1`. Keying on size
                // dropped the release in that case and made `isBalanced` report
                // a leak that did not exist, through the public `stages:`
                // injection point.
                if stage.kind == .foldPairs {
                    if let previous = chargedBytes {
                        ledger.recordDeallocation(bytes: previous)
                    }
                    chargedBytes = produced.count
                }
                value = produced
                geometry = try stage.kind.outputGeometry(from: geometry)
            }
            if let last = chargedBytes {
                ledger.recordDeallocation(bytes: last)
            }
            finalGeometry = geometry
            combinedDigest = (combinedDigest &* 0x0000_0100_0000_01B3) ^ value.digest()
        }

        return BoundaryRunResult(
            shape: .consumingValue,
            stats: ledger.stats,
            poolAllocationCount: nil,
            poolReuseCount: nil,
            peakLiveFrames: nil,
            combinedDigest: combinedDigest,
            framesProcessed: configuration.frameCount,
            finalGeometry: finalGeometry
        )
    }
}
