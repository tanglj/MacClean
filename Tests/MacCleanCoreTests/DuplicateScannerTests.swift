import Foundation
import Testing
@testable import MacCleanCore

struct DuplicateScannerTests {
    @Test func defaultScanIgnoresFilesSmallerThanOneMiB() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClean-MinimumSize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("small duplicate".utf8).write(to: root.appendingPathComponent("a.bin"))
        try Data("small duplicate".utf8).write(to: root.appendingPathComponent("b.bin"))

        let report = DuplicateScanner().scan(DuplicateScanOptions(roots: [root]))

        #expect(report.scannedFileCount == 0)
        #expect(report.groups.isEmpty)
    }

    @Test func findsExactDuplicatesAndAllowsSelectingEveryCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClean-Duplicates-\(UUID().uuidString)")
        let short = root.appendingPathComponent("a.txt")
        let long = root.appendingPathComponent("nested/long-name.txt")
        let unique = root.appendingPathComponent("unique.txt")
        try FileManager.default.createDirectory(at: long.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("same content".utf8).write(to: short)
        try Data("same content".utf8).write(to: long)
        try Data("different".utf8).write(to: unique)

        let report = DuplicateScanner().scan(DuplicateScanOptions(roots: [root], minimumFileSize: 1))
        #expect(report.groups.count == 1)
        let group = try #require(report.groups.first)
        #expect(Set(group.files.map(\.url)) == Set([short.standardizedFileURL, long.standardizedFileURL]))
        #expect(group.reclaimableBytes == Int64("same content".utf8.count))
        #expect(report.scannedFileCount == 3)

        var selection = DuplicateSelection(group: group)
        for file in group.files { selection.toggle(file.id) }
        #expect(group.files.allSatisfy { selection.contains($0.id) })
        #expect(selection.count == 2)
        #expect(selection.size == group.size * 2)
    }

    @Test func doesNotFollowSymbolicLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClean-Symlinks-\(UUID().uuidString)")
        let real = root.appendingPathComponent("real.txt")
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("content".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let report = DuplicateScanner().scan(DuplicateScanOptions(roots: [root], minimumFileSize: 1))
        #expect(report.groups.isEmpty)
        #expect(report.skippedSymbolicLinkCount == 1)
        #expect(report.skippedPaths.isEmpty)
    }

    @Test func skipsApplicationCacheDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClean-Cache-\(UUID().uuidString)")
        let cache = root.appendingPathComponent("JianyingPro/User Data/Cache/effect/mesh")
        let visible = root.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: visible, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("duplicate".utf8).write(to: cache.appendingPathComponent("brow_faceu_mesh.mesh"))
        try Data("duplicate".utf8).write(to: cache.appendingPathComponent("copy.mesh"))
        try Data("duplicate".utf8).write(to: visible.appendingPathComponent("a.mesh"))
        try Data("duplicate".utf8).write(to: visible.appendingPathComponent("b.mesh"))

        let report = DuplicateScanner().scan(DuplicateScanOptions(roots: [root], minimumFileSize: 1))

        #expect(report.groups.count == 1)
        #expect(report.groups[0].files.allSatisfy { $0.url.path.hasPrefix(visible.path + "/") })
        #expect(report.scannedFileCount == 2)
    }

    @Test func skipsMacMetadataAndLocalizedResourceDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClean-Metadata-\(UUID().uuidString)")
        let localized = root.appendingPathComponent("Media.localized/Automatically Add to Videos.localized/.localized")
        let visible = root.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: localized, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: visible, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("first"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("second"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("duplicate".utf8).write(to: root.appendingPathComponent("first/.DS_Store"))
        try Data("duplicate".utf8).write(to: root.appendingPathComponent("second/.DS_Store"))
        try Data("duplicate".utf8).write(to: localized.appendingPathComponent("en.strings"))
        try Data("duplicate".utf8).write(to: localized.appendingPathComponent("en_AU.strings"))
        try Data("duplicate".utf8).write(to: visible.appendingPathComponent("a.txt"))
        try Data("duplicate".utf8).write(to: visible.appendingPathComponent("b.txt"))

        let report = DuplicateScanner().scan(DuplicateScanOptions(roots: [root], minimumFileSize: 1))

        #expect(report.groups.count == 1)
        #expect(report.groups[0].files.allSatisfy { $0.url.path.hasPrefix(visible.path + "/") })
        #expect(report.scannedFileCount == 2)
    }

    @Test func skipsDependencyPackageDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClean-Dependencies-\(UUID().uuidString)")
        let goCache = root.appendingPathComponent("project/.gomodcache/modernc.org/sqlite/v1.50.0/testdata")
        let nodeModules = root.appendingPathComponent("project/node_modules/.pnpm/esbuild/node_modules/esbuild/bin")
        let visible = root.appendingPathComponent("project/sources")
        try FileManager.default.createDirectory(at: goCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: visible, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("duplicate".utf8).write(to: goCache.appendingPathComponent("fuzzdata3.db"))
        try Data("duplicate".utf8).write(to: goCache.appendingPathComponent("copy.db"))
        try Data("duplicate".utf8).write(to: nodeModules.appendingPathComponent("esbuild"))
        try Data("duplicate".utf8).write(to: nodeModules.appendingPathComponent("copy-esbuild"))
        try Data("duplicate".utf8).write(to: visible.appendingPathComponent("a.txt"))
        try Data("duplicate".utf8).write(to: visible.appendingPathComponent("b.txt"))

        let report = DuplicateScanner().scan(DuplicateScanOptions(roots: [root], minimumFileSize: 1))

        #expect(report.groups.count == 1)
        #expect(report.groups[0].files.allSatisfy { $0.url.path.hasPrefix(visible.path + "/") })
        #expect(report.scannedFileCount == 2)
    }
}
