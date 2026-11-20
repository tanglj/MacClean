import Foundation

public struct AppInfo: Codable, Hashable, Sendable {
    public let url: URL
    public let bundleIdentifier: String
    public let displayName: String
    public let version: String?
}

public struct AppAssociation: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let url: URL
    public let reason: String
    public let size: Int64
    public let risk: RiskLevel

    public init(id: UUID = UUID(), url: URL, reason: String, size: Int64, risk: RiskLevel) {
        self.id = id
        self.url = url
        self.reason = reason
        self.size = size
        self.risk = risk
    }
}

public struct AppUninstaller: Sendable {
    public init() {}

    public func inspect(appURL: URL, searchRoots: [URL]) -> (app: AppInfo, associations: [AppAssociation])? {
        guard let dictionary = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              let bundleID = dictionary["CFBundleIdentifier"] as? String else { return nil }
        let name = ApplicationNameMapping.shared.displayName(for: bundleID)
            ?? ApplicationMetadata.displayName(at: appURL, info: dictionary)
        let info = AppInfo(url: appURL, bundleIdentifier: bundleID, displayName: name, version: dictionary["CFBundleShortVersionString"] as? String)
        var results: [AppAssociation] = []
        // Platform words such as "mac" cannot establish application ownership.
        let genericNames: Set<String> = ["mac", "macos", "osx", "app", "apps", "application", "desktop", "client", "helper", "main", "data", "cache", "caches", "logs", "preferences", "containers"]
        let bundleLeaf = bundleID.split(separator: ".").last.map(String.init) ?? ""
        let names = Set([bundleLeaf, name, dictionary["CFBundleName"] as? String ?? name,
                         appURL.deletingPathExtension().lastPathComponent]
            .map { $0.lowercased() }.filter { !$0.isEmpty && !genericNames.contains($0) })
        let identifier = bundleID.lowercased()
        var candidatePaths: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        if bundleID.caseInsensitiveCompare("com.google.Chrome") == .orderedSame {
            candidatePaths += [
                home.appendingPathComponent("Library/Application Support/Google/Chrome"),
                home.appendingPathComponent("Library/Caches/Google/Chrome")
            ]
        }
        for root in searchRoots {
            guard let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { continue }
            for child in children {
                let item = child.lastPathComponent.lowercased()
                let identifierMatch = item == identifier || item.hasPrefix(identifier + ".")
                let exactNameMatch = names.contains(item)
                let groupMatch = root.lastPathComponent == "Group Containers"
                    && matchesGroupContainer(item, bundleID: identifier)
                guard identifierMatch || exactNameMatch || groupMatch else { continue }
                guard child.standardizedFileURL != appURL.standardizedFileURL else { continue }
                guard let values = try? child.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]), values.isSymbolicLink != true else { continue }
                let reason = identifierMatch ? "完整 Bundle ID 匹配：\(bundleID)"
                    : (groupMatch ? "应用专属共享容器：\(bundleID)" : "应用名称完全匹配：\(name)")
                results.append(AppAssociation(url: child, reason: reason, size: Int64(values.fileSize ?? 0), risk: .personalData))
            }
        }
        for path in candidatePaths where FileManager.default.fileExists(atPath: path.path) {
            if path.standardizedFileURL == appURL.standardizedFileURL { continue }
            if let values = try? path.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]), values.isSymbolicLink != true {
                results.append(AppAssociation(url: path, reason: "应用专属关联目录：\(bundleID)", size: Int64(values.fileSize ?? 0), risk: .personalData))
            }
        }
        if bundleID.caseInsensitiveCompare("com.apple.dt.Xcode") == .orderedSame {
            results.append(contentsOf: xcodeDeveloperAssociations(home: home))
        }
        return (info, results.reduce(into: [String: AppAssociation]()) { $0[$1.url.path] = $1 }.values.sorted { $0.url.path < $1.url.path })
    }

    private func xcodeDeveloperAssociations(home: URL) -> [AppAssociation] {
        let xcodeRoot = home.appendingPathComponent("Library/Developer/Xcode", isDirectory: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let children = try? FileManager.default.contentsOfDirectory(at: xcodeRoot, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
            return []
        }
        return children.compactMap { child in
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { return nil }
            return AppAssociation(
                url: child,
                reason: "Xcode 专属开发数据",
                size: Int64(values.fileSize ?? 0),
                risk: .personalData
            )
        }
    }

    private func matchesGroupContainer(_ item: String, bundleID: String) -> Bool {
        if item == "group." + bundleID { return true }
        // A team prefix is accepted only before the complete bundle identifier.
        let parts = item.split(separator: ".", maxSplits: 1)
        if parts.count == 2, parts[0].utf8.count == 10,
           parts[0].utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) }),
           parts[1] == bundleID {
            return true
        }
        // WPS uses legacy group identifiers without its complete bundle ID.
        // Keep these explicit; never suffix-match an arbitrary app name.
        if bundleID == "com.kingsoft.wpsoffice.mac" {
            return ["4rkch4ctz9.wpsoffice", "yk4wke5wam.wpsoffice", "2g98r5qyu5.wpsoffice"].contains(item)
        }
        return false
    }
}
