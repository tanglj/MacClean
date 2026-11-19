import Foundation
import Testing
@testable import MacCleanCore

@Test func bothScannersContinueBeyondPreviousFileLimits() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("MacClean-Unlimited-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    // Empty files exercise traversal past both previous limits without a large
    // disk allocation. Duplicate scanning explicitly includes empty files here.
    let count = 100_001
    for index in 0..<count {
        try Data().write(to: root.appendingPathComponent("\(index).tmp"))
    }
    let pattern = root.resolvingSymlinksInPath().path + "/**"
    let rule = CleanupRule(id: "test.unlimited", name: "完整遍历测试", pathPatterns: [pattern], risk: .safeRebuildable, explanation: "测试目录")
    let cleanup = Scanner(catalog: RuleCatalog(rules: [rule])).scan(ScanOptions(roots: [root]))
    #expect(cleanup.candidates.count == count)
    #expect(cleanup.skippedPaths.isEmpty)

    let duplicates = DuplicateScanner().scan(DuplicateScanOptions(roots: [root], minimumFileSize: 0))
    #expect(duplicates.scannedFileCount == count)
    #expect(duplicates.groups.count == 1)
    #expect(duplicates.groups.first?.files.count == count)
    #expect(duplicates.skippedPaths.isEmpty)
}
