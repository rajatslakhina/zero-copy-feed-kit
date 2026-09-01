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

Swift 6.4 adds `borrow` and `mutate` accessors, which express "hand out a view of the storage, do not copy it" as a *property* rather than as a closure, without the allocation-plus-two-calls overhead of a `_read`/`_modify` coroutine — and `Iterable` hands a `for` loop a span of elements to borrow in batches.

This package targets **Swift 6.0**, so the same semantics are spelled with scoped closures (`withBytes`, `withMutableInt8`, `TileWalk.forEachTile`). The borrowing *contract* is identical: the closure sees the storage in place, and the buffer pointer must not escape it.

This is stated plainly rather than papered over: **the code here does not use SE-0507's accessors, because the toolchain it is verified against does not have them.** What 6.4 changes is ergonomics and call overhead. What it does not change is which boundary shapes preserve zero copies — and that is the entire argument. When the accessors land, `withMutableInt8 { }` becomes a `mutate` property and `TileWalk.forEachTile` becomes a `for` loop; the allocation table above stays exactly the same.

---

## Not crashing is a feature

A feed path takes user-controlled geometry and quantized data that reaches `Int8.min` routinely. Every trapping operation on that path is routed through `Saturating`:

- `Int(someDouble)` — traps on NaN, ±infinity, and out-of-range. `Saturating.int(fromDouble:)` is total, and its bounds come from `Int.max` / `Int.min` rather than 64-bit literals, so it stays correct where `Int` is 32 bits.
- `x / 0` **and** `Int.min / -1` — both trap. `Saturating.divide` handles both.
- `abs(Int8.min)` — traps, because 128 is not representable in `Int8`. `Saturating.magnitude(ofInt8:)` widens first. A quantized feed hits `-128` constantly; this is not a theoretical case.
- `a * b` overflow, `Int8(300)` — clamped, not trapped.

Beyond arithmetic: every collection access is bounds-checked against the *real* buffer length rather than trusted from the geometry, so a mismatched geometry truncates instead of reading out of bounds; zero-length frames, `dimension = 0`, negative counts, and ragged final tiles are all covered by tests; and the pool's live limit turns "the feed ran ahead of the consumer" into a thrown `FeedError.poolExhausted` rather than unbounded growth.

There are exactly two force-unwrap-shaped constructs in the package, both `if let` guards on `baseAddress` after a `count > 0` check, both commented with why they are provably safe.

---

## Verification

- **68 tests, 0 failures** on Swift 6.0.3 (Linux, aarch64), from a clean `rm -rf .build` followed by `swift build -Xswiftc -warnings-as-errors` and `swift test`.
- The `-warnings-as-errors` flag lives in the CI job, not in this README, so "zero warnings" is machine-enforced rather than asserted.
- CI runs two jobs on every push — a Linux job that does the clean warnings-as-errors build and the full test run, and a `macos-15` job that compiles the package for `generic/platform=iOS Simulator`. Current status is on the [Actions tab](../../actions).
- **A Simulator run was attempted and could not be performed** — see the demo repo's README for exactly what happened and what was verified instead. "It compiles for a Simulator" and "it ran on a Simulator" are different claims and are reported separately.

## Demo app

Demo app: **(added after the companion repo is pushed — see below)**

## Requirements

Swift 6.0+ · iOS 16+ / macOS 13+ · no third-party dependencies.

## License

MIT — see [LICENSE](LICENSE).
