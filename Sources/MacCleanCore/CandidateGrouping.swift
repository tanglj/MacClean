import Foundation

public struct CandidateGroup: Identifiable, Sendable {
    public let directory: URL
    public let locations: [URL]
    public let candidates: [ScanCandidate]
    private let groupID: String
    public var id: String { groupID }
    public let title: String
    public let size: Int64
    public let risk: RiskLevel
    public let categories: [String]
    public let tree: CandidateDirectory

    init(directory: URL, locations: [URL] = [], candidates: [ScanCandidate], title: String? = nil, groupID: String? = nil) {
        self.directory = directory
        self.locations = locations.isEmpty ? [directory] : locations
        self.candidates = candidates
        self.groupID = groupID ?? directory.path
        self.title = title ?? Self.defaultTitle(for: directory, candidates: candidates)
        tree = CandidateDirectory(url: directory, candidates: candidates)
        size = candidates.reduce(0) { $0 + $1.size }
        risk = candidates.map(\.risk).max { $0.rawValue < $1.rawValue } ?? .prohibited
        let names = Dictionary(uniqueKeysWithValues: RuleCatalog.builtInRules.map { ($0.id, $0.name) })
        categories = Set(candidates.map { names[$0.ruleID] ?? $0.ruleID }).sorted()
    }

    private static func defaultTitle(for directory: URL, candidates: [ScanCandidate]) -> String {
        guard candidates.allSatisfy({ $0.ruleID == "app.orphan" }) else {
            return directory.lastPathComponent
        }
        let identifier = directory.lastPathComponent
            .replacingOccurrences(of: ".binarycookies", with: "")
            .replacingOccurrences(of: ".plist", with: "")
            .replacingOccurrences(of: ".sqlite", with: "")
            .replacingOccurrences(of: ".db", with: "")
        let displayName = ApplicationNameMapping.shared.displayName(for: identifier) ?? identifier
        return "疑似残留 · \(displayName)"
    }
    public var impact: String {
        if let first = candidates.first, first.ruleID == "app.orphan", let reason = first.evidence.first { return reason }
        if risk.requiresExplicitSelection { return "可能包含个人资料或需要重新下载的数据，请展开确认。" }
        return "缓存可能需要重新下载；删除日志后将无法查看对应的历史诊断记录。"
    }

    public var locationDescription: String {
        locations.count == 1 ? locations[0].path : "多个位置（\(locations.count)）"
    }
}

public enum CandidateGrouping {
    public static func groups(for candidates: [ScanCandidate], groupIDPrefix: String? = nil) -> [CandidateGroup] {
        let grouped = Dictionary(grouping: candidates) { candidate -> URL in
            if candidate.ruleID == "app.orphan", let location = HomeLogSource.enclosingRoot(candidate.url) { return location.root }
            if candidate.ruleID == "app.orphan", candidate.url.deletingLastPathComponent().lastPathComponent == "Preferences" { return candidate.url.standardizedFileURL }
            let parent = candidate.url.deletingLastPathComponent()
            let parts = parent.pathComponents
            guard let library = parts.firstIndex(of: "Library"), library + 1 < parts.count else { return parent }
            // Retain the category and its immediate owner directory, never a file name.
            let end = min(library + 2, parts.count - 1)
            return URL(fileURLWithPath: NSString.path(withComponents: Array(parts[...end])), isDirectory: true)
        }
        let nameResolver = CandidateApplicationNameResolver(directories: Array(grouped.keys))
        let groupedByApplication = Dictionary(grouping: grouped) { entry in
            if let owner = entry.value.first?.residualOwner, entry.value.allSatisfy({ $0.residualOwner == owner }) { return owner }
            if let first = entry.value.first, first.ruleID == "app.orphan", let location = HomeLogSource.enclosingRoot(first.url) { return location.source.identifier }
            return nameResolver.identity(for: entry.key) ?? "directory:\(entry.key.path)"
        }
        let result = groupedByApplication.map { identity, entries -> CandidateGroup in
            let candidates = entries.flatMap(\.value).sorted(by: candidateSort)
            let locations = entries.map(\.key).sorted { $0.path < $1.path }
            let roots = candidates.map { candidate in
                candidate.ruleID == "app.orphan" ? candidate.url : candidate.url.deletingLastPathComponent()
            }
            let directory = entries.count == 1
                ? entries[0].key
                : commonAncestor(of: roots) ?? locations[0]
            let title = candidates.allSatisfy { $0.ruleID == "app.orphan" }
                ? (HomeLogSource.all.first(where: { $0.identifier == identity })?.name ?? candidates.first?.residualOwner.map { ApplicationNameMapping.shared.displayName(for: $0) ?? $0 }).map { "疑似残留 · \($0)" }
                : nameResolver.title(for: entries[0].key)
            let groupID = groupIDPrefix.map { "\($0)|\(identity)" } ?? identity
            return CandidateGroup(directory: directory, locations: locations, candidates: candidates, title: title, groupID: groupID)
        }
        return result.sorted(by: groupSort)
    }

    private static func candidateSort(_ lhs: ScanCandidate, _ rhs: ScanCandidate) -> Bool {
        if lhs.size != rhs.size { return lhs.size > rhs.size }
        return lhs.url.path < rhs.url.path
    }

    private static func groupSort(_ lhs: CandidateGroup, _ rhs: CandidateGroup) -> Bool {
        if lhs.size != rhs.size { return lhs.size > rhs.size }
        return lhs.id < rhs.id
    }

    private static func commonAncestor(of urls: [URL]) -> URL? {
        guard let first = urls.first else { return nil }
        var components = first.standardizedFileURL.pathComponents
        for url in urls.dropFirst() {
            let other = url.standardizedFileURL.pathComponents
            let count = zip(components, other).prefix { $0 == $1 }.count
            components = Array(components.prefix(count))
            if components.isEmpty { return nil }
        }
        return URL(fileURLWithPath: NSString.path(withComponents: components), isDirectory: true)
    }
}

private struct CandidateApplicationNameResolver {
    private struct InstalledApplication {
        let bundleIdentifier: String
        let fileName: String
        let displayName: String?
        let bundleName: String?
    }

    private let applications: [InstalledApplication]
    private let mapping = ApplicationNameMapping.shared

    init(directories: [URL]) {
        let homes = Set(directories.compactMap(Self.homeDirectory(for:)))
        var roots = homes.map { $0.appendingPathComponent("Applications", isDirectory: true) }
        let currentHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        if homes.contains(currentHome) {
            roots += [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                URL(fileURLWithPath: "/System/Applications", isDirectory: true)
            ]
        }
        applications = Self.loadApplications(from: roots)
    }

    func title(for directory: URL) -> String {
        let fallback = directory.lastPathComponent
        if let bundleIdentifier = mapping.bundleIdentifier(matching: fallback),
           let mappedName = mapping.name(for: bundleIdentifier) {
            return mappedName
        }
        guard let application = applications.first(where: { matches(fallback, application: $0) }) else { return fallback }
        if let mappedName = mapping.name(for: application.bundleIdentifier) {
            return mappedName
        }
        return application.displayName ?? application.bundleName ?? application.fileName
    }

    func identity(for directory: URL) -> String? {
        if let bundleIdentifier = mapping.bundleIdentifier(matching: directory.lastPathComponent) {
            return bundleIdentifier.lowercased()
        }
        return applications.first(where: { matches(directory.lastPathComponent, application: $0) })?.bundleIdentifier.lowercased()
    }

    private func matches(_ directoryName: String, application: InstalledApplication) -> Bool {
        let normalized = Self.normalized(directoryName)
        if let bundleIdentifier = mapping.bundleIdentifier(matching: directoryName),
           Self.normalized(bundleIdentifier) == normalized {
            return true
        }
        let names = [application.bundleIdentifier, application.fileName, application.displayName, application.bundleName]
            .compactMap { $0 }
        if names.contains(where: { Self.normalized($0) == normalized }) { return true }

        let ignoredBundleParts = Set(["com", "org", "net", "app", "mac", "desktop"])
        return application.bundleIdentifier
            .split(separator: ".")
            .map { Self.normalized(String($0)) }
            .contains { !ignoredBundleParts.contains($0) && $0 == normalized }
    }

    private static func homeDirectory(for directory: URL) -> URL? {
        let parts = directory.standardizedFileURL.pathComponents
        guard let library = parts.firstIndex(of: "Library"), library > 0 else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(parts[..<library])), isDirectory: true).standardizedFileURL
    }

    private static func loadApplications(from roots: [URL]) -> [InstalledApplication] {
        var applications: [String: InstalledApplication] = [:]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "app" {
                guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
                      let bundleIdentifier = info["CFBundleIdentifier"] as? String else { continue }
                let application = InstalledApplication(
                    bundleIdentifier: bundleIdentifier,
                    fileName: url.deletingPathExtension().lastPathComponent,
                    displayName: ApplicationMetadata.displayName(at: url, info: info),
                    bundleName: info["CFBundleName"] as? String
                )
                applications[bundleIdentifier.lowercased()] = application
            }
        }
        return Array(applications.values)
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
