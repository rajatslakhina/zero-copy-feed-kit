# ZeroCopyFeed

**Whether your on-device inference feed copies every frame is decided by the shape of a function signature — not by the algorithm inside it.** This package makes that decision measurable: the same quantized embedding tiles, the same kernels, run through two module boundaries, with an allocation ledger counting what each one actually cost.

The result, from the test suite, not from prose:

| 20 frames · 6 stages · 2 KB/frame | Owning boundary | Value boundary |
|---|---:|---:|
| Heap allocations | **2** | **120** |
| Bytes allocated | 4,096 | 184,320 |
| Buffer reuses | 38 | 0 |
| Peak live bytes | 4,096 | 4,096 |
| Boundary copies | 20 (40,960 B) | 0 |
| Output digest | *identical* | *identical* |

Two allocations, not forty, not one hundred and twenty — and **the number does not change when you process 200 frames instead of 20.**

Two things this table is *not* claiming, stated up front rather than in a footnote. It excludes the per-frame synthetic capture buffer, which both paths allocate identically (one `[Int8]` per frame, 20 each here) — symmetric, so it cancels, but it means the absolute totals are ~22 vs ~140 rather than 2 vs 120. And nothing here runs a model: the payload is deterministic SplitMix64 noise and the kernels are integer requantize / mean-removal / gate / fold. This is the *plumbing* an on-device inference feed needs, sized and shaped like the real thing, not an inference engine.

---

## Why this matters

Every discussion of `borrow`, `consuming`, `~Copyable` and spans gets filed under *micro-optimization*, argued about at the level of a single loop, and then dropped because "we should profile first."

That framing is wrong, and it is wrong in a way that costs real money on a real feed path. Consider the two signatures a team actually chooses between when someone writes the tile-processing module:

```swift
// A
func transform(_ input: FrameValue) -> FrameValue

// B
func apply(to frame: inout FrameStore)   // FrameStore is ~Copyable
```

Signature **A** is obliged to allocate. Not "might allocate under some conditions" — *obliged*, structurally, because it returns a value and its input is still alive at the point of mutation, so copy-on-write fires every single time. One allocation per stage per frame. On a six-stage pipeline at 30 fps that is 180 allocations a second whose only purpose is to satisfy the shape of a type signature.

Signature **B** cannot allocate, because it was handed the caller's storage.

Neither of these is a loop-level decision. Both are **module boundary** decisions, made once, in a design review, and then inherited by every call site for the lifetime of the module. By the time anyone opens Instruments, the choice is a hundred files deep. That is why this belongs in an architecture conversation and not a performance one.

And the trade runs in both directions, which is the part usually left out:

> **You can have erased, composable, dependency-injected stages, or you can have zero copies. Choosing one costs you the other.**

`FrameStore` is `~Copyable`, so a protocol requirement taking it cannot be boxed into `[any FeedStage]`. The owning pipeline in this package therefore dispatches over a *closed enum* — no third-party extension point, no injection, no mocking a stage in a test. The value pipeline gets all of that for free and pays 60× the allocations for it. This package prices the trade instead of asserting a winner.

---

## What's in it

| Type | Role |
|---|---|
| `FrameStore` | `~Copyable` frame over pool-owned raw memory. Scoped `withBytes` / `withMutableInt8` borrows; `deinit` returns the buffer. |
| `FramePool` | Fixed-capacity recycler with a free list, a retention limit, an optional live limit for backpressure, and its own counters. |
| `AllocationLedger` | The instrument. Counts allocations, deallocations, reuses, boundary copies, live and peak bytes — all saturating. |
| `FeedKernels` | The arithmetic: integer requantise, per-tile mean removal, magnitude gating, pairwise tile fold. Called identically by both boundaries. |
| `OwningPipeline` | Boundary **B**. `inout FrameStore`, enum-dispatched, ping-pongs through the pool for the size-changing stage. |
| `ValuePipeline` / `ValueFeedStage` | Boundary **A**. `FrameValue -> FrameValue`, `any`-erased, injectable. |
| `TileWalk` | Batched borrowing — the `Iterable`/span idea at tile granularity, pinned against an element-at-a-time reference. |
| `Saturating` | Total arithmetic. Every trapping operation on the feed path routes through here. |
| `BoundaryBenchmark` | Runs both, returns a `BoundaryComparison` with an `outputsMatch` gate. |

### The load-bearing design decisions

**Ownership is enforced by the compiler, not by a code-review rule.** `FrameStore` is noncopyable, so you cannot double-return a buffer (you cannot name the same allocation twice), cannot forget to return one (`deinit` runs at last use), and cannot alias one across a stage boundary. The size-changing stage is written as `frame = consume destination` — moving the new frame in destroys the old one, whose `deinit` hands its buffer back. Ping-pong with no bookkeeping and no possible leak.

**The comparison is gated on output equality.** A path that skips work allocates less for uninteresting reasons. `BoundaryComparison.outputsMatch` compares an FNV-1a/64 digest of every frame's final bytes from both paths; if they diverge, `headline` refuses to print a ratio at all. `NegativeControlTests` runs a value stage with one threshold changed and asserts the check *fails* — a check that only ever passes is decoration.

**FNV-1a, deliberately not `Hasher`.** `Hasher` is seeded per process, so a digest taken from it is not comparable across launches — and a single-process test suite structurally cannot catch that, because both sides of the comparison share the seed. The digests here are constants; the tests hardcode them.

**Two independent counters.** The pool counts allocations because it makes them; the ledger counts them because it was told to. `testPoolCountersAgreeWithTheLedger` asserts they match across every stage count, so the harness cannot quietly report its own assumptions.

### Rejected alternatives

- **An `actor` pool.** Rejected: the release path runs from `FrameStore.deinit`, which is synchronous and cannot `await`. An `NSLock`-guarded final class is the only shape that fits, and it is a leaf that never calls user code while holding the lock.
- **`Mutex` from `Synchronization`.** The better primitive, but gated behind iOS 18 / macOS 15. The package declares `.iOS(.v16)`, so `NSLock` it is.
- **`Foundation.Data` for the value path.** Its allocations happen inside Foundation where the ledger cannot see them. `FrameValue` wraps `[Int8]`, whose copy-on-write behaviour is observable and attributable — and *is* a real allocation, not a rigged number.
- **Floating-point kernels.** Rejected: outputs would then be comparable only "up to a tolerance", and *up to a tolerance* is not a property this package wants to claim. Everything is exact integer arithmetic.
- **Live recompute on slider drag in the demo.** Rejected: a 200-frame run is real work and `onChange` would start one per rendered frame.

---

## Relationship to SE-0507 and `Iterable`

**SE-0507** (`borrow` / `mutate` accessors) is *Implemented (Swift 6.4)*. It expresses "hand out a view of the storage, do not copy it" as a **property** rather than a closure, without the allocation-plus-two-calls overhead of a `_read`/`_modify` coroutine.

**SE-0516** (`Iterable`, which hands a `for` loop a span of elements to borrow in batches) is *Accepted* — not in a shipped release. Worth keeping straight, since attributing an unshipped proposal to 6.4 is exactly the kind of overclaim this section exists to avoid.

This package targets **Swift 6.0**, so the same semantics are spelled with scoped closures (`withBytes`, `withMutableInt8`, `TileWalk.forEachTile`). The borrowing *contract* is identical: the closure sees the storage in place, and the buffer pointer must not escape it.

Stated plainly rather than papered over: **the code here does not use SE-0507's accessors, because the toolchain it is verified against does not have them** — and adopting them later would not be a mechanical rename either. `FrameStore`'s storage is a raw pointer, and SE-0507 lists *borrowing via unsafe pointers* under **future directions**: a `borrow` accessor may only return a stored property, or a computed one that itself has a `borrow` accessor. This type is precisely the case the proposal defers.

What 6.4 changes is ergonomics and call overhead. What it does not change is which boundary shapes preserve zero copies — and that is the entire argument. The allocation table above is a property of the signatures, not of the toolchain.

---

## Not crashing is a feature

A feed path takes user-controlled geometry and quantized data that reaches `Int8.min` routinely. Every trapping operation on that path is routed through `Saturating`:

- `Int(someDouble)` — traps on NaN, ±infinity, and out-of-range. `Saturating.int(fromDouble:)` is total, and its bounds come from `Int.max` / `Int.min` rather than 64-bit literals, so it stays correct where `Int` is 32 bits.
- `x / 0` **and** `Int.min / -1` — both trap. `Saturating.divide` handles both.
- `abs(Int8.min)` — traps, because 128 is not representable in `Int8`. `Saturating.magnitude(ofInt8:)` widens first. A quantized feed hits `-128` constantly; this is not a theoretical case.
- `a * b` overflow, `Int8(300)` — clamped, not trapped.

The kernels take `tileCount` and `dimension` straight from a caller rather than from a validated `FeedGeometry`, so they treat both as hostile: index math goes through `Saturating` (`tileCount + 1` overflows at `Int.max`; `tile * dimension` overflows well before that), and the loops are bounded by the *destination's* real length rather than by the claimed geometry, so an absurd `dimension` truncates instead of spinning. Every collection access is bounds-checked against the real buffer length; a tile the geometry promises but the source does not contain is zeroed rather than left holding a recycled buffer's previous frame. Zero-length frames, `dimension = 0`, negative counts, ragged final tiles and `Int.max` geometries are all covered by tests.

Two ceilings rather than one: `Saturating.maximumElementCount` is the *smaller* of an overflow bound (`Int.max / 4`, derived so it shrinks on 32-bit) and a 256 MiB allocation bound — because `UnsafeMutableRawPointer.allocate` aborts uncatchably on failure, so validating only for overflow would turn a throwable error into a crash. And the pool's live limit turns "the feed ran ahead of the consumer" into a thrown `FeedError.poolExhausted` rather than unbounded growth.

There are exactly three force-unwrap-shaped constructs in the package — `FrameStore.write`, `TileWalk.forEachTile` and `TileWalk.forEachMutableTile` — all `if let` guards on `baseAddress` after a `count > 0` check, all three commented with why they are provably safe.

---

## Installation

```swift
// Package.swift
.package(url: "https://github.com/rajatslakhina/zero-copy-feed-kit.git", from: "1.0.0")
```

```swift
.target(name: "YourFeature", dependencies: [
    .product(name: "ZeroCopyFeed", package: "zero-copy-feed-kit"),
    .product(name: "ZeroCopyFeedUI", package: "zero-copy-feed-kit"),  // SwiftUI explorer, optional
])
```

In Xcode: **File → Add Package Dependencies…**, paste the URL, choose *Up to Next Major Version* from `1.0.0`.

## Running it yourself

```bash
git clone https://github.com/rajatslakhina/zero-copy-feed-kit.git
cd zero-copy-feed-kit
swift build -Xswiftc -warnings-as-errors
swift test
```

Reproducing the table at the top:

```swift
import ZeroCopyFeed

let comparison = try BoundaryBenchmark.compare(
    tileCount: 32, dimension: 64, frameCount: 20, stageCount: 6
)
print(comparison.outputsMatch)                      // true
print(comparison.owning.stats.allocationCount)      // 2
print(comparison.value.stats.allocationCount)       // 120
print(comparison.headline)
// 20 frames · 6 stages · 2 vs 120 allocations (60.0×)
```

`ZeroCopyFeedUI` compiles to nothing where SwiftUI is unavailable, so the package builds and tests cleanly on Linux.

---

## Verification

- **72 tests, 0 failures** on Swift 6.0.3 (Linux, aarch64), from a clean `rm -rf .build` followed by `swift build -Xswiftc -warnings-as-errors` and `swift test`.
- CI runs two jobs on every push — a Linux job that repeats that clean warnings-as-errors build and the full test run, and a `macos-15` job that compiles the package for `generic/platform=iOS Simulator`. Status is on the [Actions tab](../../actions).
- Scope of the warnings claim, precisely: `-warnings-as-errors` is applied by the Linux job, which compiles the core module. `ZeroCopyFeedUI` is entirely inside `#if canImport(SwiftUI)` and so is only *compiled* by the macOS job, which does not pass the flag — deliberately, because supporting iOS 16 means using APIs (`foregroundColor`) that are soft-deprecated on the iOS 17+ SDK. So "zero warnings, machine-enforced" is true of the core module and is not claimed of the SwiftUI layer.
- **A Simulator run was attempted and could not be performed** — see the demo repo's README for the verbatim refusal and what was verified instead. "It compiles for a Simulator" and "it ran on a Simulator" are different claims and are reported separately.

## Demo app

**[zero-copy-feed-kit-demo-app](https://github.com/rajatslakhina/zero-copy-feed-kit-demo-app)** — an iOS app that consumes this package as a remote, version-pinned dependency and puts the comparison on screen with live sliders.

## Requirements

Swift 6.0+ · iOS 16+ / macOS 13+ · no third-party dependencies.

## License

MIT — see [LICENSE](LICENSE).
