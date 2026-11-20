import Foundation
import Testing
@testable import MacCleanCore

private struct ResidualFixture {
    let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    let identifier = "com.colliderli.iina"
    var library: URL { home.appendingPathComponent("Library") }

    @discardableResult func file(_ path: String) throws -> URL {
        let url = library.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    func scan(installed: Bool = false) -> [ScanCandidate] {
        Scanner(home: home, uninstallHistory: [], isInstalled: { _ in installed }).scan(ScanOptions(roots: [library])).candidates
    }
}

@Test func homeToolLogsAreGroupedSelectableAndRecheckedAtCleanup() async throws {
    let fixture = ResidualFixture()
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    let logs = [".workbuddy/logs/main.log", ".workbuddy-ai/logs/startup/app.log", ".cc-switch/logs/cc-switch.log"]
    let protected = [".workbuddy/logs/trace.jsonl", ".workbuddy/projects/user.log", ".cc-switch/backups/backup.log", ".cc-switch/cc-switch.db", ".codebuddy/logs/tool.log"]
    for path in logs + protected {
        let url = fixture.home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
    }
    let options = ScanOptions.smartCleanup(home: fixture.home)
    let scanner = Scanner(home: fixture.home, uninstallHistory: [], isInstalled: { _ in false })
    #expect(scanner.scan(options).candidates.isEmpty)
    try fixture.file("Preferences/com.workbuddy.workbuddy.plist")
    try fixture.file("Preferences/com.ccswitch.desktop.plist")
    let candidates = scanner.scan(options).candidates
    #expect(Set(candidates.map { $0.url.standardizedFileURL.path }) == Set(logs.map { fixture.home.appendingPathComponent($0).standardizedFileURL.path }))
    #expect(candidates.allSatisfy { !$0.selectedByDefault && $0.ruleID == "app.orphan" })
    let presentation = ScanPresentation(candidates: candidates)
    let groups = presentation.results(risk: nil).uninstalled
    #expect(Dictionary(uniqueKeysWithValues: groups.map { ($0.title, $0.candidates.count) }) == ["疑似残留 · WorkBuddy": 2, "疑似残留 · CC Switch": 1])
    var selection = ScanSelection()
    selection.set(candidates, selected: true, in: presentation)
    #expect(selection.ids == Set(candidates.map(\.id)))
    let engine = DeletionEngine(pathGuard: PathGuard(allowedRoots: options.roots), auditLog: AuditLog(fileURL: fixture.home.appendingPathComponent("audit")), residualHome: fixture.home, installed: { _ in false })
    let results = await engine.execute(candidates.map { DeletionRequest(candidate: $0, confirmed: true) }, dryRun: true)
    #expect(results == candidates.map { .dryRun($0.url.standardizedFileURL) })
    let reinstalled = Scanner(home: fixture.home, uninstallHistory: [], isInstalled: { $0 == "com.tencent.workbuddy.mac" })
    #expect(reinstalled.scan(options).candidates.map { $0.url.lastPathComponent } == ["cc-switch.log"])
}

@Test func uncataloguedApplicationsAreDiscoveredAcrossLocationsAndRechecked() async throws {
    let fixture = ResidualFixture()
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    let product = "quartz" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let identifier = "org.example." + product
    try fixture.file("Preferences/\(identifier).plist")
    try fixture.file("Application Support/\(product)/logs/previous.log")
    try fixture.file("Application Support/\(product)/GPUCache/data_0")
    try fixture.file("Application Support/\(product)/User/content.db")
    try fixture.file("Application Support/\(product)/GPUCache/personal.txt")
    try fixture.file("Logs/\(identifier)/session.log")
    let hiddenLog = fixture.home.appendingPathComponent(".\(product)/logs/session/previous.log")
    try FileManager.default.createDirectory(at: hiddenLog.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([1]).write(to: hiddenLog)
    let options = ScanOptions.smartCleanup(home: fixture.home)
    let scanner = Scanner(home: fixture.home, uninstallHistory: [], isInstalled: { _ in false })
    let found = scanner.scan(options).candidates
    #expect(found.count == 4)
    #expect(found.allSatisfy { $0.residualOwner == identifier && !$0.selectedByDefault })
    #expect(ScanPresentation(candidates: found).results(risk: nil).uninstalled.count == 1)
    let engine = DeletionEngine(pathGuard: PathGuard(allowedRoots: options.roots), auditLog: AuditLog(fileURL: fixture.home.appendingPathComponent("audit")), residualHome: fixture.home, installed: { _ in false })
    let requests = found.map { DeletionRequest(candidate: $0, confirmed: true) }
    #expect(await engine.execute(requests, dryRun: true) == found.map { .dryRun($0.url.standardizedFileURL) })
    let reinstalled = Scanner(home: fixture.home, uninstallHistory: [], isInstalled: { $0 == identifier })
    #expect(reinstalled.scan(options).candidates.allSatisfy { $0.ruleID != "app.orphan" })
    try fixture.file("Preferences/net.other.\(product).plist")
    #expect(scanner.scan(options).candidates.allSatisfy { $0.ruleID != "app.orphan" })
    let results = await engine.execute(requests, dryRun: true)
    #expect(results.allSatisfy { if case .skipped = $0 { return true }; return false })
}

@Test func externalUninstallNeedsTwoExactTracesAndOnlyExposesDisposableFiles() throws {
    let fixture = ResidualFixture()
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    let identifier = fixture.identifier
    let cache = try fixture.file("Caches/\(identifier)/thumbnail.cache")
    let log = try fixture.file("Logs/\(identifier)/activity.log")
    #expect(fixture.scan().allSatisfy { $0.ruleID != "app.orphan" })
    try fixture.file("Preferences/\(identifier).plist")
    for item in ["Application Support/\(identifier)/private.db", "Group Containers/TEAM.\(identifier)/data", "Containers/cn.wps.wpslaunchhelper/data", "Group Containers/5A4RE8SF68.com.tencent.xinWeChat/data", "Caches/\(identifier)/profile.db", "Caches/\(identifier)/nested/document.tmp", "Preferences/helper-tests.plist"] {
        try fixture.file(item)
    }
    let linked = try fixture.file("Caches/\(identifier)/linked.cache")
    try FileManager.default.linkItem(at: linked, to: fixture.home.appendingPathComponent("other"))
    let result = fixture.scan()
    #expect(Set(result.map { $0.url.standardizedFileURL.path }) == Set([cache, log].map { $0.standardizedFileURL.path }))
    #expect(result.allSatisfy { $0.ruleID == "app.orphan" && !$0.selectedByDefault && $0.residualStamp != nil })
    #expect(fixture.scan(installed: true).allSatisfy { $0.ruleID != "app.orphan" })
}

@Test func reinstallationReplacedFileAndLostEvidenceBlockResidualCleanup() async throws {
    let fixture = ResidualFixture()
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    let preference = try fixture.file("Preferences/\(fixture.identifier).plist")
    let file = try fixture.file("Logs/\(fixture.identifier)/activity.log")
    let candidate = try #require(fixture.scan().first { $0.ruleID == "app.orphan" })
    let request = DeletionRequest(candidate: candidate, confirmed: true)
    func check(installed: Bool, dryRun: Bool) async -> DeletionResult? {
        let engine = DeletionEngine(pathGuard: PathGuard(allowedRoots: [fixture.library]), auditLog: AuditLog(fileURL: fixture.home.appendingPathComponent("audit")), residualHome: fixture.home, installed: { _ in installed })
        return await engine.execute([request], dryRun: dryRun).first
    }
    #expect(await check(installed: false, dryRun: true) == .dryRun(file.standardizedFileURL))
    guard case .skipped = await check(installed: true, dryRun: false) else { Issue.record("重装后仍可清理"); return }
    try FileManager.default.removeItem(at: preference)
    guard case .skipped = await check(installed: false, dryRun: false) else { Issue.record("缺少归属证据仍可清理"); return }
    try fixture.file("Preferences/\(fixture.identifier).plist")
    try Data([4, 5, 6]).write(to: file, options: .atomic)
    guard case .skipped = await check(installed: false, dryRun: false) else { Issue.record("替换文件仍可清理"); return }
    #expect(try Data(contentsOf: file) == Data([4, 5, 6]))
}

@Test func observedCursorCachesAndAudacityLogPassScanAndCleanupRecheck() async throws {
    let fixture = ResidualFixture()
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    let paths = ["Cursor/GPUCache/data_0", "Cursor/DawnGraphiteCache/index", "Cursor/DawnWebGPUCache/f_000001", "Cursor/Cache/Cache_Data/793830f83868eeda_0", "Cursor/Cache/Cache_Data/index-dir/the-real-index", "Cursor/Code Cache/js/index", "audacity/lastlog.txt"]
    let protected = ["Cursor/GPUCache/project.db", "Cursor/User/settings.json", "Cursor/DawnGraphiteCache/nested/data_0", "audacity/audacity.cfg", "sqlitebrowser/DB Browser for SQLite/remotedbs.db", "Vivaldi/NativeMessagingHosts/com.openai.codexextension.json"]
    for path in paths + protected { try fixture.file("Application Support/" + path) }
    #expect(fixture.scan().isEmpty)
    for name in ["com.todesktop.230313mzl4w4u92", "org.audacityteam.audacity"] { try fixture.file("Preferences/" + name + ".plist") }
    let found = fixture.scan()
    let expected = Set(paths.map { fixture.library.appendingPathComponent("Application Support/" + $0).standardizedFileURL.path })
    #expect(Set(found.map { $0.url.standardizedFileURL.path }) == expected)
    #expect(found.allSatisfy { $0.ruleID == "app.orphan" && !$0.selectedByDefault })
    let engine = DeletionEngine(pathGuard: PathGuard(allowedRoots: [fixture.library]), auditLog: AuditLog(fileURL: fixture.home.appendingPathComponent("audit")), residualHome: fixture.home, installed: { _ in false })
    let results = await engine.execute(found.map { DeletionRequest(candidate: $0, confirmed: true) }, dryRun: true)
    #expect(results == found.map { .dryRun($0.url.standardizedFileURL) })
    #expect(fixture.scan(installed: true).isEmpty)
}
