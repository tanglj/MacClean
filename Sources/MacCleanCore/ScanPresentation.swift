import Foundation

/// Built off the main thread when a scan changes, never during selection rendering.
public struct ScanPresentation: Sendable {
    public let candidates: [ScanCandidate]
    public let groups: [CandidateGroup]
    public let riskCounts: [RiskLevel: Int]
    public let candidatesByID: [UUID: ScanCandidate]
    public let directoryPathsByCandidateID: [UUID: [String]]
    public let groupByCandidateID: [UUID: String]
    private let riskCandidates: [RiskLevel: [ScanCandidate]]
    private let riskGroups: [RiskLevel: [CandidateGroup]]
    private let groupedResults: GroupedResults
    private let riskGroupedResults: [RiskLevel: GroupedResults]

    public struct CleanupTypeGroup: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let icon: String
        public let explanation: String
        public let groups: [CandidateGroup]
        public let isUnavailable: Bool

        public var isExpandable: Bool { id != "system.trash" }
        public var candidates: [ScanCandidate] { groups.flatMap(\.candidates) }
        public var size: Int64 { candidates.reduce(0) { $0 + $1.size } }
    }

    public struct GroupedResults: Sendable {
        public let categories: [CleanupTypeGroup]

        public var regular: [CandidateGroup] {
            categories.filter { $0.id != "app.orphan" }.flatMap(\.groups)
        }

        public var uninstalled: [CandidateGroup] {
            categories.first(where: { $0.id == "app.orphan" })?.groups ?? []
        }

        fileprivate init(candidates: [ScanCandidate] = [], skippedPaths: [String] = []) {
            let grouped = Dictionary(grouping: candidates, by: \.ruleID)
            var categories: [CleanupTypeGroup] = []
            var knownIDs = Set<String>()
            let trashPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true).standardizedFileURL.path
            let trashUnavailable = skippedPaths.contains { $0 == trashPath || $0.hasPrefix(trashPath + "/") }

            for rule in RuleCatalog.builtInRules {
                guard let candidates = grouped[rule.id], !candidates.isEmpty else {
                    if rule.id == "system.trash" {
                        categories.append(CleanupTypeGroup(
                            id: rule.id,
                            title: rule.name,
                            icon: Self.icon(for: rule.id),
                            explanation: trashUnavailable
                                ? "无法访问废纸篓，请在系统设置的隐私与安全性 → 完全磁盘访问权限中允许 Mac Clean。"
                                : "当前没有发现可清理的废纸篓项目。",
                            groups: [],
                            isUnavailable: trashUnavailable
                        ))
                    }
                    continue
                }
                knownIDs.insert(rule.id)
                categories.append(CleanupTypeGroup(
                    id: rule.id,
                    title: rule.name,
                    icon: Self.icon(for: rule.id),
                    explanation: rule.explanation,
                    groups: CandidateGrouping.groups(for: candidates, groupIDPrefix: "type:\(rule.id)"),
                    isUnavailable: false
                ))
            }

            for ruleID in grouped.keys.filter({ !knownIDs.contains($0) }).sorted() {
                guard let candidates = grouped[ruleID] else { continue }
                categories.append(CleanupTypeGroup(
                    id: ruleID,
                    title: ruleID,
                    icon: "folder",
                    explanation: "按扫描规则归类的项目。",
                    groups: CandidateGrouping.groups(for: candidates, groupIDPrefix: "type:\(ruleID)"),
                    isUnavailable: false
                ))
            }
            self.categories = categories
        }

        private static func icon(for ruleID: String) -> String {
            switch ruleID {
            case "system.trash": return "trash"
            case "browser.cookies": return "circle.grid.2x2"
            case "browser.web-cache": return "globe"
            case "crash.reports", "user.logs": return "doc.text"
            case "user.caches": return "clock.arrow.circlepath"
            case "developer.build-artifacts": return "hammer"
            case "app.orphan": return "archivebox"
            default: return "folder"
            }
        }
    }

    public init(candidates: [ScanCandidate], skippedPaths: [String] = []) {
        self.candidates = candidates
        groups = CandidateGrouping.groups(for: candidates)
        riskCandidates = Dictionary(grouping: candidates, by: \.risk)
        riskCounts = riskCandidates.mapValues(\.count)
        riskGroups = riskCandidates.mapValues { CandidateGrouping.groups(for: $0) }
        groupedResults = GroupedResults(candidates: candidates, skippedPaths: skippedPaths)
        riskGroupedResults = riskCandidates.mapValues { GroupedResults(candidates: $0) }
        candidatesByID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var paths: [UUID: [String]] = [:]
        for group in groups {
            for candidate in group.candidates {
                paths[candidate.id, default: []].append(contentsOf: Self.ancestors(for: candidate, group: group))
            }
        }
        for category in groupedResults.categories {
            for group in category.groups {
                for candidate in group.candidates {
                    paths[candidate.id, default: []].append(category.id)
                    paths[candidate.id, default: []].append(contentsOf: Self.ancestors(for: candidate, group: group))
                }
            }
        }
        directoryPathsByCandidateID = paths.mapValues { values in
            var seen = Set<String>()
            return values.filter { seen.insert($0).inserted }
        }
        groupByCandidateID = Dictionary(groups.flatMap { group in group.candidates.map { ($0.id, group.id) } }, uniquingKeysWith: { first, _ in first })
    }

    private static func ancestors(for candidate: ScanCandidate, group: CandidateGroup) -> [String] {
        var ancestors = [group.id]
        var directory = candidate.url == group.directory
            ? candidate.url
            : candidate.url.deletingLastPathComponent()
        while directory.pathComponents.count >= group.directory.pathComponents.count {
            ancestors.append(directory.path)
            if directory.path == group.directory.path { break }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        return ancestors
    }

    public func candidates(risk: RiskLevel?) -> [ScanCandidate] {
        risk.map { riskCandidates[$0] ?? [] } ?? candidates
    }

    public func groups(risk: RiskLevel?) -> [CandidateGroup] {
        risk.map { riskGroups[$0] ?? [] } ?? groups
    }

    public func results(risk: RiskLevel?) -> GroupedResults {
        risk.map { riskGroupedResults[$0] ?? GroupedResults() } ?? groupedResults
    }
}

public struct ScanSelection: Sendable {
    public private(set) var ids: Set<UUID> = []
    public private(set) var size: Int64 = 0
    public private(set) var groupCounts: [String: Int] = [:]
    public private(set) var riskSizes: [RiskLevel: Int64] = [:]
    private var riskGroupCounts: [RiskLevel: [String: Int]] = [:]

    public init() {}

    public mutating func set(_ candidates: [ScanCandidate], selected: Bool, in presentation: ScanPresentation) {
        for candidate in candidates {
            let changed = selected ? ids.insert(candidate.id).inserted : ids.remove(candidate.id) != nil
            guard changed else { continue }
            let delta = selected ? 1 : -1
            size += Int64(delta) * candidate.size
            riskSizes[candidate.risk, default: 0] += Int64(delta) * candidate.size
            for directory in presentation.directoryPathsByCandidateID[candidate.id] ?? [] {
                groupCounts[directory, default: 0] += delta
                riskGroupCounts[candidate.risk, default: [:]][directory, default: 0] += delta
            }
        }
    }

    public func count(groupID: String, risk: RiskLevel?) -> Int {
        if let risk { return riskGroupCounts[risk]?[groupID] ?? 0 }
        return groupCounts[groupID] ?? 0
    }
}
