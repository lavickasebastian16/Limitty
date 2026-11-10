#if canImport(SwiftUI)
import SwiftUI

// Views shared by the app and the widget.

public extension Provider {
    var color: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color.primary
        }
    }
}

public func levelColor(_ percent: Double) -> Color {
    if percent >= 85 { return Color(red: 0.95, green: 0.33, blue: 0.35) }
    if percent >= 60 { return Color(red: 0.95, green: 0.70, blue: 0.24) }
    return Color(red: 0.19, green: 0.71, blue: 0.48)
}

public struct LimitBar: View {
    let percent: Double
    let height: CGFloat

    public init(percent: Double, height: CGFloat = 6) {
        self.percent = percent
        self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(levelColor(percent))
                    .frame(width: max(percent > 0 ? height : 0, geo.size.width * min(percent, 100) / 100))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("\(Int(percent.rounded())) percent used")
    }
}

public struct WindowRow: View {
    let window: LimitWindow
    let showReset: Bool
    let compact: Bool

    public init(_ window: LimitWindow, showReset: Bool = true, compact: Bool = false) {
        self.window = window
        self.showReset = showReset
        self.compact = compact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 3) {
            HStack {
                Text(window.label).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Int(window.usedPercent.rounded()))%").fontWeight(.semibold).monospacedDigit()
            }
            .font(compact ? .caption2 : .caption)
            LimitBar(percent: window.usedPercent, height: compact ? 5 : 6)
            if showReset, let reset = window.resetsAt {
                (Text("resets in ") + Text(reset, style: .relative))
                    .font(.system(size: compact ? 9 : 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

public struct ProviderHeader: View {
    let snapshot: ProviderSnapshot
    let showPlan: Bool

    public init(_ snapshot: ProviderSnapshot, showPlan: Bool = true) {
        self.snapshot = snapshot
        self.showPlan = showPlan
    }

    public var body: some View {
        HStack(spacing: 5) {
            Circle().fill(snapshot.provider.color).frame(width: 7, height: 7)
            Text(snapshot.provider.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
            if showPlan, let plan = snapshot.plan {
                Text(plan)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(Capsule().stroke(Color.secondary.opacity(0.4), lineWidth: 0.5))
            }
            if snapshot.stale {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
}

public struct ErrorLine: View {
    let snapshot: ProviderSnapshot
    public init(_ snapshot: ProviderSnapshot) { self.snapshot = snapshot }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.error ?? "").font(.caption).foregroundStyle(levelColor(100))
            if let hint = snapshot.hint {
                Text(hint).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}
#endif
