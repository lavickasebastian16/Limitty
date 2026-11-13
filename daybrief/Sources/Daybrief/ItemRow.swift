#if os(iOS)
import SwiftUI
import UIKit
import DaybriefCore

/// One item in a list: tap to open it in its own app, tap the circle to tick it
/// off, swipe or press and hold for more.
struct ItemRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let item: Item
    /// The day this row is listed under.
    let day: Date?
    /// Show the date as well as the time (for overdue items and email).
    let showDay: Bool
    /// Past its date: the date is shown in red.
    let late: Bool
    @State private var ticked = false

    init(item: Item, day: Date? = nil, showDay: Bool = false, late: Bool = false) {
        self.item = item
        self.day = day
        self.showDay = showDay
        self.late = late
    }

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .strikethrough(ticked)
                    .foregroundStyle(ticked ? Color.secondary : Color.primary)
                    .lineLimit(3)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { open() }
        .accessibilityAddTraits(.isButton)
        .swipeActions(edge: .trailing) {
            if model.canComplete(item) {
                Button {
                    Task { await model.complete(item) }
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .tint(.green)
            }
            Button {
                withAnimation { model.hide(item) }
            } label: {
                Label("Hide", systemImage: "eye.slash")
            }
            .tint(.gray)
        }
        .swipeActions(edge: .leading) {
            if item.source == .reminders {
                Button {
                    model.postpone(item)
                } label: {
                    Label("Tomorrow", systemImage: "arrow.turn.up.right")
                }
                .tint(.orange)
            }
        }
        .contextMenu {
            if item.link != nil {
                Button {
                    open()
                } label: {
                    Label("Open in \(item.source.label)", systemImage: "arrow.up.forward.app")
                }
            }
            if model.canComplete(item) {
                Button {
                    tick()
                } label: {
                    Label("Mark done", systemImage: "checkmark.circle")
                }
            }
            if item.source == .reminders {
                Button {
                    model.postpone(item)
                } label: {
                    Label("Move to tomorrow", systemImage: "arrow.turn.up.right")
                }
            }
            Button {
                withAnimation { model.hide(item) }
            } label: {
                Label("Hide", systemImage: "eye.slash")
            }
        }
    }

    @ViewBuilder
    private var leading: some View {
        if model.canComplete(item) {
            Button {
                tick()
            } label: {
                Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                    .foregroundStyle(ticked ? Color.green : item.color)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .frame(width: 30, height: 30)
            .accessibilityLabel("Mark done")
        } else {
            IconBadge(symbol: item.source.symbol, color: item.color)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let time = times {
            VStack(alignment: .trailing, spacing: 2) {
                Text(time.main)
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(late ? Color.red : Color.primary)
                if let until = time.until {
                    Text(until).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var subtitle: String {
        [item.source.label, item.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "14:30" (with the end time under it), "All day", or the date for overdue items and email.
    private var times: (main: String, until: String?)? {
        guard let date = item.date else { return nil }
        let cal = Calendar.current
        if showDay {
            let today = cal.isDateInToday(date) && item.hasTime
            return (today ? date.formatted(date: .omitted, time: .shortened) : date.formatted(.dateTime.day().month(.abbreviated)), nil)
        }
        if let day = day, item.kind == .event, !item.hasTime || date < cal.startOfDay(for: day) { return ("All day", nil) }
        guard item.hasTime else { return nil }
        var until: String?
        if item.kind == .event, let end = item.end, end > date, cal.isDate(end, inSameDayAs: date) {
            until = end.formatted(date: .omitted, time: .shortened)
        }
        return (date.formatted(date: .omitted, time: .shortened), until)
    }

    /// Shows the tick, then removes the task a moment later.
    private func tick() {
        guard !ticked else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy) { ticked = true }
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            let done = await model.complete(item)
            if !done { withAnimation { ticked = false } }
        }
    }

    private func open() {
        guard let link = item.link, let url = URL(string: link) else { return }
        openURL(url) { opened in
            // No Gmail app: open Gmail in the browser instead.
            if !opened, item.source == .gmail, let web = URL(string: "https://mail.google.com/") { openURL(web) }
        }
    }
}
#endif
