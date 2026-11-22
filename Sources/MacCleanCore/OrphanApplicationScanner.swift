import AppKit
import Foundation

public enum UninstallHistory {
    private static let key = "MacClean.confirmedUninstalls"

    public static func record(_ identifier: String) {
        var identifiers = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        identifiers.insert(identifier)
        UserDefaults.standard.set(identifiers.sorted(), forKey: key)
    }

    public static var identifiers: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }
}

struct HomeLogSource: Sendable {
    let directory: String
    let name: String
    let identifier: String
    let alternateIdentifiers: [String]

    static let all = [
        HomeLogSource(directory: ".workbuddy", name: "WorkBuddy", identifier: "com.workbuddy.workbuddy", alternateIdentifiers: ["com.tencent.workbuddy.mac"]),
        HomeLogSource(directory: ".workbuddy-ai", name: "WorkBuddy", identifier: "com.workbuddy.workbuddy", alternateIdentifiers: ["com.tencent.workbuddy.mac"]),
        HomeLogSource(directory: ".cc-switch", name: "CC Switch", identifier: "com.ccswitch.desktop", alternateIdentifiers: [])
    ]

    func root(in home: URL) -> URL {
        home.appendingPathComponent(directory, isDirectory: true).appendingPathComponent("logs", isDirectory: true)
    }

    static func enclosingRoot(_ url: URL) -> (source: HomeLogSource, root: URL)? {
        var parent = url.deletingLastPathComponent()
        while parent.pathComponents.count > 2 {
            if parent.lastPathComponent == "logs", let source = all.first(where: { $0.directory == parent.deletingLastPathComponent().lastPathComponent }) {
                return (source, parent)
            }
            parent.deleteLastPathComponent()
        }
        return nil
    }
}

struct OrphanApplicationScanner: Sendable {
    private static let mainApplications: Set<String> = [
        "com.aone.keka", "com.colliderli.iina", "com.figma.Desktop", "com.fournova.Tower3",
        "com.github.GitHubClient", "com.googlecode.iterm2", "com.knollsoft.Rectangle",
        "com.microsoft.VSCode", "com.postmanlabs.mac", "com.raycast.macos", "com.sublimetext.4",
        "com.todesktop.230313mzl4w4u92", "org.audacityteam.audacity", "org.videolan.vlc"
    ]
    private let home: URL
    private let identifiers: Set<String>
    private let discovery: ResidualDiscovery
    private let logOwners: [String: String]

    init(home: URL, history: Set<String>, checkingOnly: String? = nil, installed: @Sendable (String) -> Bool, discovery: ResidualDiscovery? = nil) {
        self.home = home.standardizedFileURL
        let discovery = discovery ?? ResidualDiscovery(home: home)
        self.discovery = discovery
        let sources = HomeLogSource.all + discovery.homeLogs
        logOwners = Dictionary(uniqueKeysWithValues: sources.map { ($0.directory, $0.identifier) })
        let known = Self.mainApplications.union(history).union(HomeLogSource.all.map(\.identifier)).union(discovery.identifiers)
        let preferences = home.appendingPathComponent("Library/Preferences", isDirectory: true)
        identifiers = Set(known.filter { identifier in
            let name = identifier.lowercased()
            if let checkingOnly, name != checkingOnly.lowercased() { return false }
            guard !name.hasPrefix("com.apple."), !name.hasPrefix("group."),
                  identifier.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+){2,}$"#, options: .regularExpression) != nil else { return false }
            let aliases = HomeLogSource.all.first { $0.identifier == identifier }?.alternateIdentifiers ?? []
            let productIDs = [identifier] + aliases
            let hasPreference = productIDs.contains { productID in
                let file = preferences.appendingPathComponent(productID + ".plist")
                guard let attributes = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
                return attributes.isRegularFile == true && attributes.isSymbolicLink == false && file.resolvingSymlinksInPath().path == file.standardizedFileURL.path
            }
            return hasPreference && !productIDs.contains(where: installed)
        }.map { $0.lowercased() })
    }

    func owner(of path: String) -> String? {
        guard !identifiers.isEmpty, let identifier = pathOwner(normalizedPath(path)), identifiers.contains(identifier) else { return nil }
        return identifier
    }

    private func pathOwner(_ path: String) -> String? {
        let homePrefix = home.path + "/"
        guard path.hasPrefix(homePrefix) else { return nil }
        let relative = path.dropFirst(homePrefix.count)
        guard relative.hasPrefix("Library/") else {
            let parts = relative.split(separator: "/", maxSplits: 2)
            guard parts.count == 3, parts[1] == "logs", relative.hasSuffix(".log") else { return nil }
            return logOwners[String(parts[0])]
        }
        let parts = relative.dropFirst("Library/".count).split(separator: "/", maxSplits: 2)
        guard parts.count == 3 else { return nil }
        if parts[0] == "Application Support" {
            if let special = Self.supportOwner(directory: parts[1], relativePath: parts[2]) { return special }
            guard let owner = discovery.ownersByDirectory[parts[1].lowercased()], Self.disposableSupportFile(parts[2]) else { return nil }
            return owner
        }
        guard parts[0] == "Caches" || parts[0] == "Logs" else { return nil }
        let directory = parts[1].lowercased()
        return discovery.ownersByDirectory[directory] ?? directory
    }

    func permits(_ url: URL) -> Bool {
        guard owner(of: url.path) != nil else { return false }
        let libraryPrefix = normalizedPath(home.appendingPathComponent("Library").path) + "/"
        let path = normalizedPath(url.path)
        if !path.hasPrefix(libraryPrefix) { return true }
        if path.hasPrefix(libraryPrefix + "Application Support/") { return true }
        guard normalizedPath(url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path) + "/" == libraryPrefix else { return false }
        let category = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        return category == "Logs" ? url.pathExtension.lowercased() == "log" : ["cache", "tmp"].contains(url.pathExtension.lowercased())
    }

    func shouldTraverseDirectory(_ url: URL) -> Bool {
        let supportRoot = normalizedPath(home.appendingPathComponent("Library/Application Support", isDirectory: true).path) + "/"
        let path = normalizedPath(url.path)
        guard path.hasPrefix(supportRoot) else { return true }
        let relative = path.dropFirst(supportRoot.count)
        guard !relative.contains("/") else { return true }
        let name = relative.lowercased()
        return discovery.ownersByDirectory[name] != nil || ["audacity", "cursor"].contains(name)
    }

    private func normalizedPath(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    private static func supportOwner(directory: Substring, relativePath: Substring) -> String? {
        if directory == "audacity", relativePath == "lastlog.txt" { return "org.audacityteam.audacity" }
        guard directory == "Cursor" else { return nil }
        return disposableSupportFile(relativePath) ? "com.todesktop.230313mzl4w4u92" : nil
    }

    private static func disposableSupportFile(_ relativePath: Substring) -> Bool {
        let parts = relativePath.split(separator: "/")
        let matches: Bool
        switch parts.first {
        case "logs", "Logs":
            matches = parts.count == 2 && parts[1].hasSuffix(".log")
        case "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache":
            matches = parts.count == 2 && parts[1].range(of: #"^(index|data_[0-3]|f_[0-9a-f]{6})$"#, options: .regularExpression) != nil
        case "Cache":
            matches = (parts.count == 2 && (parts[1].hasSuffix(".cache") || parts[1].hasSuffix(".tmp"))) || relativePath == "Cache/Cache_Data/index-dir/the-real-index" || (parts.count == 3 && parts[1] == "Cache_Data" && parts[2].range(of: #"^(index|[0-9a-f]{16}_[0-2])$"#, options: .regularExpression) != nil)
        case "Code Cache":
            matches = ["Code Cache/js/index", "Code Cache/js/index-dir/the-real-index", "Code Cache/wasm/index", "Code Cache/wasm/index-dir/the-real-index"].contains(String(relativePath))
        default:
            matches = false
        }
        return matches
    }

    static func isInstalled(_ identifier: String) -> Bool {
        let workspace = NSWorkspace.shared
        if !workspace.urlsForApplications(withBundleIdentifier: identifier).isEmpty { return true }
        let name = identifier.lowercased()
        func related(_ value: String) -> Bool {
            let normalized = value.lowercased()
            return normalized == name || normalized.hasPrefix(name + ".") || name.hasPrefix(normalized + ".")
        }
        if workspace.runningApplications.compactMap(\.bundleIdentifier).contains(where: related) { return true }
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        let commands = HomeLogSource.all.filter { $0.identifier == name }.map { String($0.directory.dropFirst()) } + name.split(separator: ".").suffix(1).map(String.init)
        let bins = ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path, home.appendingPathComponent(".cargo/bin").path] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        if bins.contains(where: { bin in commands.contains { manager.isExecutableFile(atPath: bin + "/" + $0) } }) { return true }
        for root in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
            if !manager.fileExists(atPath: root.path), root.lastPathComponent == "Applications", root.path.hasPrefix(home.path + "/") { continue }
            var incomplete = false
            guard let entries = manager.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants], errorHandler: { _, _ in incomplete = true; return false }) else { return true }
            for case let url as URL in entries where url.pathExtension.lowercased() == "app" {
                guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return true }
                if related(bundleID) { return true }
            }
            if incomplete { return true }
        }
        for root in ["/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools", home.appendingPathComponent("Library/LaunchAgents").path] {
            do {
                if try manager.contentsOfDirectory(atPath: root).contains(where: { related($0.hasSuffix(".plist") ? String($0.dropLast(6)) : $0) }) { return true }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { continue }
            catch { return true }
        }
        return false
    }
}

public struct ResidualFileStamp: Codable, Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let modified: Date
    let size: Int64

    init?(_ url: URL) {
        guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
              let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date else { return nil }
        self.device = device.uint64Value
        self.inode = inode.uint64Value
        self.modified = modified
        self.size = size.int64Value
    }
}
