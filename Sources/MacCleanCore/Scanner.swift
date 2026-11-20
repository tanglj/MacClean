import Foundation

public struct ScanOptions: Sendable {
    public let roots: [URL]

    public init(roots: [URL]) { self.roots = roots }

    public static func smartCleanup(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ScanOptions {
        let sources = HomeLogSource.all + ResidualDiscovery(home: home).homeLogs
        let logRoots = sources.map { $0.root(in: home) }.filter { root in
            guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().path else { return false }
            return (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        return ScanOptions(roots: [home.appendingPathComponent("Library"), home.appendingPathComponent(".Trash")] + logRoots)
    }
}

public struct Scanner: Sendable {
    private let rules: [PreparedCleanupRule]
    private let home: URL
    private let includesOrphans: Bool
    private let history: Set<String>?
    private let installed: @Sendable (String) -> Bool

    public init(catalog: RuleCatalog = RuleCatalog(), home: URL = FileManager.default.homeDirectoryForCurrentUser,
                uninstallHistory: Set<String>? = nil,
                isInstalled: (@Sendable (String) -> Bool)? = nil) {
        self.home = home.standardizedFileURL
        rules = catalog.rules.map { PreparedCleanupRule(rule: $0, homeDirectory: home.standardizedFileURL) }
        includesOrphans = catalog.rules.contains { $0.id == "app.orphan" }
        history = uninstallHistory
        installed = isInstalled ?? { OrphanApplicationScanner.isInstalled($0) }
    }

    public func scan(_ options: ScanOptions) -> ScanReport {
        let started = Date()
        var candidates: [ScanCandidate] = []
        var skipped: [String] = []
        let manager = FileManager.default
        let orphans = OrphanApplicationScanner(home: home, history: includesOrphans ? history ?? UninstallHistory.identifiers : [], installed: installed)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        for root in options.roots.map(\.standardizedFileURL) {
            if root.lastPathComponent == ".Trash", (try? manager.contentsOfDirectory(atPath: root.path)) == nil {
                skipped.append(root.path)
                continue
            }
            guard let entries = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsPackageDescendants], errorHandler: { url, _ in
                skipped.append(url.path)
                return true
            }) else { skipped.append(root.path); continue }
            for case let url as URL in entries {
                do {
                    let values = try url.resourceValues(forKeys: keys)
                    if values.isSymbolicLink == true {
                        entries.skipDescendants()
                        skipped.append(url.path)
                        continue
                    }
                    let name = url.lastPathComponent.lowercased()
                    if root.lastPathComponent != ".Trash", Self.protectedNames.contains(name), !(name == "cookies" && values.isDirectory == true) {
                        if values.isDirectory == true { entries.skipDescendants() }
                        continue
                    }
                    guard values.isRegularFile == true else { continue }
                    let path = url.standardizedFileURL.path
                    let owner = includesOrphans ? orphans.owner(of: path) : nil
                    let rule: CleanupRule?
                    if owner != nil {
                        guard orphans.permits(url.standardizedFileURL) else { continue }
                        rule = rules.first { $0.rule.id == "app.orphan" }?.rule
                    } else {
                        rule = rules.first { $0.matches(path: path) }?.rule
                    }
                    guard let rule else { continue }
                    guard let bytes = values.fileSize else { skipped.append(path); continue }
                    let stamp = owner == nil ? nil : ResidualFileStamp(url.standardizedFileURL)
                    if owner != nil && stamp == nil { continue }
                    let evidence = owner.map { ["私有目录和独立偏好文件均匹配 \($0)，当前检查范围内未找到安装副本。"] } ?? ["规则：\(rule.name)"]
                    candidates.append(ScanCandidate(url: url, size: Int64(bytes), ruleID: rule.id, risk: rule.risk, explanation: rule.explanation, evidence: evidence, residualStamp: stamp, residualOwner: owner))
                } catch { skipped.append(url.path) }
            }
        }
        return ScanReport(startedAt: started, finishedAt: Date(), candidates: candidates, skippedPaths: skipped)
    }

    private static let protectedNames: Set<String> = ["node_modules", "sourcepackages", "indexeddb", "localstorage", "local storage", "serviceworkers", "service worker", "databases", "websitedata", "cookies", "cookies-journal", "cookies-wal", "cookies-shm", "login data", "web data", "login data-journal", "web data-journal", "login data-wal", "web data-wal", "login data-shm", "web data-shm"]
}
