import Foundation

public struct CleanupRule: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let scope: String
    public let pathPatterns: [String]
    public let risk: RiskLevel
    public let explanation: String
    public let preservePatterns: [String]

    public init(id: String, name: String, scope: String = "user", pathPatterns: [String], risk: RiskLevel, explanation: String, preservePatterns: [String] = []) {
        self.id = id
        self.name = name
        self.scope = scope
        self.pathPatterns = pathPatterns
        self.risk = risk
        self.explanation = explanation
        self.preservePatterns = preservePatterns
    }
}

public struct RuleCatalog: Sendable {
    public let rules: [CleanupRule]

    public init(rules: [CleanupRule] = RuleCatalog.builtInRules) {
        self.rules = rules
    }

    public static let builtInRules: [CleanupRule] = [
        CleanupRule(id: "user.logs", name: "用户日志", pathPatterns: ["~/Library/Logs/**"], risk: .safeRebuildable, explanation: "日志可以由应用重新生成。"),
        CleanupRule(id: "user.caches", name: "用户缓存", pathPatterns: ["~/Library/Caches/**"], risk: .safeRebuildable, explanation: "缓存可以由应用重新生成。"),
        CleanupRule(id: "crash.reports", name: "崩溃报告", pathPatterns: ["~/Library/Logs/DiagnosticReports/**"], risk: .safeRebuildable, explanation: "崩溃报告只用于诊断，删除不会影响应用运行。"),
        CleanupRule(id: "browser.chrome.cache", name: "Chrome 缓存", pathPatterns: ["~/Library/Caches/Google/Chrome/**"], risk: .personalData, explanation: "删除后 Chrome 会重新生成缓存，浏览器可能需要重新加载页面.", preservePatterns: ["**/Cookies", "**/Login Data", "**/Web Data"]),
        CleanupRule(id: "developer.build-artifacts", name: "开发构建产物", pathPatterns: ["**/node_modules/**", "**/target/**", "**/.build/**", "**/DerivedData/**"], risk: .personalData, explanation: "删除后项目通常需要重新下载依赖或重新构建。")
    ]
}
