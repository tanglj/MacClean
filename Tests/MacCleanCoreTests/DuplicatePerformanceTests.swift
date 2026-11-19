import Foundation
import Testing
@testable import MacCleanCore

@Test func duplicateSelectionStartsEmptyAndCachesTotals() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClean-DuplicateSelectionFixture")
    let files = (0..<100_001).map {
        DuplicateFile(url: root.appendingPathComponent("duplicates/\($0).bin"), size: 128)
    }
    let group = DuplicateGroup(digest: "selection", files: files)
    var selection = DuplicateSelection(group: group)
    #expect(selection.count == 0)
    #expect(selection.size == 0)
    #expect(group.files.allSatisfy { !selection.contains($0.id) })
    let ids = group.files.prefix(1_000).map(\.id)
    let clock = ContinuousClock()
    let start = clock.now
    for id in ids { selection.toggle(id) }
    let elapsed = clock.now - start
    #expect(selection.count == 1_000)
    #expect(selection.size == 128_000)
    print("100,001 个文件，连续勾选 1,000 个副本：\(elapsed)")
    #expect(selection.contains(ids[0]))
    #expect(!selection.contains(group.files[1_001].id))
    selection.toggle(ids[0])
    #expect(!selection.contains(ids[0]))
    #expect(selection.count == 999)
    #expect(selection.size == 127_872)
}

@Test func sampleRejectsLargeFilesWithoutReadingEntireContent() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("MacClean-Sampling-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let fileSize = 4 * 1024 * 1024
    for index in 0..<12 {
        try Data(repeating: UInt8(index), count: fileSize).write(to: root.appendingPathComponent("\(index).bin"))
    }
    let report = DuplicateScanner().scan(DuplicateScanOptions(roots: [root]))
    #expect(report.scannedFileCount == 12)
    #expect(report.groups.isEmpty)
    #expect(report.skippedPaths.isEmpty)
    #expect(report.fullyHashedFileCount == 0)
    #expect(report.bytesRead == 12 * 64 * 1024)
    print("48 MiB 同大小不同内容文件，实际读取：\(report.bytesRead) 字节")
}

@Test func identicalSamplesStillRequireFullContentMatch() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("MacClean-FullDigest-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let original = Data(repeating: 42, count: 256 * 1024)
    var differentMiddle = original
    differentMiddle[128 * 1024] = 7
    try original.write(to: root.appendingPathComponent("a.bin"))
    try original.write(to: root.appendingPathComponent("b.bin"))
    try differentMiddle.write(to: root.appendingPathComponent("c.bin"))
    let report = DuplicateScanner().scan(DuplicateScanOptions(roots: [root, root.appendingPathComponent(".")], minimumFileSize: 1))
    #expect(report.scannedFileCount == 3)
    #expect(report.groups.count == 1)
    #expect(report.groups[0].files.count == 2)
    #expect(!report.groups[0].files.contains { $0.url.lastPathComponent == "c.bin" })
    #expect(report.fullyHashedFileCount == 3)
}

@Test func scanCanBeCancelledBeforeFullHashing() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("MacClean-Cancellation-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let bytes = Data(repeating: 42, count: 256 * 1024)
    for name in ["a", "b"] { try bytes.write(to: root.appendingPathComponent(name)) }
    let control = DuplicateScanControl()
    let report = DuplicateScanner().scan(DuplicateScanOptions(roots: [root], minimumFileSize: 1), control: control) { progress in
        if progress.phase == .verifying { control.cancel() }
    }
    #expect(report.wasCancelled)
    #expect(report.fullyHashedFileCount == 0)
    #expect(report.groups.isEmpty)
    #expect(report.skippedPaths.isEmpty)
}
