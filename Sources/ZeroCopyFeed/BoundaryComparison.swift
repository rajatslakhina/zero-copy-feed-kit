import Foundation

/// Which of the three boundary shapes a run represents.
public enum BoundaryShape: String, Sendable, Codable, CaseIterable {
    /// `inout FrameStore` — noncopyable, pool-backed, statically dispatched.
    case owning
    /// `consuming FrameValue -> FrameValue` — copyable and erasable, but
    /// ownership ends at the call, so in-place stages do not copy.
    case consumingValue
    /// `borrowing FrameValue -> FrameValue` — the default value signature.
    /// Copy-on-write fires at every stage because the input outlives the call.
    case value

    public var displayName: String {
        switch self {
        case .owning:         return "Owning boundary"
        case .consumingValue: return "Consuming value"
        case .value:          return "Borrowing value"
        }
    }

    /// The parameter annotation that defines this shape — the whole difference
    /// between the two value rows is this one keyword.
    public var signature: String {
        switch self {
        case .owning:         return "inout FrameStore"
        case .consumingValue: return "consuming FrameValue"
        case .value:          return "borrowing FrameValue"
        }
    }
}

/// What one pipeline run cost and what it produced.
public struct BoundaryRunResult: Sendable, Equatable {

    public let shape: BoundaryShape
    public let stats: LedgerStats

    /// Allocations counted by the pool itself, independent of the ledger.
    /// `nil` on the value path, which has no pool.
    ///
    /// Kept deliberately: a harness that both performs and reports its own
    /// measurements can be wrong in the same direction twice. The pool counts
    /// allocations because it makes them, not because it was asked to report
    /// them, so `poolAllocationCount == stats.allocationCount` is a real
    /// cross-check and the test suite asserts it.
    public let poolAllocationCount: Int?
    public let poolReuseCount: Int?
    public let peakLiveFrames: Int?

    /// FNV-1a/64 fold over every frame's final bytes.
    public let combinedDigest: UInt64
    public let framesProcessed: Int
    public let finalGeometry: FeedGeometry

    public init(
        shape: BoundaryShape,
        stats: LedgerStats,
        poolAllocationCount: Int?,
        poolReuseCount: Int?,
        peakLiveFrames: Int?,
        combinedDigest: UInt64,
        framesProcessed: Int,
        finalGeometry: FeedGeometry
    ) {
        self.shape = shape
        self.stats = stats
        self.poolAllocationCount = poolAllocationCount
        self.poolReuseCount = poolReuseCount
        self.peakLiveFrames = peakLiveFrames
        self.combinedDigest = combinedDigest
        self.framesProcessed = framesProcessed
        self.finalGeometry = finalGeometry
    }
}

/// Everything a run needs. Validated at construction, so nothing downstream has
/// to re-check geometry or clamp a slider value.
public struct FeedRunConfiguration: Sendable, Equatable {

    public let geometry: FeedGeometry
    public let frameCount: Int
    public let stages: [FeedStageKind]
    public let poolRetentionLimit: Int
    public let poolLiveLimit: Int?

    /// - Parameters:
    ///   - stageCount: how many stages of ``FeedStageKind/ladder`` to run.
    ///     Clamped to `0...FeedStageKind.ladder.count`.
    ///   - poolRetentionLimit: free-list size. Two is the meaningful minimum for
    ///     a pipeline containing `foldPairs`, which needs a source and a
    ///     destination live at once.
    /// - Throws: ``FeedError/invalidGeometry(reason:)`` when `frameCount` is
    ///   below one.
    public init(
        geometry: FeedGeometry,
        frameCount: Int,
        stageCount: Int,
        poolRetentionLimit: Int = 2,
        poolLiveLimit: Int? = nil
    ) throws {
        guard frameCount >= 1 else {
            throw FeedError.invalidGeometry(reason: "frameCount must be at least 1, got \(frameCount)")
        }
        let clampedStages = min(max(0, stageCount), FeedStageKind.ladder.count)
        self.geometry = geometry
        self.frameCount = frameCount
        self.stages = Array(FeedStageKind.ladder.prefix(clampedStages))
        self.poolRetentionLimit = max(0, poolRetentionLimit)
        self.poolLiveLimit = poolLiveLimit
    }
}

/// The head-to-head result.
public struct BoundaryComparison: Sendable, Equatable {

    public let configuration: FeedRunConfiguration
    public let owning: BoundaryRunResult

    /// The **strongest** value-boundary design: same erased, injectable
    /// signature, but `consuming` instead of `borrowing`. Included because a
    /// comparison against only ``value`` is a comparison against a strawman.
    public let consumingValue: BoundaryRunResult

    /// The *default* value-boundary design — what you get from
    /// `func transform(_ input: FrameValue) -> FrameValue` without thinking
    /// about ownership.
    public let value: BoundaryRunResult

    public init(
        configuration: FeedRunConfiguration,
        owning: BoundaryRunResult,
        consumingValue: BoundaryRunResult,
        value: BoundaryRunResult
    ) {
        self.configuration = configuration
        self.owning = owning
        self.consumingValue = consumingValue
        self.value = value
    }

    /// All three runs, in table order.
    public var allResults: [BoundaryRunResult] { [owning, consumingValue, value] }

    /// True when all three boundaries produced the same output **digest** for
    /// every frame, over the same geometry and the same frame count.
    ///
    /// Stated as "digest" rather than "byte-identical" because that is what was
    /// compared: a 64-bit FNV-1a fold, chosen so neither path has to materialise
    /// an array inside the measured region. For a byte-level comparison, call
    /// `FrameStore.snapshot()` outside the measured region — `FrameStoreTests`
    /// does exactly that.
    ///
    /// This is the load-bearing check. Without it the allocation numbers below
    /// are meaningless, because a path that skips work allocates less for
    /// uninteresting reasons.
    public var outputsMatch: Bool {
        allResults.allSatisfy {
            $0.combinedDigest == owning.combinedDigest
                && $0.finalGeometry == owning.finalGeometry
                && $0.framesProcessed == owning.framesProcessed
        }
    }

    /// How many times more heap allocations the **default** (borrowing) value
    /// boundary made. `nil` rather than a division by zero when the owning path
    /// made none — which happens for a zero-stage configuration.
    public var allocationRatio: Double? { ratio(of: value) }

    /// How many times more heap allocations the **consuming** value boundary
    /// made. This is the honest comparison: it is what you get from someone who
    /// reached for `consuming`, and it is the number the argument has to
    /// survive.
    public var consumingAllocationRatio: Double? { ratio(of: consumingValue) }

    private func ratio(of result: BoundaryRunResult) -> Double? {
        let denominator = owning.stats.allocationCount
        guard denominator > 0 else { return nil }
        return Double(result.stats.allocationCount) / Double(denominator)
    }

    /// Allocations the owning boundary avoided versus the default value shape.
    public var allocationsAvoided: Int {
        max(0, value.stats.allocationCount - owning.stats.allocationCount)
    }

    /// Payload bytes the owning boundary never had to write to fresh memory,
    /// versus the default value shape.
    public var bytesAvoided: Int {
        max(0, value.stats.bytesAllocated - owning.stats.bytesAllocated)
    }

    /// A one-line summary suitable for a log or a UI caption.
    ///
    /// Reports all three, because reporting only the extremes is how a
    /// benchmark quietly becomes an advertisement.
    public var headline: String {
        guard outputsMatch else {
            return "Outputs diverged — the comparison is not valid."
        }
        return "\(configuration.frameCount) frames · \(configuration.stages.count) stages · "
            + "\(owning.stats.allocationCount) / \(consumingValue.stats.allocationCount) / "
            + "\(value.stats.allocationCount) allocations (owning / consuming / borrowing)"
    }
}

/// Runs the same feed through all three boundaries and reports the difference.
public enum BoundaryBenchmark {

    /// Each shape gets its own ledger so none can contaminate another's
    /// counters; the *configuration* and the kernels are shared, which is what
    /// makes the comparison fair.
    ///
    /// - Throws: any ``FeedError`` raised by any pipeline — notably
    ///   ``FeedError/poolExhausted(live:limit:)`` when the configured live limit
    ///   is too small for a pipeline containing `foldPairs`.
    public static func compare(configuration: FeedRunConfiguration) throws -> BoundaryComparison {
        let owningLedger = AllocationLedger()
        let consumingLedger = AllocationLedger()
        let valueLedger = AllocationLedger()

        let owning = try OwningPipeline.run(configuration: configuration, ledger: owningLedger)
        let consuming = try ConsumingValuePipeline.run(configuration: configuration, ledger: consumingLedger)
        let value = try ValuePipeline.run(configuration: configuration, ledger: valueLedger)

        return BoundaryComparison(
            configuration: configuration,
            owning: owning,
            consumingValue: consuming,
            value: value
        )
    }

    /// Convenience for callers holding raw slider values.
    public static func compare(
        tileCount: Int,
        dimension: Int,
        frameCount: Int,
        stageCount: Int,
        poolRetentionLimit: Int = 2,
        poolLiveLimit: Int? = nil
    ) throws -> BoundaryComparison {
        let geometry = try FeedGeometry(tileCount: tileCount, dimension: dimension)
        let configuration = try FeedRunConfiguration(
            geometry: geometry,
            frameCount: frameCount,
            stageCount: stageCount,
            poolRetentionLimit: poolRetentionLimit,
            poolLiveLimit: poolLiveLimit
        )
        return try compare(configuration: configuration)
    }
}
