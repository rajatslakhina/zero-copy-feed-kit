#if canImport(SwiftUI)
import Foundation
import SwiftUI
import ZeroCopyFeed

/// The knobs the explorer exposes.
///
/// The host app owns the defaults and passes them in, so "what does this screen
/// show when you launch it" is an app-level decision rather than something
/// buried in a library view's initializer.
public struct ExplorerDefaults: Sendable, Equatable {
    public var tileCount: Int
    public var dimension: Int
    public var frameCount: Int
    public var stageCount: Int

    public init(tileCount: Int = 32, dimension: Int = 64, frameCount: Int = 20, stageCount: Int = 6) {
        self.tileCount = tileCount
        self.dimension = dimension
        self.frameCount = frameCount
        self.stageCount = stageCount
    }
}

/// Runs the same feed through both boundary shapes and shows what each one cost.
///
/// The screen recomputes on every slider change and on appear, so the default
/// state already shows a real result rather than an empty placeholder waiting
/// for a button press.
public struct FeedBoundaryExplorerView: View {

    @State private var tileCount: Double
    @State private var dimension: Double
    @State private var frameCount: Double
    @State private var stageCount: Double
    @State private var comparison: BoundaryComparison?
    @State private var failureMessage: String?

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
                } else {
                    banner("Running…", tint: .secondary)
                }
            }
            .padding(20)
        }
        .onAppear(perform: recompute)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Zero-Copy Feed Boundary")
                .font(.title2.bold())
            Text("The same quantized embedding tiles, the same kernels, two module boundaries.")
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
            Text("\(Int(tileCount)) × \(Int(dimension)) = \(Int(tileCount) * Int(dimension)) bytes per frame")
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
            Text(comparison.outputsMatch
                 ? "Both boundaries produced byte-identical output"
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
        HStack(alignment: .top, spacing: 12) {
            column(for: comparison.owning, tint: .green)
            column(for: comparison.value, tint: .blue)
        }
    }

    private func column(for result: BoundaryRunResult, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.shape.displayName)
                .font(.subheadline.bold())
                .foregroundColor(tint)
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
        let value = comparison.value.stats.allocationCount
        let maximum = max(owning, value, 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Heap allocations").font(.subheadline.bold())
            bar(label: "Owning", count: owning, maximum: maximum, tint: .green)
            bar(label: "Value", count: value, maximum: maximum, tint: .blue)
            Text(comparison.headline)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
        }
    }

    private func bar(label: String, count: Int, maximum: Int, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 56, alignment: .leading)
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
            let active = Array(FeedStageKind.ladder.prefix(Int(stageCount)))
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
        Text("Peak footprint is roughly equal on both paths. What differs is allocator "
             + "traffic: the owning boundary's allocation count is flat in frame count, "
             + "the value boundary's is frames × stages.")
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

    private func recompute() {
        do {
            comparison = try BoundaryBenchmark.compare(
                tileCount: Saturating.int(fromDouble: tileCount, fallback: 1),
                dimension: Saturating.int(fromDouble: dimension, fallback: 1),
                frameCount: Saturating.int(fromDouble: frameCount, fallback: 1),
                stageCount: Saturating.int(fromDouble: stageCount, fallback: 0)
            )
            failureMessage = nil
        } catch {
            comparison = nil
            failureMessage = String(describing: error)
        }
    }

    private func byteText(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.2f MB", Double(bytes) / (1024 * 1024))
    }
}
#endif
