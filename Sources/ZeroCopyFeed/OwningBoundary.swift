import Foundation

/// Runs a feed through the owning boundary.
///
/// ## Why this is an enum with a `switch` and not `[any FeedStage]`
///
/// The owning boundary hands each stage `inout FrameStore` — exclusive access to
/// pool-owned storage, no copy. That is what makes it zero-copy, and it is also
/// what makes the stage list un-erasable: `FrameStore` is `~Copyable`, so a
/// protocol whose requirement takes it cannot be boxed into the kind of
/// heterogeneous, injectable `[any Stage]` array the value boundary gets for
/// free.
///
/// This is the module-boundary decision the package is about, stated as
/// concretely as it can be stated: **you can have erased, composable,
/// dependency-injected stages, or you can have zero copies. Choosing one costs
/// you the other, and the choice is made by the shape of the function signature
/// long before anyone profiles anything.** Dispatching over a closed
/// ``FeedStageKind`` enum is the price paid here — a closed set of stages, no
/// third-party extension point, resolved statically.
public enum OwningPipeline {

    public static func run(
        configuration: FeedRunConfiguration,
        ledger: AllocationLedger
    ) throws -> BoundaryRunResult {

        let pool = FramePool(
            bufferCapacity: configuration.geometry.byteCount,
            retentionLimit: configuration.poolRetentionLimit,
            liveLimit: configuration.poolLiveLimit,
            ledger: ledger
        )
        defer { pool.drain() }

        var combinedDigest: UInt64 = 0xcbf2_9ce4_8422_2325
        var finalGeometry = configuration.geometry

        for frameIndex in 0..<configuration.frameCount {
            let source = FeedKernels.syntheticFrame(
                byteCount: configuration.geometry.byteCount,
                seed: UInt64(truncatingIfNeeded: frameIndex)
            )

            var frame = try pool.acquire()
            // The one boundary copy the owning path pays: bytes entering the
            // zero-copy world from an ordinary Swift value. Paid once per frame,
            // not once per stage — that difference is the entire argument.
            try frame.write(source, ledger: ledger)

            var geometry = configuration.geometry
            for kind in configuration.stages {
                geometry = try apply(kind, to: &frame, geometry: geometry, pool: pool)
            }
            finalGeometry = geometry
            combinedDigest = (combinedDigest &* 0x0000_0100_0000_01B3) ^ frame.digest()
            // `frame` dies here. Its `deinit` returns the buffer to the pool.
            // There is no `release()` call to forget, and no way to write one
            // twice.
        }

        // Counters are read before draining; the ledger snapshot is taken after,
        // so `stats.isBalanced` reflects a finished run rather than one with the
        // free list still held. `drain()` is idempotent, so the `defer` above
        // remains correct on the throwing path.
        let poolAllocations = pool.allocationCount
        let poolReuses = pool.reuseCount
        let peakFrames = pool.peakLiveCount
        pool.drain()

        let result = BoundaryRunResult(
            shape: .owning,
            stats: ledger.stats,
            poolAllocationCount: poolAllocations,
            poolReuseCount: poolReuses,
            peakLiveFrames: peakFrames,
            combinedDigest: combinedDigest,
            framesProcessed: configuration.frameCount,
            finalGeometry: finalGeometry
        )
        return result
    }

    /// Applies one stage in place, returning the geometry it produced.
    private static func apply(
        _ kind: FeedStageKind,
        to frame: inout FrameStore,
        geometry: FeedGeometry,
        pool: FramePool
    ) throws -> FeedGeometry {

        switch kind {
        case .requantizeUp:
            frame.withMutableInt8 { FeedKernels.requantize($0, numerator: 3, denominator: 2) }
            return geometry

        case .requantizeFine:
            frame.withMutableInt8 { FeedKernels.requantize($0, numerator: 5, denominator: 4) }
            return geometry

        case .zeroCenter:
            let dimension = geometry.dimension
            frame.withMutableInt8 { FeedKernels.zeroCenter($0, dimension: dimension) }
            return geometry

        case .gateWeak:
            frame.withMutableInt8 { FeedKernels.gate($0, belowMagnitude: 4) }
            return geometry

        case .gateResidual:
            frame.withMutableInt8 { FeedKernels.gate($0, belowMagnitude: 2) }
            return geometry

        case .foldPairs:
            let output = try kind.outputGeometry(from: geometry)
            // The size-changing case: a destination is genuinely required. It
            // comes from the same pool, so it is a reuse rather than an
            // allocation on every frame after the first.
            var destination = try pool.acquire()
            try destination.resize(to: output.byteCount)
            let inputTiles = geometry.tileCount
            let dimension = geometry.dimension
            frame.withInt8 { source in
                destination.withMutableInt8 { sink in
                    _ = FeedKernels.foldPairs(
                        source: source,
                        destination: sink,
                        tileCount: inputTiles,
                        dimension: dimension
                    )
                }
            }
            // Moving `destination` into `frame` destroys the old frame, whose
            // `deinit` returns its buffer to the pool. Ping-pong with no
            // bookkeeping and no leak, enforced by noncopyability.
            frame = consume destination
            return output
        }
    }
}
