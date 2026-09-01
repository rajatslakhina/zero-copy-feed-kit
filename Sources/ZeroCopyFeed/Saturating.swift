import Foundation

/// Arithmetic helpers that make every trapping operation on the feed path
/// unreachable.
///
/// The feed path multiplies user-supplied geometry (`tileCount * dimension`),
/// divides by a user-supplied denominator, and negates quantized values. All
/// three of those trap in Swift on the wrong input:
///
/// - `a * b` traps on overflow.
/// - `a / 0` traps, and `Int.min / -1` traps even though the divisor is not zero.
/// - `abs(Int8.min)` traps, because `128` is not representable in `Int8`.
/// - `Int(someDouble)` traps on NaN, on ±infinity, and on any value outside
///   `Int`'s range — the single most common trap in "just convert the slider
///   value" code.
///
/// Rather than scattering `guard`s at every call site, the feed path routes all
/// of these through this enum. Every function here is total: it is defined for
/// every input of its argument type and never traps.
public enum Saturating {

    // MARK: - Integer arithmetic

    /// `a + b`, clamped to `Int.min ... Int.max` instead of trapping.
    @inlinable
    public static func add(_ a: Int, _ b: Int) -> Int {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return value }
        return b > 0 ? Int.max : Int.min
    }

    /// `a * b`, clamped to `Int.min ... Int.max` instead of trapping.
    @inlinable
    public static func multiply(_ a: Int, _ b: Int) -> Int {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        guard overflow else { return value }
        // Sign of the true product decides which end we saturate to.
        let negative = (a < 0) != (b < 0)
        return negative ? Int.min : Int.max
    }

    /// `a / b`, defined for every input.
    ///
    /// Returns `fallback` when `b == 0`, and `Int.max` for the one other
    /// trapping case in Swift integer division, `Int.min / -1`.
    @inlinable
    public static func divide(_ a: Int, by b: Int, fallback: Int = 0) -> Int {
        guard b != 0 else { return fallback }
        guard !(a == Int.min && b == -1) else { return Int.max }
        return a / b
    }

    /// `|a|` computed in `Int`, defined for every `Int8` including `Int8.min`.
    ///
    /// `abs(Int8.min)` traps; widening first makes the operation total.
    @inlinable
    public static func magnitude(ofInt8 a: Int8) -> Int {
        let widened = Int(a)
        return widened < 0 ? -widened : widened
    }

    // MARK: - Narrowing

    /// Clamps an `Int` into `Int8`'s range rather than trapping on the
    /// out-of-range initializer.
    @inlinable
    public static func clampToInt8(_ value: Int) -> Int8 {
        if value > Int(Int8.max) { return Int8.max }
        if value < Int(Int8.min) { return Int8.min }
        return Int8(truncatingIfNeeded: value)
    }

    /// Converts a `Double` to `Int` without trapping.
    ///
    /// - NaN maps to `fallback`.
    /// - `+infinity` and anything at or above `Int.max` maps to `Int.max`.
    /// - `-infinity` and anything at or below `Int.min` maps to `Int.min`.
    ///
    /// The bounds are derived from `Int.max` / `Int.min` rather than hardcoded
    /// 64-bit literals, so this stays correct where `Int` is 32 bits (watchOS).
    @inlinable
    public static func int(fromDouble value: Double, fallback: Int = 0) -> Int {
        guard !value.isNaN else { return fallback }
        // `Double(Int.max)` rounds *up* to 2^63 on 64-bit, so `>=` is the correct
        // comparison here: a Double equal to that rounded value is not
        // representable as an Int.
        if value >= Double(Int.max) { return Int.max }
        if value <= Double(Int.min) { return Int.min }
        return Int(value)
    }

    // MARK: - Geometry

    /// The largest element count the feed path will accept.
    ///
    /// Two bounds, and the smaller wins:
    ///
    /// - `Int.max / 4` is the *overflow* bound. Deriving it from `Int.max`
    ///   rather than writing a 64-bit literal is what keeps it correct where
    ///   `Int` is 32 bits (watchOS).
    /// - 256 MiB is the *allocation* bound. `UnsafeMutableRawPointer.allocate`
    ///   aborts the process on failure and that abort is not catchable, so a
    ///   geometry validator that only checked for overflow would happily accept
    ///   a frame no device can allocate and turn a throwable error into a crash.
    ///   A single on-device feed frame is kilobytes; 256 MiB is already absurd.
    public static let maximumElementCount: Int = min(Int.max / 4, 256 * 1024 * 1024)
}
