#if os(iOS)
import SwiftUI
import WidgetKit
import LimittyCore

@main
struct LimittyWidgetBundle: WidgetBundle {
    var body: some Widget {
        LimitsWidget()
    }
}

struct LimitsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LimitsWidget", provider: LimitsTimeline()) { entry in
            LimitsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Limitty")
        .description("Your Claude, Codex and Gemini usage limits.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ])
    }
}

struct LimitsEntry: TimelineEntry {
    var date: Date
    var snapshots: [ProviderSnapshot]
}

struct LimitsTimeline: TimelineProvider {
    func placeholder(in context: Context) -> LimitsEntry {
        LimitsEntry(date: .now, snapshots: SampleData.snapshots())
    }

    func getSnapshot(in context: Context, completion: @escaping (LimitsEntry) -> Void) {
        let cached = LimitsService().cached()
        completion(LimitsEntry(date: .now, snapshots: context.isPreview && cached.isEmpty ? SampleData.snapshots() : cached))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LimitsEntry>) -> Void) {
        Task {
            let snapshots = await LimitsService().refreshAll()
            // iOS treats this as a hint; widgets typically refresh every 15–30 minutes.
            completion(Timeline(entries: [LimitsEntry(date: .now, snapshots: snapshots)],
                                policy: .after(.now.addingTimeInterval(15 * 60))))
        }
    }
}

struct LimitsWidgetView: View {
    let entry: LimitsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entry.snapshots.isEmpty {
            empty
        } else {
            switch family {
            case .accessoryInline: inline
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .systemSmall: small
            case .systemLarge: large
            default: medium
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.33percent")
            Text("Open Limitty to sign in").font(.caption).multilineTextAlignment(.center)
        }
    }

    // MARK: Home Screen

    /// How many limit rows fit per service, given how many services are shown.
    private var rowsPerService: Int {
        switch entry.snapshots.count {
        case 1: 3
        case 2: 2
        default: 1
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: entry.snapshots.count > 2 ? 5 : 8) {
            ForEach(entry.snapshots) { snap in
                VStack(alignment: .leading, spacing: 3) {
                    ProviderHeader(snap, showPlan: false)
                    if snap.ok {
                        ForEach(snap.windows.prefix(rowsPerService)) { WindowRow($0, showReset: false, compact: true) }
                    } else {
                        Text(snap.error ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: entry.snapshots.count > 2 ? 10 : 14) {
            ForEach(entry.snapshots) { snap in
                VStack(alignment: .leading, spacing: 5) {
                    ProviderHeader(snap, showPlan: entry.snapshots.count < 3)
                    if snap.ok {
                        ForEach(snap.windows.prefix(3)) { WindowRow($0, showReset: entry.snapshots.count < 3, compact: true) }
                    } else {
                        ErrorLine(snap)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(entry.snapshots) { snap in
                VStack(alignment: .leading, spacing: 6) {
                    ProviderHeader(snap)
                    if snap.ok {
                        ForEach(snap.windows) { WindowRow($0) }
                    } else {
                        ErrorLine(snap)
                    }
                }
            }
            Spacer(minLength: 0)
            Text("Updated \(entry.date.formatted(date: .omitted, time: .shortened))")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Lock Screen

    private var inline: some View {
        Text(entry.snapshots.map { s in
            "\(s.provider.displayName) " + (s.worst.map { "\(Int($0.usedPercent.rounded()))%" } ?? "–")
        }.joined(separator: " · "))
    }

    private var circular: some View {
        let snap = entry.snapshots[0]
        let window = snap.windows.first
        return Gauge(value: (window?.usedPercent ?? 0) / 100) {
            Text(snap.provider.displayName.prefix(1))
        } currentValueLabel: {
            Text(window.map { "\(Int($0.usedPercent.rounded()))" } ?? "–")
        }
        .gaugeStyle(.accessoryCircular)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(entry.snapshots) { snap in
                HStack(spacing: 4) {
                    Text(snap.provider.displayName).font(.caption.weight(.semibold))
                    Spacer(minLength: 2)
                    Text(snap.ok ? snap.windows.prefix(2).map { "\(Int($0.usedPercent.rounded()))%" }.joined(separator: " · ") : "–")
                        .font(.caption).monospacedDigit()
                }
                if snap.ok, entry.snapshots.count < 3, let first = snap.windows.first {
                    Gauge(value: first.usedPercent / 100) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                }
            }
        }
    }
}
#endif
