#if os(iOS)
import SwiftUI
import UIKit
import DaybriefCore

/// Colours and small pieces shared by every screen.
enum Theme {
    static let accent = Color.indigo
    /// The colour of a card on the grouped background (same as a list row).
    static let card = Color(.secondarySystemGroupedBackground)

    /// A calendar's colour as "#RRGGBB".
    static func hex(_ color: CGColor?) -> String? {
        guard let color else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(cgColor: color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        let parts = [r, g, b].map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2])
    }

    static func greeting(_ date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }
}

extension Color {
    /// "#RRGGBB" → a colour.
    init?(hex: String?) {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

extension Source {
    var symbol: String {
        switch self {
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .obsidian: return "note.text"
        case .edupage: return "graduationcap.fill"
        case .gmail: return "envelope.fill"
        }
    }

    var color: Color {
        switch self {
        case .calendar: return .red
        case .reminders: return .orange
        case .obsidian: return .purple
        case .edupage: return .blue
        case .gmail: return .green
        }
    }

    /// One line on what it adds, for the welcome screen.
    var blurb: String {
        switch self {
        case .calendar: return "Your events"
        case .reminders: return "Your to-dos, with tick-off"
        case .obsidian: return "Open tasks in your notes"
        case .edupage: return "Homework, exams, school events"
        case .gmail: return "Starred and unread mail"
        }
    }
}

extension Item {
    /// Its calendar's or list's own colour, else the colour of its source.
    var color: Color { Color(hex: tint) ?? source.color }
}

/// A symbol on a soft rounded square, like the icons in the Settings app.
struct IconBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(color.opacity(0.16)))
    }
}

/// A section heading: a bold title, with a quieter note on the right.
struct SectionTitle: View {
    let title: String
    var detail = ""
    var color = Color.primary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.bold)).foregroundStyle(color)
            Spacer()
            if !detail.isEmpty {
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
        .padding(.bottom, 2)
    }
}

/// Shown in a list when there is nothing to list.
struct EmptyNote: View {
    let symbol: String
    let title: String
    var text = ""

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            if !text.isEmpty {
                Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .listRowBackground(Color.clear)
    }
}

/// "All · Calendar · Reminders …": show one source only.
struct SourceChips: View {
    let sources: [Source]
    let selected: Source?
    let pick: (Source?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", nil)
                ForEach(sources, id: \.self) { chip($0.label, $0) }
            }
        }
    }

    private func chip(_ title: String, _ source: Source?) -> some View {
        Button {
            pick(source)
        } label: {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(selected == source ? Color.white : Color.primary)
                .background(Capsule().fill(selected == source ? Theme.accent : Theme.card))
        }
        .buttonStyle(.borderless)
    }
}

/// The gear in the top bar.
struct GearButton: ToolbarContent {
    @Binding var show: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                show = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }
}

extension View {
    /// The round microphone button in the bottom corner: speak (or type) to add a task.
    func micButton(_ show: Binding<Bool>) -> some View {
        safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
            Button {
                show.wrappedValue = true
            } label: {
                Image(systemName: "mic.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 58, height: 58)
                    .background(Circle().fill(LinearGradient(colors: [Theme.accent, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .shadow(color: Theme.accent.opacity(0.35), radius: 8, y: 4)
            }
            .accessibilityLabel("Add a task")
            .padding(.trailing, 20)
            .padding(.bottom, 12)
        }
    }
}
#endif
