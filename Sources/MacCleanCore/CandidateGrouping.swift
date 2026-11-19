import Foundation

public struct CandidateGroup: Identifiable, Sendable {
    public let directory: URL
    public let candidates: [ScanCandidate]
    public var id: String { directory.path }
    public let title: String
    public let size: Int64
    public let risk: RiskLevel
    public let categories: [String]
    public let tree: CandidateDirectory

    init(directory: URL, candidates: [ScanCandidate], title: String? = nil) {
        self.directory = directory
        self.candidates = candidates
        self.title = title ?? directory.lastPathComponent
        tree = CandidateDirectory(url: directory, candidates: candidates)
        size = candidates.reduce(0) { $0 + $1.size }
        risk = candidates.map(\.risk).max { $0.rawValue < $1.rawValue } ?? .prohibited
        let names = Dictionary(uniqueKeysWithValues: RuleCatalog.builtInRules.map { ($0.id, $0.name) })
        categories = Set(candidates.map { names[$0.ruleID] ?? $0.ruleID }).sorted()
    }
    public var impact: String {
        if risk.requiresExplicitSelection { return "可能包含个人资料或需要重新下载的数据，请展开确认。" }
        return "缓存可能需要重新下载；删除日志后将无法查看对应的历史诊断记录。"
    }
}

public enum CandidateGrouping {
    public static func groups(for candidates: [ScanCandidate]) -> [CandidateGroup] {
        let grouped = Dictionary(grouping: candidates) { candidate -> URL in
            let parent = candidate.url.deletingLastPathComponent()
            let parts = parent.pathComponents
            guard let library = parts.firstIndex(of: "Library"), library + 1 < parts.count else { return parent }
            // Retain the category and its immediate owner directory, never a file name.
            let end = min(library + 2, parts.count - 1)
            return URL(fileURLWithPath: NSString.path(withComponents: Array(parts[...end])), isDirectory: true)
        }
        let nameResolver = CandidateApplicationNameResolver(directories: Array(grouped.keys))
        let result = grouped.map { entry -> CandidateGroup in
            let candidates = entry.value.sorted(by: candidateSort)
            return CandidateGroup(directory: entry.key, candidates: candidates, title: nameResolver.title(for: entry.key))
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
}

private struct CandidateApplicationNameResolver {
    private struct InstalledApplication {
        let bundleIdentifier: String
        let fileName: String
        let displayName: String?
        let bundleName: String?
    }

    private let applications: [InstalledApplication]

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
        guard let application = applications.first(where: { matches(fallback, application: $0) }) else { return fallback }
        return application.displayName ?? application.bundleName ?? application.fileName
    }

    private func matches(_ directoryName: String, application: InstalledApplication) -> Bool {
        let normalized = Self.normalized(directoryName)
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
