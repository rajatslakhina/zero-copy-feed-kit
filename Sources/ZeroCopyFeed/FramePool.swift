import Foundation

/// A fixed-capacity recycler for raw frame buffers.
///
/// Every buffer the pool hands out is the same size (``bufferCapacity``), which
/// is what lets a size-changing stage such as `FoldPairs` write into a pooled
/// destination without a second size class: the buffer is allocated at the
/// maximum the pipeline will ever need, and a frame's *valid* length is carried
/// separately in `FrameStore.count`.
///
/// ## Why a class and not an actor
///
/// The release path runs from `FrameStore.deinit`, which is synchronous and
/// cannot `await`. An actor would force every return-to-pool through a
/// suspension point that a `deinit` is not allowed to have, so the pool is a
/// lock-guarded final class instead. That is a deliberate trade: the pool is a
/// leaf, it holds the lock for a few pointer operations, and it never calls out
/// to user code while holding it.
public final class FramePool: @unchecked Sendable {

    /// Byte capacity of every buffer this pool vends.
    public let bufferCapacity: Int

    /// Maximum number of free buffers kept on the free list. Buffers released
    /// beyond this are genuinely deallocated, which is how a burst does not
    /// permanently inflate the process's footprint.
    public let retentionLimit: Int

    /// Maximum number of frames that may be checked out at once, or `nil` for
    /// no limit. Exceeding it throws ``FeedError/poolExhausted(live:limit:)``.
    public let liveLimit: Int?

    private let ledger: AllocationLedger
    private let lock = NSLock()
    private var freeList: [UnsafeMutableRawPointer] = []
    private var live: Int = 0
    private var peakLive: Int = 0
    private var totalAllocations: Int = 0
    private var totalReuses: Int = 0

    /// - Parameters:
    ///   - bufferCapacity: Byte size of every vended buffer. Clamped to
    ///     `1 ... Saturating.maximumElementCount`.
    ///
    ///     The upper clamp matters and is not decoration: `allocate` aborts the
    ///     process on failure and that abort is not catchable, so a public
    ///     initializer that accepted an arbitrary `Int` would turn a plain
    ///     argument into a crash. `FeedGeometry` enforces the same ceiling, but
    ///     a caller can construct a pool without ever going through it — so the
    ///     bound has to live at the site that actually allocates.
    ///
    ///     Being precise about what this buys: it removes the *unbounded*
    ///     request, not every failure. `acquire()` is still not total — a 256
    ///     MiB allocation under real memory pressure aborts the same way, and
    ///     `allocate` gives no way to find out except by not coming back.
    ///     Making it total would mean `posix_memalign` and a thrown error;
    ///     that is a deliberate non-goal here, and this note exists so the
    ///     clamp is not read as a stronger guarantee than it is.
    ///   - retentionLimit: Free-list size. Clamped to at least zero.
    ///   - liveLimit: Optional checkout ceiling for backpressure.
    ///   - ledger: The instrument that records this pool's allocations.
    public init(
        bufferCapacity: Int,
        retentionLimit: Int = 2,
        liveLimit: Int? = nil,
        ledger: AllocationLedger
    ) {
        self.bufferCapacity = min(max(1, bufferCapacity), Saturating.maximumElementCount)
        self.retentionLimit = max(0, retentionLimit)
        self.liveLimit = liveLimit.map { max(1, $0) }
        self.ledger = ledger
    }

    deinit {
        // The pool owns whatever is left on the free list. Frames still checked
        // out own themselves and will return here — but by then the pool is
        // gone, which is why `FrameStore` holds a strong reference to its pool.
        for pointer in freeList {
            pointer.deallocate()
            ledger.recordDeallocation(bytes: bufferCapacity)
        }
        freeList.removeAll()
    }

    // MARK: - Counters

    /// Buffers this pool has actually allocated. Maintained independently of
    /// the ledger so tests can cross-check one against the other.
    public var allocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalAllocations
    }

    /// Buffers served from the free list.
    public var reuseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalReuses
    }

    /// Frames currently checked out.
    public var liveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return live
    }

    /// High-water mark of ``liveCount``.
    public var peakLiveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakLive
    }

    // MARK: - Checkout

    /// Checks out a zero-length frame backed by a pooled buffer.
    ///
    /// - Throws: ``FeedError/poolExhausted(live:limit:)`` when ``liveLimit`` is
    ///   set and already reached.
    public func acquire() throws -> FrameStore {
        let pointer = try checkOutBuffer()
        return FrameStore(base: pointer, capacity: bufferCapacity, pool: self)
    }

    private func checkOutBuffer() throws -> UnsafeMutableRawPointer {
        lock.lock()
        if let limit = liveLimit, live >= limit {
            let currentLive = live
            lock.unlock()
            throw FeedError.poolExhausted(live: currentLive, limit: limit)
        }
        live += 1
        if live > peakLive { peakLive = live }

        if let recycled = freeList.popLast() {
            totalReuses += 1
            lock.unlock()
            ledger.recordReuse()
            return recycled
        }
        totalAllocations += 1
        lock.unlock()

        // Allocated outside the lock: `allocate` can be slow, and nothing in the
        // pool's invariants depends on it happening atomically with the counter
        // bump — `live` was already incremented, so a concurrent caller sees the
        // correct occupancy.
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferCapacity,
            alignment: FramePool.alignment
        )
        // Raw memory is uninitialised; frames only ever read bytes they have
        // written, but zeroing removes any dependence on that being true.
        //
        // Bound as `Int8`, deliberately: `FrameStore` reaches this memory through
        // `assumingMemoryBound(to: Int8.self)`, which *asserts* the memory is
        // already bound to that type. Initialising it as `UInt8` here and then
        // assuming `Int8` there would be benign on every real target and still
        // formally undefined.
        pointer.initializeMemory(as: Int8.self, repeating: 0, count: bufferCapacity)
        ledger.recordAllocation(bytes: bufferCapacity)
        return pointer
    }

    /// Returns a buffer. Called only from `FrameStore.deinit`.
    internal func release(_ pointer: UnsafeMutableRawPointer) {
        lock.lock()
        live = max(0, live - 1)
        if freeList.count < retentionLimit {
            freeList.append(pointer)
            lock.unlock()
            return
        }
        lock.unlock()
        pointer.deallocate()
        ledger.recordDeallocation(bytes: bufferCapacity)
    }

    /// Deallocates every retained buffer, bringing the ledger back into balance
    /// for a run that is finished.
    ///
    /// Call this only when no frames are checked out; frames still live own
    /// their buffers and will return them afterwards.
    public func drain() {
        lock.lock()
        let retained = freeList
        freeList.removeAll()
        lock.unlock()
        for pointer in retained {
            pointer.deallocate()
            ledger.recordDeallocation(bytes: bufferCapacity)
        }
    }

    /// 64-byte alignment: wide enough for any NEON/AVX vector load a kernel
    /// might use over these tiles, and a multiple of the common cache-line size
    /// so two frames never share a line.
    public static let alignment = 64
}
