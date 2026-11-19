import Foundation

public enum RiskLevel: Int, Codable, CaseIterable, Sendable {
    case safeRebuildable = 0
    case attributed = 1
    case personalData = 2
    case highRisk = 3
    case prohibited = 4
}

public extension RiskLevel {
    var requiresExplicitSelection: Bool { self.rawValue >= 2 }
    var displayName: String {
        switch self {
        case .safeRebuildable: "可重建"
        case .attributed: "应用关联"
        case .personalData: "可能含个人资料"
        case .highRisk: "高风险"
        case .prohibited: "禁止操作"
        }
    }
}
