import Foundation

public struct ScanScope: Sendable {
    public let root: URL
    public let ruleIDs: Set<String>?

    let pruneResidualDirectories: Bool

    public init(root: URL, ruleIDs: Set<String>? = nil) {
        self.init(root: root, ruleIDs: ruleIDs, pruneResidualDirectories: false)
    }

    init(root: URL, ruleIDs: Set<String>?, pruneResidualDirectories: Bool) {
        self.root = root
        self.ruleIDs = ruleIDs
        self.pruneResidualDirectories = pruneResidualDirectories
    }
}

public struct ScanOptions: Sendable {
    public let roots: [URL]
    public let scopes: [ScanScope]

    public init(roots: [URL]) {
        self.init(scopes: roots.map { ScanScope(root: $0) })
    }

    public init(scopes: [ScanScope]) {
        self.roots = scopes.map(\.root)
        self.scopes = scopes
    }

    public static func smartCleanup(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ScanOptions {
        let canonicalHome = home.resolvingSymlinksInPath().standardizedFileURL
        let discovery = ResidualDiscovery(home: canonicalHome)
        var scopes: [ScanScope] = []
        var seenRoots = Set<String>()

        func add(_ root: URL, ruleIDs: Set<String>, pruneResidualDirectories: Bool = false) {
            let standardized = root.standardizedFileURL
            guard standardized.path == root.resolvingSymlinksInPath().path,
                  (try? standardized.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  seenRoots.insert(standardized.path).inserted else { return }
            scopes.append(ScanScope(root: standardized, ruleIDs: ruleIDs, pruneResidualDirectories: pruneResidualDirectories))
        }

        add(canonicalHome.appendingPathComponent(".Trash", isDirectory: true), ruleIDs: ["system.trash"])
        add(canonicalHome.appendingPathComponent("Library/Caches", isDirectory: true), ruleIDs: [
            "browser.cookies", "browser.web-cache", "user.caches", "developer.package-caches", "app.orphan"
        ])
        add(canonicalHome.appendingPathComponent("Library/Logs", isDirectory: true), ruleIDs: ["crash.reports", "user.logs", "app.orphan"])
        add(canonicalHome.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true), ruleIDs: ["developer.build-artifacts"])
        add(canonicalHome.appendingPathComponent("Library/Application Support", isDirectory: true), ruleIDs: ["app.orphan"], pruneResidualDirectories: true)
        add(canonicalHome.appendingPathComponent("Library/Preferences", isDirectory: true), ruleIDs: ["app.orphan"])
        add(canonicalHome.appendingPathComponent("Library/Cookies", isDirectory: true), ruleIDs: ["browser.cookies", "app.orphan"])
        add(canonicalHome.appendingPathComponent("Library/HTTPStorages", isDirectory: true), ruleIDs: ["browser.cookies", "app.orphan"])
        add(canonicalHome.appendingPathComponent("Library/WebKit", isDirectory: true), ruleIDs: ["browser.cookies", "browser.web-cache", "app.orphan"])
        add(canonicalHome.appendingPathComponent("Library/pnpm/store", isDirectory: true), ruleIDs: ["developer.package-caches"])

        for source in HomeLogSource.all + discovery.homeLogs {
            add(source.root(in: canonicalHome), ruleIDs: ["user.logs", "app.orphan"])
        }

        let developerCacheRoots = [
            canonicalHome.appendingPathComponent(".npm/_cacache", isDirectory: true),
            canonicalHome.appendingPathComponent(".npm/_npx", isDirectory: true),
            canonicalHome.appendingPathComponent(".npm/_prebuilds", isDirectory: true),
            canonicalHome.appendingPathComponent(".npm/_logs", isDirectory: true),
            canonicalHome.appendingPathComponent(".gradle/caches", isDirectory: true),
            canonicalHome.appendingPathComponent(".gradle/wrapper/dists", isDirectory: true),
            canonicalHome.appendingPathComponent(".gradle/daemon", isDirectory: true),
            canonicalHome.appendingPathComponent(".gradle/native", isDirectory: true),
            canonicalHome.appendingPathComponent(".gradle/.tmp", isDirectory: true),
            canonicalHome.appendingPathComponent(".m2/repository", isDirectory: true),
            canonicalHome.appendingPathComponent(".bun/install/cache", isDirectory: true),
            canonicalHome.appendingPathComponent(".nvm/.cache", isDirectory: true),
            canonicalHome.appendingPathComponent(".cache/pip", isDirectory: true),
            canonicalHome.appendingPathComponent(".cache/uv", isDirectory: true),
            canonicalHome.appendingPathComponent(".cache/ruby-install", isDirectory: true),
            canonicalHome.appendingPathComponent(".local/share/uv/cache", isDirectory: true),
            canonicalHome.appendingPathComponent(".gem/specs", isDirectory: true)
        ]
        for root in developerCacheRoots {
            add(root, ruleIDs: ["developer.package-caches"])
        }
        return ScanOptions(scopes: scopes)
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
        let canonicalHome = home.resolvingSymlinksInPath().standardizedFileURL
        self.home = canonicalHome
        rules = catalog.rules.map { PreparedCleanupRule(rule: $0, homeDirectory: canonicalHome) }
        includesOrphans = catalog.rules.contains { $0.id == "app.orphan" }
        history = uninstallHistory
        installed = isInstalled ?? { OrphanApplicationScanner.isInstalled($0) }
    }

    public func scan(_ options: ScanOptions) -> ScanReport {
        let started = Date()
        let discovery = ResidualDiscovery(home: home)
        let orphans = OrphanApplicationScanner(home: home, history: includesOrphans ? history ?? UninstallHistory.identifiers : [], installed: installed, discovery: discovery)
        let scopes = options.scopes.map { ScanScope(root: $0.root.standardizedFileURL, ruleIDs: $0.ruleIDs, pruneResidualDirectories: $0.pruneResidualDirectories) }
        let store = ScanResultStore(count: scopes.count)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = min(3, max(1, scopes.count))

        for (index, scope) in scopes.enumerated() {
            queue.addOperation {
                store.store(Self.scan(scope: scope, rules: self.rules, orphans: orphans), at: index)
            }
        }
        queue.waitUntilAllOperationsAreFinished()

        let results = store.results()
        let candidates = results.flatMap(\.candidates)
        let skipped = results.flatMap(\.skipped)
        return ScanReport(startedAt: started, finishedAt: Date(), candidates: candidates, skippedPaths: skipped)
    }

    private struct ScopeScanResult: Sendable {
        var candidates: [ScanCandidate] = []
        var skipped: [String] = []
    }

    private final class ScanResultStore: @unchecked Sendable {
        private var values: [ScopeScanResult]
        private let lock = NSLock()

        init(count: Int) {
            values = Array(repeating: ScopeScanResult(), count: count)
        }

        func store(_ result: ScopeScanResult, at index: Int) {
            lock.lock()
            values[index] = result
            lock.unlock()
        }

        func results() -> [ScopeScanResult] {
            lock.lock()
            let snapshot = values
            lock.unlock()
            return snapshot
        }
    }

    private static func scan(scope: ScanScope, rules: [PreparedCleanupRule], orphans: OrphanApplicationScanner) -> ScopeScanResult {
        var result = ScopeScanResult()
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let scopedRules = scope.ruleIDs.map { ids in rules.filter { ids.contains($0.rule.id) } } ?? rules
        let orphanRule = scopedRules.first { $0.rule.id == "app.orphan" }?.rule
        let root = scope.root.standardizedFileURL

        if root.lastPathComponent == ".Trash", (try? manager.contentsOfDirectory(atPath: root.path)) == nil {
            result.skipped.append(root.path)
            return result
        }
        guard let entries = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsPackageDescendants], errorHandler: { url, _ in
            result.skipped.append(url.path)
            return true
        }) else {
            result.skipped.append(root.path)
            return result
        }

        for case let url as URL in entries {
            do {
                let values = try url.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true {
                    entries.skipDescendants()
                    result.skipped.append(url.path)
                    continue
                }
                let name = url.lastPathComponent.lowercased()
                if root.lastPathComponent != ".Trash", Self.protectedNames.contains(name), !(name == "cookies" && values.isDirectory == true) {
                    if values.isDirectory == true { entries.skipDescendants() }
                    continue
                }
                if values.isDirectory == true && scope.pruneResidualDirectories && !orphans.shouldTraverseDirectory(url) {
                    entries.skipDescendants()
                    continue
                }
                guard values.isRegularFile == true else { continue }
                let path = url.path
                let owner = orphanRule == nil ? nil : orphans.owner(of: path)
                let rule: CleanupRule?
                if owner != nil {
                    guard orphans.permits(url) else { continue }
                    rule = orphanRule
                } else {
                    rule = scopedRules.first { $0.matches(path: path) }?.rule
                }
                guard let rule else { continue }
                guard let bytes = values.fileSize else { result.skipped.append(path); continue }
                let stamp = owner == nil ? nil : ResidualFileStamp(url)
                if owner != nil && stamp == nil { continue }
                let evidence = owner.map { ["私有目录和独立偏好文件均匹配 \($0)，当前检查范围内未找到安装副本。"] } ?? ["规则：\(rule.name)"]
                result.candidates.append(ScanCandidate(url: url, size: Int64(bytes), ruleID: rule.id, risk: rule.risk, explanation: rule.explanation, evidence: evidence, residualStamp: stamp, residualOwner: owner))
            } catch { result.skipped.append(url.path) }
        }
        return result
    }

    private static let protectedNames: Set<String> = ["node_modules", "sourcepackages", "indexeddb", "localstorage", "local storage", "serviceworkers", "service worker", "databases", "websitedata", "cookies", "cookies-journal", "cookies-wal", "cookies-shm", "login data", "web data", "login data-journal", "web data-journal", "login data-wal", "web data-wal", "login data-shm", "web data-shm"]
}
