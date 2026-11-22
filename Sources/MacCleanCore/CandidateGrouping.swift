import Foundation

private final class CandidateTreeStorage: @unchecked Sendable {
    private let directory: URL
    private let candidates: [ScanCandidate]
    private let lock = NSLock()
    private var cachedTree: CandidateDirectory?

    init(directory: URL, candidates: [ScanCandidate]) {
        self.directory = directory
        self.candidates = candidates
    }

    func tree() -> CandidateDirectory {
        lock.lock()
        defer { lock.unlock() }
        if let cachedTree { return cachedTree }
        let tree = CandidateDirectory(url: directory, candidates: candidates)
        cachedTree = tree
        return tree
    }
}

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
    private let treeStorage: CandidateTreeStorage
    public var tree: CandidateDirectory { treeStorage.tree() }

    init(directory: URL, locations: [URL] = [], candidates: [ScanCandidate], title: String? = nil, groupID: String? = nil) {
        self.directory = directory
        self.locations = locations.isEmpty ? [directory] : locations
        self.candidates = candidates
        self.groupID = groupID ?? directory.path
        self.title = title ?? Self.defaultTitle(for: directory, candidates: candidates)
        treeStorage = CandidateTreeStorage(directory: directory, candidates: candidates)
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
        CandidateGroupingContext(candidates: candidates).groups(for: candidates, groupIDPrefix: groupIDPrefix)
    }

    static func context(for candidates: [ScanCandidate]) -> CandidateGroupingContext {
        CandidateGroupingContext(candidates: candidates)
    }

    fileprivate static func groups(for candidates: [ScanCandidate], groupIDPrefix: String?, nameResolver: CandidateApplicationNameResolver) -> [CandidateGroup] {
        let grouped = Dictionary(grouping: candidates, by: groupingDirectory(for:))
        return groups(for: grouped, groupIDPrefix: groupIDPrefix, nameResolver: nameResolver, identityByDirectory: nil, titleByDirectory: nil)
    }

    fileprivate static func groups(
        for grouped: [URL: [ScanCandidate]],
        groupIDPrefix: String?,
        nameResolver: CandidateApplicationNameResolver,
        identityByDirectory: [URL: String]?,
        titleByDirectory: [URL: String]?
    ) -> [CandidateGroup] {
        let groupedByApplication = Dictionary(grouping: grouped) { entry in
            if let owner = entry.value.first?.residualOwner, entry.value.allSatisfy({ $0.residualOwner == owner }) { return owner }
            if let first = entry.value.first, first.ruleID == "app.orphan", let location = HomeLogSource.enclosingRoot(first.url) { return location.source.identifier }
            return identityByDirectory?[entry.key] ?? nameResolver.identity(for: entry.key) ?? "directory:\(entry.key.path)"
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
                : titleByDirectory?[entries[0].key] ?? nameResolver.title(for: entries[0].key)
            let groupID = groupIDPrefix.map { "\($0)|\(identity)" } ?? identity
            return CandidateGroup(directory: directory, locations: locations, candidates: candidates, title: title, groupID: groupID)
        }
        return result.sorted(by: groupSort)
    }

    fileprivate static func groupingDirectory(for candidate: ScanCandidate) -> URL {
        if candidate.ruleID == "app.orphan", let location = HomeLogSource.enclosingRoot(candidate.url) { return location.root }
        if candidate.ruleID == "app.orphan", candidate.url.deletingLastPathComponent().lastPathComponent == "Preferences" { return candidate.url.standardizedFileURL }
        let parent = candidate.url.deletingLastPathComponent()
        let parts = parent.pathComponents
        guard let library = parts.firstIndex(of: "Library"), library + 1 < parts.count else { return parent }
        // Retain the category and its immediate owner directory, never a file name.
        let end = min(library + 2, parts.count - 1)
        return URL(fileURLWithPath: NSString.path(withComponents: Array(parts[...end])), isDirectory: true)
    }

    fileprivate static func candidateSort(_ lhs: ScanCandidate, _ rhs: ScanCandidate) -> Bool {
        if lhs.size != rhs.size { return lhs.size > rhs.size }
        return lhs.url.path < rhs.url.path
    }

    fileprivate static func groupSort(_ lhs: CandidateGroup, _ rhs: CandidateGroup) -> Bool {
        if lhs.size != rhs.size { return lhs.size > rhs.size }
        return lhs.id < rhs.id
    }

    fileprivate static func commonAncestor(of urls: [URL]) -> URL? {
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

struct CandidateGroupingContext: Sendable {
    let nameResolver: CandidateApplicationNameResolver
    private let groupingDirectoryByCandidateID: [UUID: URL]
    private let identityByDirectory: [URL: String]
    private let titleByDirectory: [URL: String]

    init(candidates: [ScanCandidate]) {
        let groupingDirectories = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, CandidateGrouping.groupingDirectory(for: $0)) })
        let directories = Set(groupingDirectories.values)
        let nameResolver = CandidateApplicationNameResolver(directories: Array(directories))
        self.nameResolver = nameResolver
        groupingDirectoryByCandidateID = groupingDirectories
        identityByDirectory = Dictionary(uniqueKeysWithValues: directories.map { directory in
            (directory, nameResolver.identity(for: directory) ?? "directory:\(directory.path)")
        })
        titleByDirectory = Dictionary(uniqueKeysWithValues: directories.map { directory in
            (directory, nameResolver.title(for: directory))
        })
    }

    func groups(for candidates: [ScanCandidate], groupIDPrefix: String? = nil) -> [CandidateGroup] {
        let grouped = Dictionary(grouping: candidates) { candidate in
            groupingDirectoryByCandidateID[candidate.id] ?? CandidateGrouping.groupingDirectory(for: candidate)
        }
        return CandidateGrouping.groups(
            for: grouped,
            groupIDPrefix: groupIDPrefix,
            nameResolver: nameResolver,
            identityByDirectory: identityByDirectory,
            titleByDirectory: titleByDirectory
        )
    }
}

struct CandidateApplicationNameResolver: Sendable {
    private struct InstalledApplication {
        let bundleIdentifier: String
        let fileName: String
        let displayName: String?
        let bundleName: String?
        let normalizedNames: Set<String>
        let normalizedBundleParts: Set<String>
    }

    private let applicationsByName: [String: InstalledApplication]
    private let applicationsByBundlePart: [String: InstalledApplication]
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
        let applications = Self.loadApplications(from: roots)
        applicationsByName = Self.index(applications, key: { $0.normalizedNames })
        applicationsByBundlePart = Self.index(applications, key: { $0.normalizedBundleParts })
    }

    func title(for directory: URL) -> String {
        let fallback = directory.lastPathComponent
        if let bundleIdentifier = mapping.bundleIdentifier(matching: fallback),
           let mappedName = mapping.name(for: bundleIdentifier) {
            return mappedName
        }
        guard let application = application(matching: fallback) else { return fallback }
        if let mappedName = mapping.name(for: application.bundleIdentifier) {
            return mappedName
        }
        return application.displayName ?? application.bundleName ?? application.fileName
    }

    func identity(for directory: URL) -> String? {
        if let bundleIdentifier = mapping.bundleIdentifier(matching: directory.lastPathComponent) {
            return bundleIdentifier.lowercased()
        }
        return application(matching: directory.lastPathComponent)?.bundleIdentifier.lowercased()
    }

    private func application(matching directoryName: String) -> InstalledApplication? {
        let normalized = Self.normalized(directoryName)
        if let bundleIdentifier = mapping.bundleIdentifier(matching: directoryName),
           Self.normalized(bundleIdentifier) == normalized {
            return applicationsByName[normalized]
        }
        return applicationsByName[normalized] ?? applicationsByBundlePart[normalized]
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
                let fileName = url.deletingPathExtension().lastPathComponent
                let displayName = ApplicationMetadata.displayName(at: url, info: info)
                let bundleName = info["CFBundleName"] as? String
                let application = InstalledApplication(
                    bundleIdentifier: bundleIdentifier,
                    fileName: fileName,
                    displayName: displayName,
                    bundleName: bundleName,
                    normalizedNames: Set([
                        bundleIdentifier,
                        fileName,
                        displayName,
                        bundleName
                    ].compactMap { $0 }.map(Self.normalized)),
                    normalizedBundleParts: Set(bundleIdentifier.split(separator: ".")
                        .map { Self.normalized(String($0)) }
                        .filter { !["com", "org", "net", "app", "mac", "desktop"].contains($0) })
                )
                applications[bundleIdentifier.lowercased()] = application
            }
        }
        return Array(applications.values)
    }

    private static func index(
        _ applications: [InstalledApplication],
        key: (InstalledApplication) -> Set<String>
    ) -> [String: InstalledApplication] {
        var result: [String: InstalledApplication] = [:]
        for application in applications {
            for value in key(application) {
                result[value] = result[value] ?? application
            }
        }
        return result
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
