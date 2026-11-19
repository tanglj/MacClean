import Foundation

public struct ScanOptions: Sendable {
    public let roots: [URL]

    public init(roots: [URL]) {
        self.roots = roots
    }
}

public struct Scanner: Sendable {
    private let rules: [PreparedCleanupRule]

    public init(catalog: RuleCatalog = RuleCatalog()) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        rules = catalog.rules.map { PreparedCleanupRule(rule: $0, homeDirectory: home) }
    }

    public func scan(_ options: ScanOptions) -> ScanReport {
        let started = Date()
        var candidates: [ScanCandidate] = []
        var skipped: [String] = []
        let fm = FileManager.default

        for root in options.roots.map(\.standardizedFileURL) {
            guard fm.fileExists(atPath: root.path) else {
                skipped.append(root.path)
                continue
            }
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey], options: [.skipsPackageDescendants]) else {
                skipped.append(root.path)
                continue
            }
            for case let url as URL in enumerator {
                do {
                    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
                    if values.isSymbolicLink == true { enumerator.skipDescendants(); skipped.append(url.path); continue }
                    guard values.isRegularFile == true else { continue }
                    let path = url.standardizedFileURL.path
                    guard let rule = rules.first(where: { $0.matches(path: path) })?.rule else { continue }
                    let size = Int64(values.fileSize ?? 0)
                    candidates.append(ScanCandidate(url: url, size: size, ruleID: rule.id, risk: rule.risk, explanation: rule.explanation, evidence: ["规则：\(rule.name)"]))
                } catch {
                    skipped.append(url.path)
                }
            }
        }
        return ScanReport(startedAt: started, finishedAt: Date(), candidates: candidates, skippedPaths: skipped)
    }
}
