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
