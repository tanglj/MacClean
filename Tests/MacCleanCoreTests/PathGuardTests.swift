import Foundation
import Testing
@testable import MacCleanCore

@Test func pathGuardAllowsDescendantsAndRejectsOutsideRoots() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let child = root.appendingPathComponent("child.txt")
    try Data("test".utf8).write(to: child)
    let guarder = PathGuard(allowedRoots: [root])
    #expect(guarder.isAllowed(child))
    #expect(!guarder.isAllowed(FileManager.default.homeDirectoryForCurrentUser))
}

@Test func pathGuardRejectsSymlink() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("target")
    let link = root.appendingPathComponent("link")
    try Data("secret".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: PathGuardError.symbolicLink) { try PathGuard(allowedRoots: [root]).validate(link) }
}
