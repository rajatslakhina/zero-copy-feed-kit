import Foundation

/// A snapshot of everything the ledger has observed.
///
/// All counters saturate rather than overflow, so a pathological run degrades
/// into a pinned `Int.max` instead of trapping.
public struct LedgerStats: Sendable, Equatable {

    /// Number of times a fresh heap buffer was created.
    public var allocationCount: Int = 0

    /// Number of times a heap buffer was destroyed.
    public var deallocationCount: Int = 0

    /// Number of times a buffer was handed out from a free list instead of
    /// being allocated. This is the number the owning boundary is trying to
    /// maximise.
    public var reuseCount: Int = 0

    /// Number of `memcpy`-shaped operations performed *solely* to move bytes
    /// across an API boundary — not counting bytes written as the output of a
    /// transform, which are work rather than overhead.
    public var boundaryCopyCount: Int = 0

    /// Payload bytes requested across all allocations. Excludes allocator and
    /// `Array` headers, which this ledger cannot observe.
    public var bytesAllocated: Int = 0

    /// Payload bytes moved purely to cross a boundary.
    public var bytesCopied: Int = 0

    /// Payload bytes currently held in live buffers.
    public var liveBytes: Int = 0

    /// The high-water mark of ``liveBytes`` over the run.
    public var peakLiveBytes: Int = 0

    public init() {}

    /// True when every allocation has a matching deallocation and no bytes
    /// remain live.
    ///
    /// This is the leak check. It is only meaningful once every frame has gone
    /// out of scope — while a frame is alive it is *expected* to be false, and
    /// ``NegativeControlTests`` asserts exactly that so the check is known to
    /// be sensitive rather than vacuously true.
    public var isBalanced: Bool {
        allocationCount == deallocationCount && liveBytes == 0
    }
}

/// The measuring instrument for the whole package.
///
/// Every claim this library makes about copies and allocations is a claim about
/// numbers that came out of here, which is why the ledger is injected rather
/// than global: a test can hand a fresh ledger to a single pipeline run and read
/// exact counts back, and two pipeline shapes can be measured against the *same*
/// instrument so the comparison is apples to apples.
///
/// Thread safety is provided by an `NSLock` rather than by `Mutex` from the
/// `Synchronization` module. `Mutex` would be the better primitive, but it is
/// gated behind iOS 18 / macOS 15 availability, and the package supports iOS 16.
/// An actor was rejected because the pool's release path runs from
/// `FrameStore.deinit`, which is not an async context and cannot `await`.
public final class AllocationLedger: @unchecked Sendable {

    private let lock = NSLock()
    private var storage = LedgerStats()

    public init() {}

    /// A consistent snapshot of all counters.
    public var stats: LedgerStats {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Records the creation of a heap buffer of `bytes` payload bytes.
    public func recordAllocation(bytes: Int) {
        let clamped = max(0, bytes)
        lock.lock()
        defer { lock.unlock() }
        storage.allocationCount = Saturating.add(storage.allocationCount, 1)
        storage.bytesAllocated = Saturating.add(storage.bytesAllocated, clamped)
        storage.liveBytes = Saturating.add(storage.liveBytes, clamped)
        if storage.liveBytes > storage.peakLiveBytes {
            storage.peakLiveBytes = storage.liveBytes
        }
    }

    /// Records the destruction of a heap buffer of `bytes` payload bytes.
    public func recordDeallocation(bytes: Int) {
        let clamped = max(0, bytes)
        lock.lock()
        defer { lock.unlock() }
        storage.deallocationCount = Saturating.add(storage.deallocationCount, 1)
        storage.liveBytes = max(0, storage.liveBytes - clamped)
    }

    /// Records that a buffer was served from a free list.
    public func recordReuse() {
        lock.lock()
        defer { lock.unlock() }
        storage.reuseCount = Saturating.add(storage.reuseCount, 1)
    }

    /// Records `bytes` moved purely to cross an API boundary.
    public func recordBoundaryCopy(bytes: Int) {
        let clamped = max(0, bytes)
        lock.lock()
        defer { lock.unlock() }
        storage.boundaryCopyCount = Saturating.add(storage.boundaryCopyCount, 1)
        storage.bytesCopied = Saturating.add(storage.bytesCopied, clamped)
    }
}
