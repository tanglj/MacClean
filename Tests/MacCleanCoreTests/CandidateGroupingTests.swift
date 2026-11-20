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

@Test func groupsUseApplicationMappingAndInstalledMetadata() throws {
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

    #expect(groups.first(where: { $0.title == "实际应用" })?.directory.lastPathComponent == "com.example.actual")
    #expect(groups.first(where: { $0.title == "如流" })?.directory.lastPathComponent == "BaiduMacHi")
}

@Test func applicationNameMappingMatchesBundleIDsAndAliasesCaseInsensitively() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let candidates = [
        ScanCandidate(
            url: root.appendingPathComponent("Library/Caches/COM.BAIDU.HI.MAC/session/data"),
            size: 1,
            ruleID: "user.caches",
            risk: .safeRebuildable,
            explanation: "缓存"
        ),
        ScanCandidate(
            url: root.appendingPathComponent("Library/Caches/BaiduMacHi/session/data"),
            size: 2,
            ruleID: "user.caches",
            risk: .safeRebuildable,
            explanation: "缓存"
        )
    ]

    let groups = CandidateGrouping.groups(for: candidates)

    #expect(groups.count == 1)
    #expect(groups[0].title == "如流")
    #expect(groups[0].candidates.count == 2)
}

@Test func appleSystemApplicationsUseLocalizedDisplayNames() {
    let expected: [String: String] = [
        "com.apple.Dictionary": "词典",
        "com.apple.MobileSMS": "信息",
        "com.apple.QuickTimePlayerX": "QuickTime Player",
        "com.apple.Shortcuts": "快捷指令",
        "com.apple.siri.launcher": "Siri",
        "com.apple.dt.Xcode": "Xcode"
    ]

    for (bundleIdentifier, displayName) in expected {
        #expect(ApplicationNameMapping.shared.displayName(for: bundleIdentifier) == displayName)
        #expect(ApplicationNameMapping.shared.displayName(for: bundleIdentifier.uppercased()) == displayName)
    }
}

@Test func orphanApplicationTitlesUseMappedDisplayNames() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let candidate = ScanCandidate(
        url: root.appendingPathComponent("Library/Application Support/com.todesktop.230313mzl4w4u92/state.db"),
        size: 1,
        ruleID: "app.orphan",
        risk: .personalData,
        explanation: "已卸载应用残留"
    )

    let group = CandidateGrouping.groups(for: [candidate]).first

    #expect(group?.title == "疑似残留 · Cursor")
}

@Test func groupsAllLocationsOfOneApplicationTogether() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Applications/Actual App.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(
        fromPropertyList: [
            "CFBundleIdentifier": "com.example.actual",
            "CFBundleDisplayName": "实际应用"
        ],
        format: .xml,
        options: 0
    )
    try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))

    let paths = [
        "Library/Caches/ActualApp/cache",
        "Library/Caches/com.example.actual/cache",
        "Library/Logs/com.example.actual/log"
    ]
    let candidates = paths.map { path in
        ScanCandidate(url: root.appendingPathComponent(path), size: 1, ruleID: "user.caches", risk: .safeRebuildable, explanation: "缓存")
    }
    let groups = CandidateGrouping.groups(for: candidates)

    #expect(groups.count == 1)
    #expect(groups[0].title == "实际应用")
    #expect(groups[0].locations.count == 3)
    #expect(groups[0].candidates.count == 3)
}
