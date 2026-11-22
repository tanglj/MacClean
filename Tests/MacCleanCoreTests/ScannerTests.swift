import Foundation
import Testing
@testable import MacCleanCore

@Test func builtInCleanupUsesOnlyVerifiedLocations() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).standardizedFileURL
    defer { try? FileManager.default.removeItem(at: home) }
    let library = home.appendingPathComponent("Library")
    let expected = ["HTTPStorages/test.binarycookies": "browser.cookies", "Cookies/Cookies.binarycookies": "browser.cookies", "Caches/Google/Chrome/Default/Code Cache/js/item": "browser.web-cache", "Developer/Xcode/DerivedData/Project/Build/test.o": "developer.build-artifacts", "Caches/App/cache": "user.caches", "Logs/App/test.log": "user.logs", "Logs/DiagnosticReports/test.ips": "crash.reports"]
    let excluded = ["Logs/MacClean/operations.ndjson", "HTTPStorages/App/httpstorages.sqlite-wal", "WebKit/App/WebsiteData/Default/IndexedDB/file", "Safari/Databases/site/file", "Caches/Google/Chrome/Default/Login Data", "Caches/com.apple.Safari/LocalStorage/db", "Application Support/Cursor/worker/node_modules/pkg/run", "pnpm/store/links/node_modules/pnpm/bin", "Developer/Xcode/DerivedData/Project/SourcePackages/checkouts/lib/file", "Developer/Xcode/Archives/build.app/file", "Developer/Xcode/UserData/settings"]
    for path in Array(expected.keys) + excluded {
        let file = library.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: file)
    }
    let report = Scanner(home: home, uninstallHistory: []).scan(ScanOptions(roots: [library]))
    let actual = Dictionary(uniqueKeysWithValues: report.candidates.map { (String($0.url.standardizedFileURL.path.dropFirst(library.standardizedFileURL.path.count + 1)), $0.ruleID) })
    #expect(actual == expected)
    #expect(report.candidates.allSatisfy { !$0.selectedByDefault && $0.size == 1 })
}

@Test func smartCleanupIncludesDeveloperCachesWithoutIncludingToolchains() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).standardizedFileURL
    defer { try? FileManager.default.removeItem(at: home) }

    let expected = [
        ".npm/_cacache/content": "developer.package-caches",
        ".npm/_npx/package/index": "developer.package-caches",
        ".gradle/caches/modules-2/files-2.1/dependency.bin": "developer.package-caches",
        ".gradle/wrapper/dists/gradle.zip": "developer.package-caches",
        ".m2/repository/com/example/library.jar": "developer.package-caches",
        "Library/Caches/pnpm/v12/store.json": "developer.package-caches",
        "Library/pnpm/store/v3/files/package.tgz": "developer.package-caches",
        ".cache/pip/http-v2/entry": "developer.package-caches",
        ".cache/uv/archive-v0/entry": "developer.package-caches",
        ".gem/specs/api.4.8.gz": "developer.package-caches"
    ]
    let excluded = [
        ".pyenv/versions/3.12/bin/python",
        ".nvm/versions/node/v20.0.0/bin/node",
        ".rubies/ruby-3.4.1/bin/ruby",
        ".gradle/gradle.properties",
        ".npmrc"
    ]
    for path in Array(expected.keys) + excluded {
        let file = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: file)
    }

    let report = Scanner(home: home, uninstallHistory: []).scan(ScanOptions.smartCleanup(home: home))
    let homePath = home.resolvingSymlinksInPath().path
    let actual = Dictionary(uniqueKeysWithValues: report.candidates.map {
        let path = $0.url.resolvingSymlinksInPath().path
        return (String(path.dropFirst(homePath.count + 1)), $0.ruleID)
    })
    #expect(actual == expected)
    #expect(report.candidates.allSatisfy { !$0.selectedByDefault && $0.risk == .personalData })
}

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

@Test func scannerMatchesTrashCleanupRule() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let trash = root.appendingPathComponent("Trash")
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = trash.appendingPathComponent("removed.txt")
    try Data(repeating: 1, count: 8).write(to: file)
    let rule = CleanupRule(id: "system.trash", name: "废纸篓", pathPatterns: [trash.path + "/**"], risk: .personalData, explanation: "清空后无法恢复")

    let report = Scanner(catalog: RuleCatalog(rules: [rule])).scan(ScanOptions(roots: [trash]))

    #expect(report.candidates.count == 1)
    #expect(report.candidates.first?.url.standardizedFileURL == file.standardizedFileURL)
    #expect(report.candidates.first?.selectedByDefault == false)
}
