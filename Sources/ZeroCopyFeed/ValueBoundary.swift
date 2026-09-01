import Foundation

/// One feed payload as an ordinary Swift value.
///
/// This is the boundary shape almost every codebase reaches for first, and it
/// is a perfectly good one: `Sendable`, `Equatable`, easy to log, easy to test,
/// crosses actor boundaries for free. The cost is invisible at the call site,
/// which is the whole problem — see ``ValueFeedStage``.
public struct FrameValue: Sendable, Equatable {

    public let bytes: [Int8]

    public init(bytes: [Int8]) {
        self.bytes = bytes
    }

    public var count: Int { bytes.count }

    /// FNV-1a/64 over the payload, comparable with `FrameStore.digest()`.
    public func digest() -> UInt64 {
        fnv1a64(bytes)
    }
}

/// A stage on the value boundary.
///
/// The signature is the point. `transform` takes a value and returns a value,
/// which means it is *obliged* to produce new storage: `input` is still alive at
/// the point of mutation, so `var copy = input.bytes` triggers copy-on-write,
/// and a size-changing stage has to allocate outright. There is no way to write
/// this signature such that a stage reuses the caller's buffer, because the
/// signature does not give the stage the caller's buffer — it gives it a value.
///
/// Note what this shape buys, because it is not nothing: `any ValueFeedStage`
/// is a real existential, so stages compose into an array, are injectable, and
/// are trivially `Sendable`. The owning boundary cannot do that (see
/// ``OwningPipeline``). That is the trade this package exists to price.
public protocol ValueFeedStage: Sendable {

    var kind: FeedStageKind { get }

    /// Applies the stage. Implementations record every allocation they cause on
    /// `ledger`, so the value path is measured by exactly the same instrument as
    /// the owning path.
    func transform(_ input: FrameValue, geometry: FeedGeometry, ledger: AllocationLedger?) -> FrameValue
}

// MARK: - Concrete stages

/// `v' = clamp((v * numerator) / denominator)`.
public struct ValueRequantizeStage: ValueFeedStage {
    public let kind: FeedStageKind
    public let numerator: Int
    public let denominator: Int

    public init(kind: FeedStageKind, numerator: Int, denominator: Int) {
        self.kind = kind
        self.numerator = numerator
        self.denominator = max(1, denominator)
    }

    public func transform(_ input: FrameValue, geometry: FeedGeometry, ledger: AllocationLedger?) -> FrameValue {
        var output = input.bytes
        // `input` is still alive here, so the buffer is shared and this mutation
        // is a genuine copy-on-write allocation of `output.count` bytes — not an
        // artefact of the measurement.
        ledger?.recordAllocation(bytes: output.count)
        output.withUnsafeMutableBufferPointer { buffer in
            FeedKernels.requantize(buffer, numerator: numerator, denominator: denominator)
        }
        return FrameValue(bytes: output)
    }
}

/// Per-tile mean removal.
public struct ValueZeroCenterStage: ValueFeedStage {
    public let kind: FeedStageKind = .zeroCenter

    public init() {}

    public func transform(_ input: FrameValue, geometry: FeedGeometry, ledger: AllocationLedger?) -> FrameValue {
        var output = input.bytes
        ledger?.recordAllocation(bytes: output.count)
        output.withUnsafeMutableBufferPointer { buffer in
            FeedKernels.zeroCenter(buffer, dimension: geometry.dimension)
        }
        return FrameValue(bytes: output)
    }
}

/// Magnitude gate.
public struct ValueGateStage: ValueFeedStage {
    public let kind: FeedStageKind
    public let threshold: Int

    public init(kind: FeedStageKind, threshold: Int) {
        self.kind = kind
        self.threshold = threshold
    }

    public func transform(_ input: FrameValue, geometry: FeedGeometry, ledger: AllocationLedger?) -> FrameValue {
        var output = input.bytes
        ledger?.recordAllocation(bytes: output.count)
        output.withUnsafeMutableBufferPointer { buffer in
            FeedKernels.gate(buffer, belowMagnitude: threshold)
        }
        return FrameValue(bytes: output)
    }
}

/// Pairwise tile fold. The one stage whose output is a different size.
public struct ValueFoldPairsStage: ValueFeedStage {
    public let kind: FeedStageKind = .foldPairs

    public init() {}

    public func transform(_ input: FrameValue, geometry: FeedGeometry, ledger: AllocationLedger?) -> FrameValue {
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
    /// The value-boundary implementation of this stage.
    public func makeValueStage() -> any ValueFeedStage {
        switch self {
        case .requantizeUp:   return ValueRequantizeStage(kind: .requantizeUp, numerator: 3, denominator: 2)
        case .zeroCenter:     return ValueZeroCenterStage()
        case .gateWeak:       return ValueGateStage(kind: .gateWeak, threshold: 4)
        case .foldPairs:      return ValueFoldPairsStage()
        case .requantizeFine: return ValueRequantizeStage(kind: .requantizeFine, numerator: 5, denominator: 4)
        case .gateResidual:   return ValueGateStage(kind: .gateResidual, threshold: 2)
        }
    }
}

/// Runs a feed through the value boundary.
public enum ValuePipeline {

    /// - Returns: the run's measurements and a combined digest of every frame's
    ///   final bytes.
    public static func run(
        configuration: FeedRunConfiguration,
        ledger: AllocationLedger
    ) throws -> BoundaryRunResult {
        try run(
            configuration: configuration,
            ledger: ledger,
            stages: configuration.stages.map { $0.makeValueStage() }
        )
    }

    /// Runs with caller-supplied stage implementations.
    ///
    /// This is the extension point the value boundary gets and the owning
    /// boundary does not: because ``FrameValue`` is copyable, stages erase to
    /// `any ValueFeedStage` and a caller can substitute their own. The test
    /// suite uses it to run a *deliberately wrong* stage and confirm the
    /// output-equality check actually fails — a check that only ever passes is
    /// not a check.
    ///
    /// - Parameter stages: applied in order. Geometry is advanced using each
    ///   stage's `kind`, so a substituted stage must report the `kind` whose
    ///   geometry contract it honours.
    public static func run(
        configuration: FeedRunConfiguration,
        ledger: AllocationLedger,
        stages: [any ValueFeedStage]
    ) throws -> BoundaryRunResult {

        var combinedDigest: UInt64 = 0xcbf2_9ce4_8422_2325
        var finalGeometry = configuration.geometry

        for frameIndex in 0..<configuration.frameCount {
            // The capture buffer exists whichever boundary you choose, so it is
            // charged to neither path. Measurement starts at the first stage.
            let source = FeedKernels.syntheticFrame(
                byteCount: configuration.geometry.byteCount,
                seed: UInt64(truncatingIfNeeded: frameIndex)
            )
            var value = FrameValue(bytes: source)
            var geometry = configuration.geometry

            // Buffers on this path are freed by ARC, which the ledger cannot
            // observe directly — so the pipeline models it explicitly. When a
            // stage's output replaces `value`, the previous buffer's last
            // reference drops and it is freed; recording that keeps
            // `liveBytes` and `peakLiveBytes` meaningful on both paths, and
            // makes `isBalanced` a real check here too rather than a number
            // that only ever grows. The capture buffer is not charged, so its
            // release is not recorded either.
            var chargedBytes: Int?

            for stage in stages {
                value = stage.transform(value, geometry: geometry, ledger: ledger)
                if let previous = chargedBytes {
                    ledger.recordDeallocation(bytes: previous)
                }
                chargedBytes = value.count
                geometry = try stage.kind.outputGeometry(from: geometry)
            }
            if let last = chargedBytes {
                ledger.recordDeallocation(bytes: last)
            }
            finalGeometry = geometry
            combinedDigest = (combinedDigest &* 0x0000_0100_0000_01B3) ^ value.digest()
        }

        return BoundaryRunResult(
            shape: .value,
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
