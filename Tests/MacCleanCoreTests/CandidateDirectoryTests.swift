import Foundation
import Testing
@testable import MacCleanCore

@Test func directoriesAggregateOnlyScannedFilesAndUpdateAncestorSelection() throws {
    let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MacClean-DirectoryFixture")
    let paths = ["Chrome/Default/Cache/a", "Chrome/Default/Cache/b", "Chrome/Profile 1/Cache/c", "root.log"]
    let files = paths.enumerated().map { index, path in
        ScanCandidate(url: fixtureRoot.appendingPathComponent("Library/Caches/Google/" + path), size: Int64(index + 1), ruleID: "cache", risk: index == 1 ? .personalData : .safeRebuildable, explanation: "test")
    }
    let presentation = ScanPresentation(candidates: files)
    let root = try #require(presentation.groups.first?.tree)
    #expect(root.fileCount == 4)
    #expect(root.size == 10)
    #expect(root.files.map(\.url.lastPathComponent) == ["root.log"])
    let chrome = try #require(root.directories.first)
    #expect(chrome.url.lastPathComponent == "Chrome")
    #expect(chrome.fileCount == 3)
    #expect(chrome.directories.count == 2)
    let profile = try #require(chrome.directories.first { $0.url.lastPathComponent == "Default" })
    #expect(profile.files.isEmpty)
    #expect(profile.directories.first?.files.count == 2)
    var selection = ScanSelection()
    selection.set(profile.descendants, selected: true, in: presentation)
    #expect(selection.size == 3)
    #expect(selection.count(groupID: root.id, risk: nil) == 2)
    #expect(selection.count(groupID: chrome.id, risk: nil) == 2)
    #expect(selection.count(groupID: profile.id, risk: .personalData) == 1)
    selection.set([files[0]], selected: false, in: presentation)
    #expect(selection.count(groupID: chrome.id, risk: nil) == 1)
    let filtered = try #require(presentation.groups(risk: .personalData).first?.tree)
    #expect(filtered.fileCount == 1)
    #expect(filtered.descendants == [files[1]])
    let updated = ScanReport(startedAt: Date(), finishedAt: Date(), candidates: files).applyingDeletionResults([.deleted(files[1].url)])
    let remaining = try #require(ScanPresentation(candidates: updated.candidates).groups.first?.tree)
    #expect(remaining.fileCount == 3)
    #expect(remaining.size == 8)
}
