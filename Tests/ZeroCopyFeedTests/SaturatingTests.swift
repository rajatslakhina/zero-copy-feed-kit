import XCTest
@testable import ZeroCopyFeed

/// Every case here is an input that makes the *unguarded* operation trap.
/// The tests cannot call the unguarded form — it would abort the process rather
/// than fail an assertion — so each one names the trap it is standing in for.
final class SaturatingTests: XCTestCase {

    // MARK: - add

    func testAddSaturatesInsteadOfOverflowing() {
        // `Int.max + 1` traps.
        XCTAssertEqual(Saturating.add(Int.max, 1), Int.max)
        // `Int.min + (-1)` traps.
        XCTAssertEqual(Saturating.add(Int.min, -1), Int.min)
        XCTAssertEqual(Saturating.add(Int.max, -1), Int.max - 1)
        XCTAssertEqual(Saturating.add(2, 3), 5)
    }

    // MARK: - multiply

    func testMultiplySaturatesWithCorrectSign() {
        // `Int.max * 2` traps.
        XCTAssertEqual(Saturating.multiply(Int.max, 2), Int.max)
        // A negative overflow must pin to `Int.min`, not `Int.max`.
        XCTAssertEqual(Saturating.multiply(Int.max, -2), Int.min)
        XCTAssertEqual(Saturating.multiply(Int.min, 2), Int.min)
        XCTAssertEqual(Saturating.multiply(Int.min, -2), Int.max)
        XCTAssertEqual(Saturating.multiply(-3, -4), 12)
        XCTAssertEqual(Saturating.multiply(0, Int.max), 0)
    }

    // MARK: - divide

    func testDivideHandlesBothTrappingCases() {
        // `x / 0` traps.
        XCTAssertEqual(Saturating.divide(10, by: 0), 0)
        XCTAssertEqual(Saturating.divide(10, by: 0, fallback: -7), -7)
        // `Int.min / -1` traps even though the divisor is non-zero — the true
        // quotient is `Int.max + 1`.
        XCTAssertEqual(Saturating.divide(Int.min, by: -1), Int.max)
        XCTAssertEqual(Saturating.divide(-7, by: 2), -3)  // Swift truncates toward zero
        XCTAssertEqual(Saturating.divide(7, by: 2), 3)
    }

    // MARK: - magnitude

    func testMagnitudeOfInt8MinDoesNotTrap() {
        // `abs(Int8.min)` traps: 128 is not representable in Int8. A quantized
        // feed produces -128 routinely, so this is a live case, not a curiosity.
        XCTAssertEqual(Saturating.magnitude(ofInt8: Int8.min), 128)
        XCTAssertEqual(Saturating.magnitude(ofInt8: Int8.max), 127)
        XCTAssertEqual(Saturating.magnitude(ofInt8: 0), 0)
        XCTAssertEqual(Saturating.magnitude(ofInt8: -5), 5)
    }

    // MARK: - clampToInt8

    func testClampToInt8PinsAtBothEnds() {
        // `Int8(300)` traps.
        XCTAssertEqual(Saturating.clampToInt8(300), Int8.max)
        XCTAssertEqual(Saturating.clampToInt8(-300), Int8.min)
        XCTAssertEqual(Saturating.clampToInt8(127), 127)
        XCTAssertEqual(Saturating.clampToInt8(128), 127)
        XCTAssertEqual(Saturating.clampToInt8(-128), -128)
        XCTAssertEqual(Saturating.clampToInt8(-129), -128)
        XCTAssertEqual(Saturating.clampToInt8(Int.max), Int8.max)
        XCTAssertEqual(Saturating.clampToInt8(Int.min), Int8.min)
    }

    // MARK: - Double conversion

    func testIntFromDoubleCoversEveryTrappingInput() {
        // All four of these trap in `Int(_:)`.
        XCTAssertEqual(Saturating.int(fromDouble: .nan), 0)
        XCTAssertEqual(Saturating.int(fromDouble: .nan, fallback: 42), 42)
        XCTAssertEqual(Saturating.int(fromDouble: .infinity), Int.max)
        XCTAssertEqual(Saturating.int(fromDouble: -.infinity), Int.min)
        XCTAssertEqual(Saturating.int(fromDouble: 1e300), Int.max)
        XCTAssertEqual(Saturating.int(fromDouble: -1e300), Int.min)

        // Ordinary values still convert normally, truncating toward zero.
        XCTAssertEqual(Saturating.int(fromDouble: 3.9), 3)
        XCTAssertEqual(Saturating.int(fromDouble: -3.9), -3)
        XCTAssertEqual(Saturating.int(fromDouble: 0), 0)
    }

    func testIntFromDoubleAtTheIntMaxBoundary() {
        // `Double(Int.max)` rounds *up* to 2^63, which is not representable as
        // an Int — converting it directly traps. The `>=` comparison in the
        // implementation is what makes this case safe, so pin it explicitly.
        XCTAssertEqual(Saturating.int(fromDouble: Double(Int.max)), Int.max)
        XCTAssertEqual(Saturating.int(fromDouble: Double(Int.min)), Int.min)
    }

    // MARK: - Ceiling

    func testMaximumElementCountIsTheSmallerOfTwoBounds() {
        // Two bounds: an overflow bound derived from `Int.max` (so it shrinks
        // where `Int` is 32 bits) and a 256 MiB allocation bound (because
        // `allocate` aborts uncatchably rather than throwing). The smaller wins.
        //
        // Both halves are asserted, not just the answer: a change to either
        // bound turns this red, which a bare `> 0` check would not.
        XCTAssertEqual(Saturating.maximumElementCount, min(Int.max / 4, 256 * 1024 * 1024))
        XCTAssertLessThanOrEqual(Saturating.maximumElementCount, Int.max / 4)
        XCTAssertLessThanOrEqual(Saturating.maximumElementCount, 256 * 1024 * 1024)
    }
}
