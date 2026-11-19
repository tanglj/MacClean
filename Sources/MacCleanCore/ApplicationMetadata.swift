import Foundation

public enum ApplicationMetadata {
    public static func displayName(at appURL: URL, info: [String: Any], preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        let resources = appURL.appendingPathComponent("Contents/Resources")
        let children = (try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)) ?? []
        let languages = children.filter { $0.pathExtension == "lproj" }.map { $0.deletingPathExtension().lastPathComponent }
        let preferred = Bundle.preferredLocalizations(from: languages, forPreferences: preferredLanguages)
        for language in preferred {
            let path = resources.appendingPathComponent(language + ".lproj/InfoPlist.strings")
            if let localized = NSDictionary(contentsOf: path) as? [String: Any], let name = name(in: localized) { return name }
        }
        return name(in: info) ?? appURL.deletingPathExtension().lastPathComponent
    }

    private static func name(in info: [String: Any]) -> String? {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let text = info[key] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }
}

public struct ApplicationFootprint: Sendable, Equatable {
    public let allocatedBytes: Int64
    public let isComplete: Bool

    /// Counts logical file sizes for an application and associated data, without following symlinks.
    /// The value matches Finder/Cleaner-style size displays rather than APFS allocated blocks.
    public static func measure(at url: URL) -> ApplicationFootprint {
        measure(at: [url])
    }

    public static func measure(at urls: [URL]) -> ApplicationFootprint {
        var total: Int64 = 0
        var complete = true
        var roots = Set<String>()
        for url in urls.sorted(by: { $0.path.count < $1.path.count }) {
            if Task.isCancelled { return ApplicationFootprint(allocatedBytes: total, isComplete: false) }
            let root = url.standardizedFileURL.path
            guard !roots.contains(where: { root == $0 || root.hasPrefix($0 + "/") }) else { continue }
            roots.insert(root)
            guard FileManager.default.fileExists(atPath: root) else { complete = false; continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
            process.arguments = [root, "-type", "f", "-exec", "/usr/bin/stat", "-f", "%z\n", "{}", "+"]
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { complete = false; continue }
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                    if let value = Int64(line) { total += value }
                }
            } catch { complete = false }
        }
        return ApplicationFootprint(allocatedBytes: total, isComplete: complete)
    }
}
