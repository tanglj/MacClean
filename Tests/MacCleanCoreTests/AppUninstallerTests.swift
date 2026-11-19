import Foundation
import Testing
@testable import MacCleanCore

@Test func appAssociationsRequireExactNamesAndKeepDataUnselected() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("App.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.App", "CFBundleName": "App"], format: .xml, options: 0)
    try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
    let data = root.appendingPathComponent("Preferences")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    for name in ["com.example.App.plist", "com.example.AppOther.plist", "OtherApp.plist"] {
        try Data().write(to: data.appendingPathComponent(name))
    }
    let result = try #require(AppUninstaller().inspect(appURL: app, searchRoots: [data, data]))
    #expect(result.associations.count == 1)
    #expect(result.associations.first?.url.lastPathComponent == "com.example.App.plist")
    #expect(result.associations.first?.risk.requiresExplicitSelection == true)
}

@Test(arguments: ["com.baidu.hi.mac", "com.kingsoft.wpsoffice.mac", "com.postmanlabs.mac", "com.tencent.workbuddy.mac"])
func platformSuffixCannotAssociateOtherApplications(bundleID: String) throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("MacClean-Ownership-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let app = root.appendingPathComponent("TargetProduct.app")
    try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID, "CFBundleName": "TargetProduct"], format: .xml, options: 0)
    try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
    let roots = ["Containers", "HTTPStorages", "WebKit", "Application Support", "Group Containers"].map { root.appendingPathComponent($0) }
    let ids = ["com.baidu.hi.mac", "com.kingsoft.wpsoffice.mac", "com.postmanlabs.mac", "com.tencent.workbuddy.mac"]
    for directory in roots {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ids + [bundleID + ".plist", bundleID + ".binarycookies", "mac", "other.mac", "Other.TargetProduct", bundleID + "Other"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
    }
    let result = try #require(AppUninstaller().inspect(appURL: app, searchRoots: roots))
    #expect(result.associations.count == roots.count * 3)
    #expect(result.associations.allSatisfy {
        [bundleID, bundleID + ".plist", bundleID + ".binarycookies"].contains($0.url.lastPathComponent)
    })
}

@Test func legacyGroupAliasesAreExplicitAndRestrictedToGroupContainers() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("MacClean-GroupOwnership-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let app = root.appendingPathComponent("wpsoffice.app")
    try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let id = "com.kingsoft.wpsoffice.mac"
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": "wpsoffice"], format: .xml, options: 0)
    try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
    let group = root.appendingPathComponent("Group Containers")
    let ordinary = root.appendingPathComponent("HTTPStorages")
    let allowed = ["4RKCH4CTZ9.wpsoffice", "YK4WKE5WAM.wpsoffice", "2G98R5QYU5.wpsoffice", "ABCDE12345." + id, "group." + id]
    for directory in [group, ordinary] {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in allowed + ["Other.wpsoffice", "UNKNOWN123.wpsoffice", "ABCDE12345.mac", "other." + id] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
    }
    let result = try #require(AppUninstaller().inspect(appURL: app, searchRoots: [group, ordinary]))
    #expect(result.associations.count == allowed.count)
    #expect(Set(result.associations.map { $0.url.lastPathComponent }) == Set(allowed))
    #expect(result.associations.allSatisfy { $0.url.deletingLastPathComponent().lastPathComponent == "Group Containers" })
}
