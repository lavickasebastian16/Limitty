import Foundation

/// Reads open tasks from Obsidian notes.
///
/// Understands plain checkboxes (`- [ ] Buy milk`), the Tasks plugin
/// (`📅 2026-11-14`, `⏳ 2026-11-14`), Dataview fields (`[due:: 2026-11-14]`)
/// and `@due(2026-11-14)`. A task without a date in a daily note
/// (`2026-11-14.md`) is due on that day.
public enum ObsidianParser {
    private static let isoDate = "(\\d{4}-\\d{2}-\\d{2})"
    private static let taskLine = Rx("^\\s*(?:[-*+]|\\d+[.)])\\s+\\[(.)\\]\\s+(.*)$")
    private static let dueRules = [
        Rx("📅\\x{FE0F}?\\s*" + isoDate),
        Rx("[\\[(]due::\\s*" + isoDate),
        Rx("@due\\(\\s*" + isoDate),
        Rx("⏳\\x{FE0F}?\\s*" + isoDate),
        Rx("[\\[(]scheduled::\\s*" + isoDate),
    ]
    private static let fileDate = Rx(isoDate)
    private static let leadingTime = Rx("^(\\d{1,2}):(\\d{2})(?:\\s*[-–]\\s*\\d{1,2}:\\d{2})?\\s+(.+)$")

    private static let cleanups: [(Rx, String)] = [
        (Rx("[📅⏳🛫✅➕❌]\\x{FE0F}?\\s*\\d{4}-\\d{2}-\\d{2}"), ""),
        (Rx("🔁\\x{FE0F}?[^📅⏳🛫✅➕❌⏫🔼🔽🔺⏬]*"), ""),
        (Rx("[⏫🔼🔽🔺⏬]\\x{FE0F}?"), ""),
        (Rx("[\\[(][A-Za-z_]+::[^\\])]*[\\])]"), ""),
        (Rx("@due\\([^)]*\\)"), ""),
        (Rx("\\s\\^[A-Za-z0-9-]+\\s*$"), ""),
        (Rx("\\[\\[(?:[^\\]|]*\\|)?([^\\]]*)\\]\\]"), "$1"),
        (Rx("\\[([^\\]]*)\\]\\([^)]*\\)"), "$1"),
        (Rx("#task\\b"), ""),
        (Rx("\\s+"), " "),
    ]

    /// The open tasks in one note. `file` is the note's path inside the vault.
    public static func tasks(in text: String, file: String, vault: String, calendar: Calendar = .current) -> [Item] {
        let fileName = (file as NSString).lastPathComponent
        let noteName = (fileName as NSString).deletingPathExtension
        let noteDay = fileDate.groups(in: noteName)?[1].flatMap { DayParser.date($0, calendar: calendar) }
        let link = openLink(vault: vault, file: file)

        var items: [Item] = []
        var inCode = false
        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inCode.toggle()
                continue
            }
            if inCode { continue }
            guard let g = taskLine.groups(in: rawLine.replacingOccurrences(of: "\r", with: "")),
                  let status = g[1], let rest = g[2] else { continue }
            // " " is open and "/" is in progress; anything else is done or cancelled.
            guard status == " " || status == "/" else { continue }

            var day: Date?
            for rule in dueRules {
                if let text = rule.groups(in: rest)?[1], let d = DayParser.date(text, calendar: calendar) {
                    day = d
                    break
                }
            }
            day = day ?? noteDay

            var title = rest
            for (rx, template) in cleanups { title = rx.replace(in: title, with: template) }
            title = title.trimmingCharacters(in: .whitespaces)

            // "09:30 Call the dentist" or "09:30 - 10:00 Call the dentist".
            var date = day
            var hasTime = false
            if let t = leadingTime.groups(in: title), let hs = t[1], let ms = t[2], let name = t[3],
               let h = Int(hs), let m = Int(ms), h < 24, m < 60 {
                title = name
                if let d = day, let timed = calendar.date(bySettingHour: h, minute: m, second: 0, of: d) {
                    date = timed
                    hasTime = true
                }
            }
            guard !title.isEmpty else { continue }

            items.append(Item(id: "obsidian:\(file):\(index + 1)", source: .obsidian, kind: .task, title: title,
                              detail: noteName, date: date, hasTime: hasTime, link: link))
        }
        return items
    }

    /// `obsidian://open?vault=…&file=…`
    public static func openLink(vault: String, file: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let v = vault.addingPercentEncoding(withAllowedCharacters: allowed) ?? vault
        let f = file.addingPercentEncoding(withAllowedCharacters: allowed) ?? file
        return "obsidian://open?vault=\(v)&file=\(f)"
    }
}
