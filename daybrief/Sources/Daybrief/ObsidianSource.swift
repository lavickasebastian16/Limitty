#if os(iOS)
import Foundation
import DaybriefCore

/// Reads the notes of an Obsidian vault folder you picked in the Files browser.
/// iOS only lets an app open a folder you chose, and remembers the choice
/// through a "bookmark".
enum ObsidianSource {
    private static let bookmarkKey = "obsidianBookmark"
    static let chooseAgain = "Daybrief can't open the vault folder any more. Choose it again in Connections."

    static var isConnected: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }

    /// Remembers the folder. Returns the vault's name.
    static func connect(_ folder: URL) throws -> String {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let data = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        return folder.lastPathComponent
    }

    static func disconnect() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    static func tasks() async throws -> [Item] {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return [] }
        return try await Task.detached(priority: .utility) { try read(bookmark) }.value
    }

    private static func read(_ bookmark: Data) throws -> [Item] {
        var stale = false
        guard let root = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            throw BriefError(chooseAgain)
        }
        guard root.startAccessingSecurityScopedResource() else { throw BriefError(chooseAgain) }
        defer { root.stopAccessingSecurityScopedResource() }
        if stale, let fresh = try? root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }

        let vault = root.lastPathComponent
        let rootParts = root.standardizedFileURL.pathComponents
        // Hidden folders (.obsidian, .trash) are skipped.
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey],
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw BriefError(chooseAgain)
        }
        var items: [Item] = []
        var count = 0
        while let file = files.nextObject() as? URL {
            guard file.pathExtension.lowercased() == "md" else { continue }
            count += 1
            if count > 5000 { break }
            // Very large notes are skipped to keep refreshes quick.
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_000_000 { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8), text.contains("[") else { continue }
            let parts = file.standardizedFileURL.pathComponents
            let relative = parts.count > rootParts.count ? parts.dropFirst(rootParts.count).joined(separator: "/") : file.lastPathComponent
            items += ObsidianParser.tasks(in: text, file: relative, vault: vault)
        }
        return items
    }
}
#endif
