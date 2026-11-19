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

    public init(candidates: [ScanCandidate]) {
        self.candidates = candidates
        groups = CandidateGrouping.groups(for: candidates)
        riskCandidates = Dictionary(grouping: candidates, by: \.risk)
        riskCounts = riskCandidates.mapValues(\.count)
        riskGroups = riskCandidates.mapValues { CandidateGrouping.groups(for: $0) }
        candidatesByID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var paths: [UUID: [String]] = [:]
        for group in groups {
            for candidate in group.candidates {
                var directory = candidate.url.deletingLastPathComponent()
                var ancestors: [String] = []
                while directory.pathComponents.count >= group.directory.pathComponents.count {
                    ancestors.append(directory.path)
                    if directory.path == group.id { break }
                    let parent = directory.deletingLastPathComponent()
                    if parent == directory { break }
                    directory = parent
                }
                paths[candidate.id] = ancestors
            }
        }
        directoryPathsByCandidateID = paths
        groupByCandidateID = Dictionary(groups.flatMap { group in group.candidates.map { ($0.id, group.id) } }, uniquingKeysWith: { first, _ in first })
    }

    public func candidates(risk: RiskLevel?) -> [ScanCandidate] {
        risk.map { riskCandidates[$0] ?? [] } ?? candidates
    }

    public func groups(risk: RiskLevel?) -> [CandidateGroup] {
        risk.map { riskGroups[$0] ?? [] } ?? groups
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
