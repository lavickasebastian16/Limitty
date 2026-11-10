import Foundation

/// Files shared between the app and the widget through the App Group container.
///
/// xtool renames App Groups for free Apple IDs: `group.com.limitty.shared`
/// becomes `group.XTL-<ID>.com.limitty.shared`, using the same `XTL-<ID>` prefix
/// it adds to the bundle ID. We work out the real name from our own bundle ID.
public final class SharedStore: @unchecked Sendable {
    public static let baseGroup = "com.limitty.shared"

    public let directory: URL
    /// True when the widget and the app can share data (the App Group was found).
    public let isShared: Bool
    private let lock = NSLock()

    public init(directory: URL, isShared: Bool = false) {
        self.directory = directory
        self.isShared = isShared
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static let shared: SharedStore = {
        let (dir, shared) = resolveDirectory()
        return SharedStore(directory: dir, isShared: shared)
    }()

    /// App Group names to try, best guess first. Sideloading tools (xtool,
    /// Sideloadly, AltStore…) each rename the group differently, so the group
    /// listed in our own signing profile wins when there is one.
    public static func groupCandidates(bundleID: String?, profileGroups: [String] = []) -> [String] {
        var out = profileGroups.filter { $0.contains(baseGroup) } + profileGroups.filter { !$0.contains(baseGroup) }
        if let id = bundleID, id.hasPrefix("XTL-"), let prefix = id.split(separator: ".").first {
            out.append("group.\(prefix).\(baseGroup)")
        }
        out.append("group.\(baseGroup)")
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// Reads `com.apple.security.application-groups` from an `embedded.mobileprovision`
    /// (a signed blob with a plain XML plist inside).
    public static func appGroups(fromProvisioningProfile data: Data) -> [String] {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let ents = plist["Entitlements"] as? [String: Any],
              let groups = ents["com.apple.security.application-groups"] as? [String]
        else { return [] }
        return groups
    }

    static func resolveDirectory() -> (URL, Bool) {
        #if canImport(Darwin)
        let profile = Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")
        let profileGroups = (try? Data(contentsOf: profile)).map(appGroups(fromProvisioningProfile:)) ?? []
        for group in groupCandidates(bundleID: Bundle.main.bundleIdentifier, profileGroups: profileGroups) {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
                return (url.appendingPathComponent("Limitty", isDirectory: true), true)
            }
        }
        #endif
        // No shared container (e.g. a sideloading tool dropped the App Group): the
        // app still works, but the widget can't see your logins.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return (base.appendingPathComponent("Limitty", isDirectory: true), false)
    }

    // MARK: credentials

    private var credentialsURL: URL { directory.appendingPathComponent("credentials.json") }
    private var snapshotsURL: URL { directory.appendingPathComponent("snapshots.json") }

    public func credential(for p: Provider) -> Credential? { read([Provider: Credential].self, credentialsURL)?[p] }

    public func setCredential(_ c: Credential?, for p: Provider) {
        update([Provider: Credential].self, credentialsURL) { $0[p] = c }
    }

    // MARK: last results

    public func snapshots() -> [Provider: ProviderSnapshot] { read([Provider: ProviderSnapshot].self, snapshotsURL) ?? [:] }

    public func saveSnapshot(_ s: ProviderSnapshot) { update([Provider: ProviderSnapshot].self, snapshotsURL) { $0[s.provider] = s } }

    public func removeSnapshot(_ p: Provider) { update([Provider: ProviderSnapshot].self, snapshotsURL) { $0[p] = nil } }

    // MARK: file io

    private func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func update<T: Codable & ExpressibleByDictionaryLiteral>(_ type: T.Type, _ url: URL, _ change: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var value = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(T.self, from: $0) } ?? [:]
        change(&value)
        guard let data = try? JSONEncoder().encode(value) else { return }
        #if os(iOS)
        // Readable by the widget after the first unlock following a reboot.
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url, options: .atomic)
        #endif
    }
}
