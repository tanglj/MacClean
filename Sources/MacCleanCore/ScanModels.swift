import Foundation

public struct ScanCandidate: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let url: URL
    public let size: Int64
    public let ruleID: String
    public let risk: RiskLevel
    public let explanation: String
    public let evidence: [String]
    public let selectedByDefault: Bool
    public let residualStamp: ResidualFileStamp?
    public let residualOwner: String?

    public init(id: UUID = UUID(), url: URL, size: Int64, ruleID: String, risk: RiskLevel, explanation: String, evidence: [String] = [], selectedByDefault: Bool? = nil, residualStamp: ResidualFileStamp? = nil, residualOwner: String? = nil) {
        self.id = id
        self.residualStamp = residualStamp
        self.residualOwner = residualOwner
        self.url = url
        self.size = size
        self.ruleID = ruleID
        self.risk = risk
        self.explanation = explanation
        self.evidence = evidence
        self.selectedByDefault = selectedByDefault ?? !risk.requiresExplicitSelection
    }
}

public struct ScanReport: Codable, Sendable {
    public let startedAt: Date
    public let finishedAt: Date
    public let candidates: [ScanCandidate]
    public let skippedPaths: [String]

    public init(startedAt: Date, finishedAt: Date, candidates: [ScanCandidate], skippedPaths: [String] = []) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.candidates = candidates
        self.skippedPaths = skippedPaths
    }
}

public extension ScanReport {
    /// Keep the original scan snapshot and identities; only successful deletions leave the list.
    func applyingDeletionResults(_ results: [DeletionResult]) -> ScanReport {
        let deletedPaths = Set(results.compactMap { result -> String? in
            if case let .deleted(url) = result { return url.standardizedFileURL.path }
            return nil
        })
        return ScanReport(
            startedAt: startedAt,
            finishedAt: finishedAt,
            candidates: candidates.filter { !deletedPaths.contains($0.url.standardizedFileURL.path) },
            skippedPaths: skippedPaths
        )
    }
}
