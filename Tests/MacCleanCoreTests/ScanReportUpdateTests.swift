import Foundation
import Testing
@testable import MacCleanCore

@Test func deletionUpdatesOnlySuccessfulItemsAndPreservesSnapshot() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClean-ScanReportFixture")
    let files = (1...4).map { index in
        ScanCandidate(url: root.appendingPathComponent("cache/file\(index)"), size: Int64(index * 10), ruleID: "user.caches", risk: .safeRebuildable, explanation: "缓存")
    }
    let report = ScanReport(startedAt: Date(timeIntervalSince1970: 100), finishedAt: Date(timeIntervalSince1970: 200), candidates: files, skippedPaths: ["/unreadable"])
    let updated = report.applyingDeletionResults([
        .deleted(files[0].url), .skipped(files[1].url, "权限不足"), .dryRun(files[2].url)
    ])
    #expect(updated.candidates == Array(files.dropFirst()))
    #expect(updated.startedAt == report.startedAt)
    #expect(updated.finishedAt == report.finishedAt)
    #expect(updated.skippedPaths == report.skippedPaths)
    #expect(CandidateGrouping.groups(for: updated.candidates).reduce(0) { $0 + $1.size } == 90)
    let repeated = updated.applyingDeletionResults([.deleted(files[0].url)])
    #expect(repeated.candidates == updated.candidates)
    #expect(report.applyingDeletionResults([]).candidates == files)
}
