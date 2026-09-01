#if canImport(SwiftUI)
import Foundation
import SwiftUI
import ZeroCopyFeed

/// The knobs the explorer exposes.
///
/// The host app owns the defaults and passes them in, so "what does this screen
/// show when you launch it" is an app-level decision rather than something
/// buried in a library view's initializer.
///
/// Every field is clamped to the slider's own range at construction. That is not
/// belt-and-braces: this initializer is `public`, its values are converted back
/// to `Int` inside the view, and an unclamped `Int.max` or a negative would trap
/// on `Int(someDouble)`, on `tileCount * dimension`, or on
/// `Array.prefix(negative)`. Validating once, here, is what keeps those three
/// call sites total.
public struct ExplorerDefaults: Sendable, Equatable {

    /// Slider bounds, and therefore the clamp bounds — one source of truth.
    public static let tileCountRange = 1...128
    public static let dimensionRange = 1...128
    public static let frameCountRange = 1...200
    public static var stageCountRange: ClosedRange<Int> { 0...FeedStageKind.ladder.count }

    public let tileCount: Int
    public let dimension: Int
    public let frameCount: Int
    public let stageCount: Int

    public init(tileCount: Int = 32, dimension: Int = 64, frameCount: Int = 20, stageCount: Int = 6) {
        func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
            min(max(value, range.lowerBound), range.upperBound)
        }
        self.tileCount = clamp(tileCount, Self.tileCountRange)
        self.dimension = clamp(dimension, Self.dimensionRange)
        self.frameCount = clamp(frameCount, Self.frameCountRange)
        self.stageCount = clamp(stageCount, Self.stageCountRange)
    }
}

/// Runs the same feed through both boundary shapes and shows what each one cost.
///
/// The screen recomputes on appear and when a slider drag *ends*, so the default
/// state already shows a real result rather than an empty placeholder waiting
/// for a button press — without starting a 200-frame run on every rendered
/// frame of a drag.
public struct FeedBoundaryExplorerView: View {

    @State private var tileCount: Double
    @State private var dimension: Double
    @State private var frameCount: Double
    @State private var stageCount: Double
    @State private var comparison: BoundaryComparison?
    @State private var failureMessage: String?
    @State private var isRunning = false
    @State private var work: Task<Void, Never>?

    public init(defaults: ExplorerDefaults = ExplorerDefaults()) {
        _tileCount = State(initialValue: Double(defaults.tileCount))
        _dimension = State(initialValue: Double(defaults.dimension))
        _frameCount = State(initialValue: Double(defaults.frameCount))
        _stageCount = State(initialValue: Double(defaults.stageCount))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                controls
                if let failureMessage {
                    banner(failureMessage, tint: .orange)
                } else if let comparison {
                    matchBadge(comparison)
                    resultGrid(comparison)
                    allocationBars(comparison)
                    stageList
                    footnote
                }
                if isRunning {
                    banner("Running…", tint: .secondary)
                }
            }
            .padding(20)
        }
        .onAppear(perform: recompute)
        .onDisappear { work?.cancel() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Zero-Copy Feed Boundary")
                .font(.title2.bold())
            Text("The same quantized embedding tiles, the same kernels, three module boundaries.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            slider("Tiles per frame", value: $tileCount, range: 1...128, format: "%.0f")
            slider("Tile dimension", value: $dimension, range: 1...128, format: "%.0f")
            slider("Frames", value: $frameCount, range: 1...200, format: "%.0f")
            slider("Stages", value: $stageCount, range: 0...Double(FeedStageKind.ladder.count), format: "%.0f")
            // Same reasoning as the pipeline list: `Int(Double)` and `a * b`
            // both trap, and neither is guaranteed safe by the slider alone.
            Text("\(currentTiles) × \(currentDimension) = "
                 + "\(Saturating.multiply(currentTiles, currentDimension)) bytes per frame")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
        }
    }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            // Recomputed when the drag ends rather than on every intermediate
            // value: a 200-frame run is real work, and `onChange` would start
            // one per rendered frame. `onEditingChanged` is also the only form
            // that is neither deprecated on iOS 17+ nor unavailable on iOS 16,
            // which matters for a package that declares `.iOS(.v16)`.
            Slider(value: value, in: range, step: 1) { editing in
                if !editing { recompute() }
            }
        }
    }

    private func matchBadge(_ comparison: BoundaryComparison) -> some View {
        HStack(spacing: 8) {
            Image(systemName: comparison.outputsMatch ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
            // "Same digest" rather than "byte-identical": the check that ran is
            // an FNV-1a/64 comparison, and the badge should claim what it
            // actually verified.
            Text(comparison.outputsMatch
                 ? "All three boundaries produced the same output digest"
                 : "Outputs diverged — comparison invalid")
                .font(.subheadline.weight(.medium))
        }
        .foregroundColor(comparison.outputsMatch ? .green : .orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.12))
        .cornerRadius(10)
    }

    private func resultGrid(_ comparison: BoundaryComparison) -> some View {
        // Three rows rather than three columns: on a phone, three columns of
        // labelled metrics is unreadable.
        VStack(spacing: 12) {
            column(for: comparison.owning, tint: .green)
            column(for: comparison.consumingValue, tint: .purple)
            column(for: comparison.value, tint: .blue)
        }
    }

    private func column(for result: BoundaryRunResult, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(result.shape.displayName)
                    .font(.subheadline.bold())
                    .foregroundColor(tint)
                Spacer(minLength: 8)
                Text(result.shape.signature)
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
            }
            metric("Allocations", "\(result.stats.allocationCount)")
            metric("Bytes allocated", byteText(result.stats.bytesAllocated))
            metric("Peak live", byteText(result.stats.peakLiveBytes))
            metric("Buffer reuses", "\(result.stats.reuseCount)")
            metric("Boundary copies", "\(result.stats.boundaryCopyCount)")
            metric("Balanced", result.stats.isBalanced ? "yes" : "no")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.10))
        .cornerRadius(10)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Spacer(minLength: 6)
            Text(value).font(.caption.monospacedDigit().weight(.semibold))
        }
    }

    private func allocationBars(_ comparison: BoundaryComparison) -> some View {
        // The widest bar defines the scale. Guarded against a zero maximum so a
        // stageless configuration renders instead of dividing by zero.
        let owning = comparison.owning.stats.allocationCount
        let consuming = comparison.consumingValue.stats.allocationCount
        let value = comparison.value.stats.allocationCount
        let maximum = max(owning, consuming, value, 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Heap allocations").font(.subheadline.bold())
            bar(label: "Owning", count: owning, maximum: maximum, tint: .green)
            bar(label: "Consuming", count: consuming, maximum: maximum, tint: .purple)
            bar(label: "Borrowing", count: value, maximum: maximum, tint: .blue)
            Text(comparison.headline)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
        }
    }

    private func bar(label: String, count: Int, maximum: Int, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 74, alignment: .leading)
            GeometryReader { proxy in
                let fraction = maximum > 0 ? Double(count) / Double(maximum) : 0
                let width = max(2, proxy.size.width * fraction)
                RoundedRectangle(cornerRadius: 4)
                    .fill(tint)
                    .frame(width: width, height: 16)
            }
            .frame(height: 16)
            Text("\(count)").font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
        }
    }

    private var stageList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pipeline").font(.subheadline.bold())
            // `prefix(_:)` traps on a negative length, and `Int(Double)` traps on
            // NaN or out-of-range — the slider cannot produce either, but this
            // is a `public` view and its state is seeded from a `public`
            // initializer, so neither is guaranteed by construction.
            let requested = max(0, Saturating.int(fromDouble: stageCount, fallback: 0))
            let active = Array(FeedStageKind.ladder.prefix(requested))
            if active.isEmpty {
                Text("No stages — the frame is written and read back unchanged.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(active.enumerated()), id: \.offset) { index, kind in
                    Text("\(index + 1). \(kind.displayName)\(kind.isInPlace ? "" : "  · changes size")")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("One keyword separates the two value rows. `consuming` ends the caller's "
                 + "ownership at the call, so an in-place stage mutates uniquely-referenced "
                 + "storage and copy-on-write never fires. Erasure is not what costs the copies.")
            Text("What does not change: only the owning boundary's allocation count is flat "
                 + "in frame count. Both value shapes are linear, because a size-changing "
                 + "stage must produce new storage and a value type has nowhere to recycle it.")
            Text("Peak footprint is comparable on all three. What differs is allocator traffic.")
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    private func banner(_ message: String, tint: Color) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundColor(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.secondary.opacity(0.12))
            .cornerRadius(10)
    }

    // MARK: - Work

    private var currentTiles: Int { max(1, Saturating.int(fromDouble: tileCount, fallback: 1)) }
    private var currentDimension: Int { max(1, Saturating.int(fromDouble: dimension, fallback: 1)) }

    /// Runs the benchmark **off** the main actor.
    ///
    /// This matters more here than in most demos: the worst configuration the
    /// sliders can reach (128 x 128, 200 frames, six stages) is genuinely
    /// seconds of work in a debug build. Running it inline from `onAppear` and
    /// `onEditingChanged` would freeze the UI — a screen whose entire argument
    /// is about the cost of doing avoidable work would be doing avoidable work
    /// on the main thread. The previous run is cancelled, so dragging a slider
    /// repeatedly does not queue up runs behind each other.
    private func recompute() {
        work?.cancel()
        let tiles = currentTiles
        let dim = currentDimension
        let frames = max(1, Saturating.int(fromDouble: frameCount, fallback: 1))
        let stages = max(0, Saturating.int(fromDouble: stageCount, fallback: 0))
        isRunning = true

        work = Task {
            let outcome: Result<BoundaryComparison, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try BoundaryBenchmark.compare(
                        tileCount: tiles, dimension: dim, frameCount: frames, stageCount: stages
                    ))
                } catch {
                    return .failure(error)
                }
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                isRunning = false
                switch outcome {
                case .success(let result):
                    comparison = result
                    failureMessage = nil
                case .failure(let error):
                    comparison = nil
                    failureMessage = String(describing: error)
                }
            }
        }
    }

    private func byteText(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.2f MB", Double(bytes) / (1024 * 1024))
    }
}
#endif
