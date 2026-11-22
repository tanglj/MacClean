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
        CleanupRule(id: "system.trash", name: "废纸篓", pathPatterns: ["~/.Trash/**"], risk: .personalData, explanation: "清空后文件将无法从废纸篓恢复。"),
        CleanupRule(id: "browser.cookies", name: "Cookie", pathPatterns: ["~/Library/Cookies/*.binarycookies", "~/Library/HTTPStorages/*.binarycookies", "~/Library/WebKit/**/Cookies/*.binarycookies"], risk: .personalData, explanation: "删除后部分网站可能需要重新登录。"),
        CleanupRule(id: "browser.web-cache", name: "Web 缓存", pathPatterns: ["~/Library/Caches/Google/Chrome/*/Cache/**", "~/Library/Caches/Google/Chrome/*/Code Cache/**", "~/Library/Caches/Google/Chrome/*/GPUCache/**", "~/Library/Caches/com.apple.Safari/WebKitCache/**", "~/Library/WebKit/*/NetworkCache/**"], risk: .personalData, explanation: "浏览器可能需要重新下载页面资源。"),
        CleanupRule(id: "crash.reports", name: "崩溃报告", pathPatterns: ["~/Library/Logs/DiagnosticReports/**"], risk: .personalData, explanation: "删除后将失去历史诊断记录。"),
        CleanupRule(id: "user.logs", name: "日志文件", pathPatterns: ["~/Library/Logs/**"], risk: .personalData, explanation: "请确认已无需保留这些历史日志。", preservePatterns: ["~/Library/Logs/MacClean/**"]),
        CleanupRule(id: "developer.package-caches", name: "开发工具缓存", pathPatterns: [
            "~/Library/Caches/Homebrew/**",
            "~/Library/Caches/pnpm/**",
            "~/Library/pnpm/store/**",
            "~/.npm/_cacache/**",
            "~/.npm/_npx/**",
            "~/.npm/_prebuilds/**",
            "~/.npm/_logs/**",
            "~/.gradle/caches/**",
            "~/.gradle/wrapper/dists/**",
            "~/.gradle/daemon/**",
            "~/.gradle/native/**",
            "~/.gradle/.tmp/**",
            "~/.m2/repository/**",
            "~/.bun/install/cache/**",
            "~/.nvm/.cache/**",
            "~/.cache/pip/**",
            "~/.cache/uv/**",
            "~/.cache/ruby-install/**",
            "~/.local/share/uv/cache/**",
            "~/.gem/specs/**"
        ], risk: .personalData, explanation: "包管理器和构建工具缓存，删除后可以重新下载或生成。"),
        CleanupRule(id: "user.caches", name: "应用程序缓存", pathPatterns: ["~/Library/Caches/**"], risk: .personalData, explanation: "按缓存目录识别，清理后可能需要重新下载或重建。", preservePatterns: ["~/Library/Caches/Google/Chrome/**", "~/Library/Caches/com.apple.Safari/**"]),
        CleanupRule(id: "developer.build-artifacts", name: "开发构建产物", pathPatterns: ["~/Library/Developer/Xcode/DerivedData/**"], risk: .personalData, explanation: "Xcode 可能需要重新构建项目或重建索引。", preservePatterns: ["**/SourcePackages/**", "**/Logs/**"]),
        CleanupRule(id: "app.orphan", name: "疑似已卸载应用残留", pathPatterns: [], risk: .personalData, explanation: "私有目录与偏好记录匹配。请展开逐项核对，所选文件将移入废纸篓。")
    ]
}
