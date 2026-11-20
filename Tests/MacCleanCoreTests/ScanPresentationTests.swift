import Foundation
import Testing
@testable import MacCleanCore

@Test func selectionTracksBulkAndFilteredChangesWithoutRebuildingGroups() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClean-SelectionFixture")
    let candidates = (0..<10_000).map { index in
        ScanCandidate(url: root.appendingPathComponent("Library/Caches/App\(index % 10)/file\(index)"), size: 10, ruleID: "test", risk: index % 2 == 0 ? .safeRebuildable : .personalData, explanation: "test")
    }
    let presentation = ScanPresentation(candidates: candidates)
    var selection = ScanSelection()
    selection.set(candidates, selected: true, in: presentation)
    #expect(selection.ids.count == 10_000)
    #expect(selection.size == 100_000)
    #expect(presentation.groups.count == 10)
    #expect(selection.riskSizes[.safeRebuildable] == 50_000)
    let group = presentation.groups[0]
    #expect(selection.count(groupID: group.id, risk: nil) == group.candidates.count)
    selection.set(group.candidates, selected: true, in: presentation)
    #expect(selection.size == 100_000)
    selection.set(group.candidates, selected: false, in: presentation)
    #expect(selection.size == 90_000)
    #expect(selection.count(groupID: group.id, risk: nil) == 0)
    let safe = presentation.candidates(risk: .safeRebuildable)
    selection.set(safe, selected: false, in: presentation)
    #expect(selection.riskSizes[.safeRebuildable] == 0)
    for group in presentation.groups(risk: .safeRebuildable) {
        #expect(selection.count(groupID: group.id, risk: .safeRebuildable) == 0)
    }
    #expect(presentation.groups.map(\.id) == CandidateGrouping.groups(for: candidates).map(\.id))
}

@Test func orphanGroupSelectionIncludesTheOrphanCandidateItself() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClean-Orphan-Selection")
    let candidate = ScanCandidate(
        url: root.appendingPathComponent("Library/Preferences/com.example.removed.plist"),
        size: 12,
        ruleID: "app.orphan",
        risk: .personalData,
        explanation: "已卸载应用残留"
    )
    let presentation = ScanPresentation(candidates: [candidate])
    var selection = ScanSelection()

    selection.set([candidate], selected: true, in: presentation)

    #expect(presentation.groups.first?.title == "疑似残留 · com.example.removed")
    #expect(presentation.groups.first.map { selection.count(groupID: $0.id, risk: nil) } == 1)
}

@Test func uninstalledResultsCollectResidualGroupsUnderOneCategory() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClean-Orphan-Category")
    let residuals = ["com.example.one.plist", "com.example.two.plist"].map { name in
        ScanCandidate(url: root.appendingPathComponent("Library/Preferences/\(name)"),
            size: 12, ruleID: "app.orphan", risk: .personalData, explanation: "残留")
    }
    let cache = ScanCandidate(url: root.appendingPathComponent("Library/Caches/Example/cache"),
        size: 8, ruleID: "user.caches", risk: .safeRebuildable, explanation: "缓存")
    let presentation = ScanPresentation(candidates: residuals + [cache])
    let results = presentation.results(risk: nil)

    #expect(results.regular.flatMap(\.candidates).map(\.id) == [cache.id])
    #expect(Set(results.uninstalled.flatMap(\.candidates).map(\.id)) == Set(residuals.map(\.id)))
    #expect(presentation.results(risk: .safeRebuildable).uninstalled.isEmpty)
    #expect(presentation.results(risk: .personalData).regular.isEmpty)
    #expect(presentation.results(risk: .personalData).uninstalled.count == 2)
}

@Test func resultsAreGroupedByCleanupType() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClean-Type-Category")
    let candidates = [
        ScanCandidate(url: root.appendingPathComponent("Library/Caches/Example/cache"), size: 8, ruleID: "user.caches", risk: .safeRebuildable, explanation: "缓存"),
        ScanCandidate(url: root.appendingPathComponent("Library/Logs/Example.log"), size: 4, ruleID: "user.logs", risk: .safeRebuildable, explanation: "日志"),
        ScanCandidate(url: root.appendingPathComponent(".Trash/removed.txt"), size: 2, ruleID: "system.trash", risk: .personalData, explanation: "废纸篓")
    ]
    let presentation = ScanPresentation(candidates: candidates)
    let results = presentation.results(risk: nil)

    #expect(results.categories.map(\.id) == ["system.trash", "user.logs", "user.caches"])
    #expect(results.categories.first(where: { $0.id == "system.trash" })?.title == "废纸篓")
    #expect(results.categories.first(where: { $0.id == "user.caches" })?.candidates.count == 1)

    var selection = ScanSelection()
    let trash = results.categories.first(where: { $0.id == "system.trash" })!
    #expect(trash.isExpandable == false)
    selection.set(trash.candidates, selected: true, in: presentation)
    #expect(selection.count(groupID: trash.id, risk: nil) == 1)
}

@Test func unavailableTrashRemainsVisibleWithPermissionGuidance() {
    let trashPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true).path
    let presentation = ScanPresentation(candidates: [], skippedPaths: [trashPath])
    let trash = presentation.results(risk: nil).categories.first(where: { $0.id == "system.trash" })

    #expect(trash?.isUnavailable == true)
    #expect(trash?.explanation.contains("完全磁盘访问权限") == true)
}

@Test func fiftyThousandFilesSelectionBenchmark() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClean-SelectionBenchmark")
    let files = (0..<50_000).map { index in
        ScanCandidate(url: root.appendingPathComponent("Library/Caches/App\(index % 100)/file\(index)"), size: 100, ruleID: "test", risk: .safeRebuildable, explanation: "test")
    }
    let prepared = ScanPresentation(candidates: files)
    var selected = ScanSelection()
    let clock = ContinuousClock()
    let bulk = clock.measure { selected.set(files, selected: true, in: prepared) }
    let clicks = clock.measure {
        for index in 0..<1000 {
            selected.set([files[index]], selected: false, in: prepared)
        }
    }
    print("50,000 文件批量选择：\(bulk)；1,000 次单项取消选择：\(clicks)")
    #expect(selected.ids.count == 49_000)
    #expect(selected.size == 4_900_000)
}
