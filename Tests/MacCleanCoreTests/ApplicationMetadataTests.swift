import Foundation
import Testing
@testable import MacCleanCore

@Test func zeroFileSizeUsesNumericZero() {
    #expect(FileSizeFormatter.string(fromByteCount: 0) == "0 KB")
}

@Test func localizedApplicationNamesUsePreferredLanguageAndFallback() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("Contents/Resources")
    for (language, name) in [("zh-Hans", "微信"), ("en", "WeChat")] {
        let directory = resources.appendingPathComponent(language + ".lproj")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleDisplayName": name], format: .binary, options: 0)
        try data.write(to: directory.appendingPathComponent("InfoPlist.strings"))
    }
    let info: [String: Any] = ["CFBundleName": "WeChat"]
    #expect(ApplicationMetadata.displayName(at: root, info: info, preferredLanguages: ["zh-Hans-CN"]) == "微信")
    #expect(ApplicationMetadata.displayName(at: root, info: info, preferredLanguages: ["en-US"]) == "WeChat")
    let missing = root.appendingPathComponent("Other.app")
    #expect(ApplicationMetadata.displayName(at: missing, info: ["CFBundleDisplayName": "准确名称", "CFBundleName": "Other"]) == "准确名称")
    #expect(ApplicationMetadata.displayName(at: missing, info: [:]) == "Other")
}

@Test func applicationFootprintCountsNestedFilesOnceAndDoesNotFollowSymlinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("App.app")
    let directory = app.appendingPathComponent("Contents/Subdir")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("data")
    try Data(repeating: 123, count: 16_384).write(to: file)
    let original = ApplicationFootprint.measure(at: app)
    #expect(original.isComplete)
    #expect(original.allocatedBytes > 0)
    try FileManager.default.linkItem(at: file, to: app.appendingPathComponent("hardlink"))
    let external = root.appendingPathComponent("external")
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    try Data(repeating: 13, count: 100_000).write(to: external.appendingPathComponent("large"))
    try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("outside"), withDestinationURL: external)
    let measured = ApplicationFootprint.measure(at: app)
    #expect(measured.isComplete)
    #expect(measured.allocatedBytes >= original.allocatedBytes)
    #expect(!ApplicationFootprint.measure(at: root.appendingPathComponent("missing")).isComplete)
}

@Test func combinedFootprintIncludesAssociatedFilesAndDeduplicatesOverlappingRoots() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("App.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    let nested = app.appendingPathComponent("data")
    try Data(repeating: 1, count: 16_384).write(to: nested)
    let preference = root.appendingPathComponent("app.plist")
    try Data(repeating: 2, count: 32_768).write(to: preference)
    let appSize = ApplicationFootprint.measure(at: app)
    let preferenceSize = ApplicationFootprint.measure(at: preference)
    let combined = ApplicationFootprint.measure(at: [app, preference, nested, app])
    #expect(combined.isComplete)
    #expect(preferenceSize.allocatedBytes > 0)
    #expect(combined.allocatedBytes == appSize.allocatedBytes + preferenceSize.allocatedBytes)
    let reversed = ApplicationFootprint.measure(at: [nested, app, preference])
     #expect(reversed.allocatedBytes == combined.allocatedBytes)
}
