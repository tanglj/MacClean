import Foundation
import Testing
@testable import MacCleanCore

@Test func scannerMatchesRulesAndSkipsSymlink() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = root.appendingPathComponent("Library/Caches/App")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = cache.appendingPathComponent("item.tmp")
    try Data(repeating: 1, count: 8).write(to: file)
    let link = cache.appendingPathComponent("outside")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    let rule = CleanupRule(id: "test", name: "测试", pathPatterns: [root.path + "/Library/Caches/**"], risk: .safeRebuildable, explanation: "test")
    let report = Scanner(catalog: RuleCatalog(rules: [rule])).scan(ScanOptions(roots: [root]))
    let canonical = { (path: String) in path.hasPrefix("/private/") ? path : path.replacingOccurrences(of: "/var/", with: "/private/var/") }
    #expect(report.candidates.map { canonical($0.url.path) } == [canonical(file.path)])
    #expect(report.skippedPaths.contains(canonical(link.path)))
}
