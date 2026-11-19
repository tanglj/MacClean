import Foundation
import Testing
@testable import MacCleanCore

@Test func dryRunNeverDeletesAndWritesAuditEvent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("cache.bin")
    try Data(repeating: 1, count: 4).write(to: file)
    let audit = root.appendingPathComponent("audit/events.ndjson")
    let candidate = ScanCandidate(url: file, size: 4, ruleID: "test.cache", risk: .safeRebuildable, explanation: "test")
    let engine = DeletionEngine(pathGuard: PathGuard(allowedRoots: [root]), auditLog: AuditLog(fileURL: audit))
    let results = await engine.execute([DeletionRequest(candidate: candidate, confirmed: true)], dryRun: true)
    #expect(results == [.dryRun(file.standardizedFileURL)])
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(FileManager.default.fileExists(atPath: audit.path))
}

@Test func unconfirmedRequestIsSkipped() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("cache.bin")
    try Data("x".utf8).write(to: file)
    let candidate = ScanCandidate(url: file, size: 1, ruleID: "test.cache", risk: .safeRebuildable, explanation: "test")
    let engine = DeletionEngine(pathGuard: PathGuard(allowedRoots: [root]), auditLog: AuditLog(fileURL: root.appendingPathComponent("audit.ndjson")))
    let result = await engine.execute([DeletionRequest(candidate: candidate, confirmed: false)])
    #expect(result == [.skipped(file.standardizedFileURL, "未确认")])
    #expect(FileManager.default.fileExists(atPath: file.path))
}
