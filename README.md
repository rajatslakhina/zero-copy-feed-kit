# ZeroCopyFeed

**Whether your on-device inference feed copies every frame is decided by one keyword in a function signature.** Not by the algorithm inside it, and — this is the part that surprised me — not by whether the signature is erasable either.

This package makes that decision measurable: the same quantized embedding tiles, the same kernels, run through **three** module boundaries, with an allocation ledger counting what each one cost.

| 20 frames · 6 stages · 2 KB/frame | `inout FrameStore` | `consuming FrameValue` | `borrowing FrameValue` |
|---|---:|---:|---:|
| Heap allocations | **2** | **20** | **120** |
| Bytes allocated | 4,096 | 20,480 | 184,320 |
| Peak live bytes | 4,096 | 1,024 | 4,096 |
| Output digest | *identical* | *identical* | *identical* |

Two allocations, not twenty, not one hundred and twenty — and **only the first column stays at 2 when you process 200 frames instead of 20.**

### The build mode this is true in

**The middle column is a release-mode result, and that qualifier is load-bearing.** `consuming` is a guarantee about *ownership*, not an instruction to the code generator: it makes the array provably uniquely referenced at the mutation, and the ARC optimiser is what then deletes the retain that would otherwise make copy-on-write fire. At `-Onone` that optimiser does not run.

Counting every real `malloc` with an `LD_PRELOAD` interposer, on this exact configuration:

| | owning | consuming | borrowing |
|---|---:|---:|---:|
| `-O` | 27 | **45** | 145 |
| `-Onone` | 171 | **20,783** | 20,765 |

In a debug build the consuming and borrowing paths are, to within the interposer's own noise, **the same program**. The ledger still reports 2 / 20 / 120 in both, and it is not lying: it counts the allocations the *library* asks for, and a copy-on-write copy is one the runtime makes on the library's behalf. So the saving is real, and it is real at `-O`.

Rather than leave that as a footnote, `swift test -c release` is part of CI and `testConsumingStagesMutateTheirInputBufferInPlace` asserts buffer identity there — it skips itself in a debug build with that reason, instead of asserting something false. Gut all three in-place stages into deep copies and that test goes red; that is how I know it is worth having.

(Raw `malloc` totals include Swift runtime and test-harness overhead and will not reproduce to the digit on a different machine. The ledger numbers — 2 / 20 / 120 — are exact, deterministic, and asserted by the suite.)

Two more things this table is *not* claiming. It excludes the per-frame synthetic capture buffer, which every path allocates identically (one `[Int8]` per frame) — symmetric, so it cancels, and it is most of the gap between the ledger's 2 / 20 / 120 and the `-O` row above. And nothing here runs a model: the payload is deterministic SplitMix64 noise and the kernels are integer requantize / mean-removal / gate / fold. This is the *plumbing* an on-device inference feed needs, sized and shaped like the real thing, not an inference engine.

---

## Why this matters

Every discussion of `borrow`, `consuming`, `~Copyable` and spans gets filed under *micro-optimization*, argued about at the level of a single loop, and then dropped because "we should profile first."

That framing is wrong, and it is wrong in a way that costs real money on a real feed path. Consider the signatures a team actually chooses between when someone writes the tile-processing module:

```swift
// A — the one you get if you don't think about ownership
func transform(_ input: FrameValue) -> FrameValue

// B — one keyword different
func transform(_ input: consuming FrameValue) -> FrameValue

// C — noncopyable, pool-backed
func apply(to frame: inout FrameStore)
```

**A** is structurally obliged to allocate — not "might allocate under some conditions", *obliged*, because the caller still owns `input` at the point of mutation, so copy-on-write fires every single time. One allocation per stage per frame. On a six-stage pipeline at 30 fps that is 180 allocations a second whose only purpose is to satisfy an ownership rule nobody thought about.

**B** is the same signature — still value-in/value-out, still `Sendable`, still erases into `[any ConsumingValueFeedStage]`, still injectable and mockable — and it allocates **nothing at all** for an in-place stage, because `consuming` ends the caller's ownership at the call and the storage is uniquely referenced.

**C** cannot allocate, because it was handed the caller's storage.

### The claim I had to retract

An earlier version of this README compared only **A** against **C** and concluded:

> ~~You can have erased, composable, dependency-injected stages, or you can have zero copies. Choosing one costs you the other.~~

That is false, and `ConsumingValueBoundary.swift` is the counter-example, shipped in the package so the mistake cannot come back. Erasure is not what costs you the copies. The *ownership annotation on the parameter* is. Measured, with no size-changing stage in the pipeline, the erased consuming boundary allocates **zero** times.

### What survives

The durable claim is about **shape**, not magnitude:

> **Only the owning boundary's allocation count is constant in frame count. Every value boundary is linear in it** — because a size-changing stage must produce new storage, and a value type has nowhere to recycle it to.

1 / 20 / 200 frames give the owning path 2 allocations every time. They give the consuming path 1 / 20 / 200, and the borrowing path 6 / 120 / 1200. That is the difference a pool buys, and it is the only difference a pool buys.

So the honest ratio depends entirely on what you are comparing against: **60×** against the signature most people write by accident, **10×** against the best one a careful engineer would write. Both are in the table. Leading with only the first would be an advertisement.

---

## What's in it

| Type | Role |
|---|---|
| `FrameStore` | `~Copyable` frame over pool-owned raw memory. Scoped `withBytes` / `withMutableInt8` borrows; `deinit` returns the buffer. |
| `FramePool` | Fixed-capacity recycler with a free list, a retention limit, an optional live limit for backpressure, and its own counters. |
| `AllocationLedger` | The instrument. Counts allocations, deallocations, reuses, boundary copies, live and peak bytes — all saturating. |
| `FeedKernels` | The arithmetic: integer requantise, per-tile mean removal, magnitude gating, pairwise tile fold. Called identically by all three boundaries. |
| `OwningPipeline` | Boundary **C**. `inout FrameStore`, enum-dispatched, ping-pongs through the pool for the size-changing stage. |
| `ConsumingValuePipeline` / `ConsumingValueFeedStage` | Boundary **B**. `consuming FrameValue -> FrameValue`, `any`-erased, injectable, and allocation-free for in-place stages. |
| `ValuePipeline` / `ValueFeedStage` | Boundary **A**. `borrowing FrameValue -> FrameValue`, `any`-erased, injectable, copy-on-write at every stage. |
| `TileWalk` | Batched borrowing — the `Iterable`/span idea at tile granularity, pinned against an element-at-a-time reference. |
| `Saturating` | Total arithmetic. Every trapping operation on the feed path routes through here. |
| `BoundaryBenchmark` | Runs all three, returns a `BoundaryComparison` with an `outputsMatch` gate. |

### The load-bearing design decisions

**Ownership is enforced by the compiler, not by a code-review rule.** `FrameStore` is noncopyable, so you cannot double-return a buffer (you cannot name the same allocation twice), cannot forget to return one (`deinit` runs at last use), and cannot alias one across a stage boundary. The size-changing stage is written as `frame = consume destination` — moving the new frame in destroys the old one, whose `deinit` hands its buffer back. Ping-pong with no bookkeeping and no possible leak.

**The comparison is gated on output equality.** A path that skips work allocates less for uninteresting reasons. `BoundaryComparison.outputsMatch` compares an FNV-1a/64 digest of every frame's final bytes across all three paths; if any diverges, `headline` refuses to print a ratio at all. `ConsumingValueBoundaryTests` also asserts the stronger property — the three paths agree **byte for byte** — outside the measured region, so "identical output" does not rest on a hash alone. `NegativeControlTests` runs a value stage with one threshold changed and asserts the check *fails* — a check that only ever passes is decoration.

**FNV-1a, deliberately not `Hasher`.** `Hasher` is seeded per process, so a digest taken from it is not comparable across launches — and a single-process test suite structurally cannot catch that, because both sides of the comparison share the seed. The digests here are constants; the tests hardcode them.

**Two independent counters.** The pool counts allocations because it makes them; the ledger counts them because it was told to. `testPoolCountersAgreeWithTheLedger` asserts they match across every stage count, so the harness cannot quietly report its own assumptions.

### Considered and shipped instead of rejected

- **`consuming FrameValue` for the value boundary.** This was the missing alternative, and leaving it out was the single biggest flaw in the first version of this package. It is not rejected — it is shipped as a first-class third pipeline, because it is what a careful engineer writes and it is what the argument has to beat. Measured: 20 allocations at the headline configuration versus 120 for the borrowing form, and **0** when no stage changes size.

### Rejected alternatives

- **An `actor` pool.** Rejected: the release path runs from `FrameStore.deinit`, which is synchronous and cannot `await`. An `NSLock`-guarded final class is the only shape that fits, and it is a leaf that never calls user code while holding the lock.
- **`Mutex` from `Synchronization`.** The better primitive, but gated behind iOS 18 / macOS 15. The package declares `.iOS(.v16)`, so `NSLock` it is.
- **`Foundation.Data` for the value path.** Its allocations happen inside Foundation where the ledger cannot see them. `FrameValue` wraps `[Int8]`, whose copy-on-write behaviour is observable and attributable — and *is* a real allocation, not a rigged number.
- **Floating-point kernels.** Rejected: outputs would then be comparable only "up to a tolerance", and *up to a tolerance* is not a property this package wants to claim. Everything is exact integer arithmetic.
- **Live recompute on slider drag in the demo.** Rejected: a 200-frame run is real work and `onChange` would start one per rendered frame. The run is also moved off the main actor with cancellation, so dragging a slider cannot freeze the UI — a screen arguing about the cost of avoidable work should not be doing avoidable work on the main thread.

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
.package(url: "https://github.com/rajatslakhina/zero-copy-feed-kit.git", from: "1.1.1")
```

```swift
.target(name: "YourFeature", dependencies: [
    .product(name: "ZeroCopyFeed", package: "zero-copy-feed-kit"),
    .product(name: "ZeroCopyFeedUI", package: "zero-copy-feed-kit"),  // SwiftUI explorer, optional
])
```

In Xcode: **File → Add Package Dependencies…**, paste the URL, choose *Up to Next Major Version* from `1.1.1`.

## Running it yourself

```bash
git clone https://github.com/rajatslakhina/zero-copy-feed-kit.git
cd zero-copy-feed-kit
swift build -Xswiftc -warnings-as-errors
swift test
swift test -c release   # reaches the copy-elision assertion, which debug skips
```

The release run is not optional decoration. `testConsumingStagesMutateTheirInputBufferInPlace` asserts that a consuming stage hands back the *same* buffer it was given, which is only true once the ARC optimiser has run; in a debug build it skips itself with that reason rather than asserting something false.

Reproducing the table at the top:

```swift
import ZeroCopyFeed

let comparison = try BoundaryBenchmark.compare(
    tileCount: 32, dimension: 64, frameCount: 20, stageCount: 6
)
print(comparison.outputsMatch)                              // true
print(comparison.owning.stats.allocationCount)              // 2
print(comparison.consumingValue.stats.allocationCount)      // 20
print(comparison.value.stats.allocationCount)               // 120
print(comparison.headline)
// 20 frames · 6 stages · 2 / 20 / 120 allocations (owning / consuming / borrowing)
```

`ZeroCopyFeedUI` compiles to nothing where SwiftUI is unavailable, so the package builds and tests cleanly on Linux.

---

## Verification

- **82 tests, 0 failures** on Swift 6.0.3 (Linux, aarch64), from a clean `rm -rf .build` followed by `swift build -Xswiftc -warnings-as-errors` and `swift test`. One of them skips in a debug build, on purpose, and asserts under `swift test -c release`; the exact counts are in the CI log rather than restated here, because a hand-copied number goes stale the next time someone adds a test.
- CI runs two jobs on every push to `main` (and on pull requests into it) — a Linux job that repeats that clean warnings-as-errors build and runs the suite in **both** debug and release, and a `macos-15` job that compiles the package for `generic/platform=iOS Simulator`. Status is on the [Actions tab](../../actions).
- Scope of the warnings claim, precisely: `-warnings-as-errors` is applied by the Linux job, which compiles the core module. `ZeroCopyFeedUI` is entirely inside `#if canImport(SwiftUI)` and so is only *compiled* by the macOS job, which does not pass the flag — deliberately, because supporting iOS 16 means using APIs (`foregroundColor`) that are soft-deprecated on the iOS 17+ SDK. So "zero warnings, machine-enforced" is true of the core module and is not claimed of the SwiftUI layer.
- **A Simulator run was attempted and could not be performed** — see the demo repo's README for the verbatim refusal and what was verified instead. "It compiles for a Simulator" and "it ran on a Simulator" are different claims and are reported separately.

## Demo app

**[zero-copy-feed-kit-demo-app](https://github.com/rajatslakhina/zero-copy-feed-kit-demo-app)** — an iOS app that consumes this package as a remote, version-pinned dependency and puts the comparison on screen with live sliders.

## Requirements

Swift 6.0+ · iOS 16+ / macOS 13+ · no third-party dependencies.

## License

MIT — see [LICENSE](LICENSE).
