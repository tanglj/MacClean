import Foundation

/// Compiled once per scanner, rather than rebuilding patterns for every file.
struct PreparedCleanupRule: Sendable {
    let rule: CleanupRule
    private let paths: [NSRegularExpression]
    private let preserved: [NSRegularExpression]

    init(rule: CleanupRule, homeDirectory: URL) {
        self.rule = rule
        func compile(_ pattern: String) -> NSRegularExpression? {
            let expanded = pattern.hasPrefix("~/") ? homeDirectory.appendingPathComponent(String(pattern.dropFirst(2))).path : pattern
            let expression = NSRegularExpression.escapedPattern(for: expanded)
                .replacingOccurrences(of: "\\*\\*", with: ".*")
                .replacingOccurrences(of: "\\*", with: "[^/]*")
                .replacingOccurrences(of: "\\?", with: "[^/]")
            return try? NSRegularExpression(pattern: "^" + expression + "$", options: [.dotMatchesLineSeparators])
        }
        paths = rule.pathPatterns.compactMap(compile)
        preserved = rule.preservePatterns.compactMap(compile)
    }

    func matches(path: String) -> Bool {
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        return paths.contains { $0.firstMatch(in: path, range: range) != nil }
            && !preserved.contains { $0.firstMatch(in: path, range: range) != nil }
    }
}

public struct RuleMatcher: Sendable {
    public init() {}
    public func matches(_ url: URL, rule: CleanupRule, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        PreparedCleanupRule(rule: rule, homeDirectory: homeDirectory).matches(path: url.standardizedFileURL.path)
    }
}
