import Foundation

/// Every way the feed path can refuse to run.
///
/// There is deliberately no "unknown" case: each error names a specific
/// admission-control decision the caller can act on.
public enum FeedError: Error, Equatable, Sendable, CustomStringConvertible {

    /// The pool already has `limit` frames checked out and was asked for
    /// another one. This is backpressure, not a bug — a feed running ahead of
    /// its consumer hits this instead of growing without bound.
    case poolExhausted(live: Int, limit: Int)

    /// The requested frame geometry is not usable.
    case invalidGeometry(reason: String)

    /// A stage tried to write more bytes than the destination frame can hold.
    case capacityExceeded(needed: Int, capacity: Int)

    public var description: String {
        switch self {
        case let .poolExhausted(live, limit):
            return "Frame pool exhausted: \(live) frames live, limit \(limit)."
        case let .invalidGeometry(reason):
            return "Invalid frame geometry: \(reason)."
        case let .capacityExceeded(needed, capacity):
            return "Stage needed \(needed) bytes, frame capacity is \(capacity)."
        }
    }
}

/// The shape of one feed payload: `tileCount` embedding tiles of `dimension`
/// int8 values each, laid out row-major.
///
/// This models the quantized embedding tiles an on-device inference feed
/// actually moves — a batch of fixed-width vectors, contiguous, one byte per
/// component.
public struct FeedGeometry: Sendable, Equatable {

    public let tileCount: Int
    public let dimension: Int

    /// Total payload bytes. Computed once at init against a validated geometry,
    /// so no multiplication on the hot path can overflow.
    public let byteCount: Int

    /// - Throws: ``FeedError/invalidGeometry(reason:)`` if either dimension is
    ///   below one or the product exceeds ``Saturating/maximumElementCount``.
    public init(tileCount: Int, dimension: Int) throws {
        guard tileCount >= 1 else {
            throw FeedError.invalidGeometry(reason: "tileCount must be at least 1, got \(tileCount)")
        }
        guard dimension >= 1 else {
            throw FeedError.invalidGeometry(reason: "dimension must be at least 1, got \(dimension)")
        }
        let product = Saturating.multiply(tileCount, dimension)
        guard product <= Saturating.maximumElementCount else {
            throw FeedError.invalidGeometry(
                reason: "tileCount * dimension = \(product) exceeds the \(Saturating.maximumElementCount)-byte ceiling"
            )
        }
        self.tileCount = tileCount
        self.dimension = dimension
        self.byteCount = product
    }
}
