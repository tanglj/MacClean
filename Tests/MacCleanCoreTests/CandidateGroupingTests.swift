import Foundation
import Testing
@testable import MacCleanCore

@Test func groupsKeepOwnerTogetherAndSortBySize() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClean-GroupingFixture")
    func candidate(_ path: String, _ size: Int64) -> ScanCandidate {
        ScanCandidate(url: root.appendingPathComponent(path), size: size, ruleID: "user.caches", risk: .safeRebuildable, explanation: "缓存")
    }
    let groups = CandidateGrouping.groups(for: [
        candidate("Library/Caches/Google/Chrome/a", 10),
        candidate("Library/Caches/Google/Chrome/deep/b", 20),
        candidate("Library/Caches/Other/c", 5)
    ])
    #expect(groups.count == 2)
    #expect(groups[0].title == "Google")
    #expect(groups[0].size == 30)
    #expect(groups[0].candidates.count == 2)
    #expect(groups[0].directory.path == root.appendingPathComponent("Library/Caches/Google", isDirectory: true).path)
}

@Test func groupsUseInstalledApplicationMetadataWithoutGuessingUnrelatedDirectories() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Applications/Actual App.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(
        fromPropertyList: [
            "CFBundleIdentifier": "com.example.actual",
            "CFBundleDisplayName": "实际应用",
            "CFBundleName": "ActualApp"
        ],
        format: .xml,
        options: 0
    )
    try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))

    let candidates = [
        ScanCandidate(
            url: root.appendingPathComponent("Library/Caches/com.example.actual/session/data"),
            size: 1,
            ruleID: "user.caches",
            risk: .safeRebuildable,
            explanation: "缓存"
        ),
        ScanCandidate(
            url: root.appendingPathComponent("Library/Caches/BaiduMacHi/session/data"),
            size: 1,
            ruleID: "user.caches",
            risk: .safeRebuildable,
            explanation: "缓存"
        )
    ]
    let groups = CandidateGrouping.groups(for: candidates)

    #expect(groups.first(where: { $0.directory.lastPathComponent == "com.example.actual" })?.title == "实际应用")
    #expect(groups.first(where: { $0.directory.lastPathComponent == "BaiduMacHi" })?.title == "BaiduMacHi")
}
