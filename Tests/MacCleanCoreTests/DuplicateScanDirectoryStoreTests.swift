import Foundation
import Testing
@testable import MacCleanCore

@Test func duplicateScanDirectoriesPersistAcrossStoreInstances() {
    let suiteName = "MacClean-DuplicateScanDirectoryStore-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = DuplicateScanDirectoryStore(defaults: defaults)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClean-DirectoryStoreFixture")
    let first = root.appendingPathComponent("one").standardizedFileURL
    let second = root.appendingPathComponent("two").standardizedFileURL

    store.save([first, second, first])

    #expect(DuplicateScanDirectoryStore(defaults: defaults).load(fallback: []) == [first, second])
}
