import Foundation

/// A noncopyable, pool-backed frame of quantized feed bytes.
///
/// ## The point of the type
///
/// `FrameStore` is `~Copyable`, and that single annotation is what turns pool
/// discipline from a code-review rule into a compiler-enforced one:
///
/// - You cannot double-return a buffer, because you cannot make a second
///   `FrameStore` that names the same allocation.
/// - You cannot forget to return one, because `deinit` runs at the last use and
///   hands the buffer back to the pool.
/// - You cannot alias one across a stage boundary, because passing it by
///   `consuming` moves it and passing it by `inout` takes exclusive access.
///
/// A copyable wrapper around the same pointer gives you none of that. The
/// ownership annotation *is* the design.
///
/// ## Relationship to SE-0507
///
/// Swift 6.4 implements `borrow` and `mutate` accessors, which express "hand out
/// a view of the storage, do not copy it" as a property rather than as a
/// closure, and without the allocation-plus-two-calls overhead of a
/// `_read`/`_modify` coroutine. This package targets Swift 6.0, so the same
/// semantics are spelled with scoped closures — ``withBytes(_:)`` and
/// ``withMutableInt8(_:)``. The borrowing *contract* is identical: the closure
/// sees the storage in place and the buffer pointer must not escape it.
///
/// One caveat worth stating rather than glossing: `FrameStore`'s storage is a
/// raw pointer, and SE-0507 lists *borrowing via unsafe pointers* under future
/// directions — a `borrow` accessor may only return a stored property, or a
/// computed one that itself has a `borrow` accessor. So this type is precisely
/// the case the proposal defers, and adopting 6.4 here is not a mechanical
/// find-and-replace. What 6.4 changes is ergonomics and call overhead; what it
/// does not change is which boundary shapes preserve zero copies — which is why
/// this library's argument survives the version gap regardless.
public struct FrameStore: ~Copyable {

    @usableFromInline internal let base: UnsafeMutableRawPointer

    /// Bytes the backing buffer can hold. Fixed by the pool.
    public let capacity: Int

    /// Bytes currently valid. Always in `0...capacity`.
    public private(set) var count: Int

    /// Strong reference: a frame outliving its pool must still have somewhere
    /// to return the buffer to.
    private let pool: FramePool

    internal init(base: UnsafeMutableRawPointer, capacity: Int, pool: FramePool) {
        self.base = base
        self.capacity = capacity
        self.count = 0
        self.pool = pool
    }

    deinit {
        pool.release(base)
    }

    // MARK: - Length

    /// Sets the number of valid bytes.
    ///
    /// - Throws: ``FeedError/capacityExceeded(needed:capacity:)`` when `newCount`
    ///   exceeds ``capacity``. Negative values are treated as zero.
    public mutating func resize(to newCount: Int) throws {
        let requested = max(0, newCount)
        guard requested <= capacity else {
            throw FeedError.capacityExceeded(needed: requested, capacity: capacity)
        }
        count = requested
    }

    // MARK: - Borrowing access

    /// Borrows the valid bytes for the duration of `body`.
    ///
    /// The buffer pointer must not escape the closure — it names pool-owned
    /// memory that is valid only while this frame is alive.
    @inlinable
    public borrowing func withBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: base, count: count))
    }

    /// Borrows the valid bytes as `Int8` tiles.
    @inlinable
    public borrowing func withInt8<R>(_ body: (UnsafeBufferPointer<Int8>) throws -> R) rethrows -> R {
        let typed = base.assumingMemoryBound(to: Int8.self)
        return try body(UnsafeBufferPointer(start: typed, count: count))
    }

    /// Mutates the valid bytes in place for the duration of `body`.
    @inlinable
    public mutating func withMutableInt8<R>(
        _ body: (UnsafeMutableBufferPointer<Int8>) throws -> R
    ) rethrows -> R {
        let typed = base.assumingMemoryBound(to: Int8.self)
        return try body(UnsafeMutableBufferPointer(start: typed, count: count))
    }

    /// Writes `bytes` into the frame, replacing its contents.
    ///
    /// This is the one place the package performs a boundary copy on the owning
    /// path — it is how bytes *enter* the zero-copy world from an ordinary
    /// Swift value — and it charges the ledger for it, so the owning path is
    /// never credited with a copy it actually performed.
    ///
    /// - Throws: ``FeedError/capacityExceeded(needed:capacity:)``.
    public mutating func write(_ bytes: [Int8], ledger: AllocationLedger?) throws {
        guard bytes.count <= capacity else {
            throw FeedError.capacityExceeded(needed: bytes.count, capacity: capacity)
        }
        count = bytes.count
        guard count > 0 else { return }
        let typed = base.assumingMemoryBound(to: Int8.self)
        bytes.withUnsafeBufferPointer { source in
            // Safe force-free: `source.baseAddress` is non-nil whenever
            // `count > 0`, which the guard above established.
            if let address = source.baseAddress {
                typed.update(from: address, count: count)
            }
        }
        ledger?.recordBoundaryCopy(bytes: count)
    }

    /// Copies the valid bytes out into an ordinary array.
    ///
    /// Also a boundary copy, and also charged. Used by tests and by the
    /// equality check; never called inside a measured pipeline body.
    public borrowing func snapshot(ledger: AllocationLedger? = nil) -> [Int8] {
        guard count > 0 else { return [] }
        let typed = base.assumingMemoryBound(to: Int8.self)
        let result = Array(UnsafeBufferPointer(start: typed, count: count))
        ledger?.recordBoundaryCopy(bytes: count)
        return result
    }

    // MARK: - Checksums

    /// An FNV-1a/64 digest of the valid bytes, computed in place.
    ///
    /// Deliberately *not* `Hasher`. `Hasher` is seeded per process, so a digest
    /// taken from it is not comparable across launches — and a single-process
    /// test suite structurally cannot catch that, because both sides of the
    /// comparison share the seed. FNV-1a is fixed, so the value in this file's
    /// tests is the value on any machine, and the two pipeline shapes can be
    /// compared by digest without either of them materialising an array.
    public borrowing func digest() -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01B3
        let buffer = UnsafeRawBufferPointer(start: base, count: count)
        for byte in buffer {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }
}

/// FNV-1a/64 over an ordinary byte sequence, so the value path can produce a
/// digest comparable with ``FrameStore/digest()``.
@inlinable
public func fnv1a64(_ bytes: [Int8]) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    let prime: UInt64 = 0x0000_0100_0000_01B3
    for signed in bytes {
        hash ^= UInt64(UInt8(bitPattern: signed))
        hash = hash &* prime
    }
    return hash
}
