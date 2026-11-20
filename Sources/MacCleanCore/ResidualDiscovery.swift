import Foundation

struct ResidualDiscovery {
    let identifiers: Set<String>
    let ownersByDirectory: [String: String]
    let homeLogs: [HomeLogSource]

    init(home: URL) {
        let library = home.appendingPathComponent("Library")
        let preferences = Self.children(library.appendingPathComponent("Preferences"), directories: false)
            .filter { $0.pathExtension == "plist" }.map { $0.deletingPathExtension().lastPathComponent }
            .filter(Self.applicationIdentifier)
        let support = Self.children(library.appendingPathComponent("Application Support"), directories: true)
        var domains = Set(support.map { $0.lastPathComponent.lowercased() })
        for category in ["HTTPStorages", "WebKit", "Saved Application State"] {
            for url in Self.children(library.appendingPathComponent(category), directories: true) {
                let domain = category == "Saved Application State" && url.pathExtension == "savedState" ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
                domains.insert(domain.lowercased())
            }
        }
        let byProduct = Dictionary(grouping: preferences) { $0.split(separator: ".").last!.lowercased() }
        var owners: [String: String] = [:]
        var identified: Set<String> = []
        let supportNames = Set(support.map { $0.lastPathComponent.lowercased() })
        for identifier in preferences {
            let key = identifier.lowercased()
            let product = String(key.split(separator: ".").last!)
            let distinctive = product.count >= 4 && !Self.genericNames.contains(product) && byProduct[product]?.count == 1
            guard domains.contains(key) || (distinctive && supportNames.contains(product)) || ApplicationNameMapping.shared.name(for: identifier) != nil else { continue }
            identified.insert(identifier)
            owners[key] = key
            if distinctive { owners[product] = key }
        }
        identifiers = identified
        ownersByDirectory = owners
        let reserved = Set(HomeLogSource.all.map(\.directory))
        homeLogs = Self.children(home, directories: true).compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("."), !reserved.contains(name), let owner = owners[String(name.dropFirst()).lowercased()],
                  Self.directory(url.appendingPathComponent("logs")) else { return nil }
            return HomeLogSource(directory: name, name: ApplicationNameMapping.shared.name(for: owner) ?? String(name.dropFirst()), identifier: owner, alternateIdentifiers: [])
        }
    }

    private static let genericNames: Set<String> = ["desktop", "app", "application", "client", "editor", "mac", "macos", "config", "local", "cache", "support", "shared", "library", "logs", "data", "tools", "configstore", "cargo", "docker", "npm", "ssh", "gnupg", "swiftpm", "vscode", "git"]

    private static func applicationIdentifier(_ name: String) -> Bool {
        let key = name.lowercased()
        guard !key.hasPrefix("com.apple."), !key.hasPrefix("group."),
              key.range(of: #"^[a-z][a-z0-9-]*\.[a-z0-9-]+(?:\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil else { return false }
        let parts = key.split(separator: ".")
        let componentTerms = ["helper", "agent", "updater", "autoupdate", "installer", "daemon", "service", "plugin", "extension", "shipit", "tests"]
        return !parts.dropFirst(2).contains { part in componentTerms.contains { part.contains($0) } }
    }

    static func directory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && url.resolvingSymlinksInPath().path == url.standardizedFileURL.path
    }

    private static func children(_ root: URL, directories: Bool) -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard directory(root), let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) else { return [] }
        return entries.filter { entry in
            guard let values = try? entry.resourceValues(forKeys: keys), values.isSymbolicLink == false else { return false }
            return directories ? values.isDirectory == true : values.isRegularFile == true
        }
    }
}
