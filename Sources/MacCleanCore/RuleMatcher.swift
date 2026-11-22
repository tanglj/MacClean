import Foundation

/// Compiled once per scanner, rather than rebuilding patterns for every file.
struct PreparedCleanupRule: Sendable {
    let rule: CleanupRule
    private let paths: [NSRegularExpression]
    private let pathPrefixes: [String]
    private let preserved: [NSRegularExpression]
    private let preservedPrefixes: [String]

    init(rule: CleanupRule, homeDirectory: URL) {
        self.rule = rule

        func filesystemPath(_ path: String) -> String {
            path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
        }

        func expand(_ pattern: String) -> String {
            let expanded = pattern.hasPrefix("~/") ? homeDirectory.appendingPathComponent(String(pattern.dropFirst(2))).path : pattern
            return filesystemPath(expanded)
        }

        func compile(_ pattern: String) -> NSRegularExpression? {
            let expression = NSRegularExpression.escapedPattern(for: expand(pattern))
                .replacingOccurrences(of: "\\*\\*", with: ".*")
                .replacingOccurrences(of: "\\*", with: "[^/]*")
                .replacingOccurrences(of: "\\?", with: "[^/]")
            return try? NSRegularExpression(pattern: "^" + expression + "$", options: [.dotMatchesLineSeparators])
        }

        func prefix(_ pattern: String) -> String {
            let expanded = expand(pattern)
            guard let wildcard = expanded.firstIndex(where: { $0 == "*" || $0 == "?" }) else { return expanded }
            return String(expanded[..<wildcard]).hasSuffix("/") ? String(expanded[..<wildcard]) : String(expanded[..<wildcard].dropLast())
        }

        paths = rule.pathPatterns.compactMap(compile)
        pathPrefixes = rule.pathPatterns.compactMap { compile($0) == nil ? nil : prefix($0) }
        preserved = rule.preservePatterns.compactMap(compile)
        preservedPrefixes = rule.preservePatterns.compactMap { compile($0) == nil ? nil : prefix($0) }
    }

    func matches(path: String) -> Bool {
        let path = path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        let matchesPath = paths.indices.contains { index in
            let prefix = pathPrefixes[index]
            return (prefix.isEmpty || path.hasPrefix(prefix)) && paths[index].firstMatch(in: path, range: range) != nil
        }
        guard matchesPath else { return false }
        return !preserved.indices.contains { index in
            let prefix = preservedPrefixes[index]
            return (prefix.isEmpty || path.hasPrefix(prefix)) && preserved[index].firstMatch(in: path, range: range) != nil
        }
    }
}

public struct RuleMatcher: Sendable {
    public init() {}
    public func matches(_ url: URL, rule: CleanupRule, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        PreparedCleanupRule(rule: rule, homeDirectory: homeDirectory).matches(path: url.standardizedFileURL.path)
    }
}
