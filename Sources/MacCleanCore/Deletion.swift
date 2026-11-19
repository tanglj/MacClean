import Foundation
import Darwin
import LocalAuthentication
import Security

@_silgen_name("AuthorizationExecuteWithPrivileges")
private func executeWithPrivileges(
    _ authorization: AuthorizationRef,
    _ tool: UnsafePointer<CChar>,
    _ options: AuthorizationFlags,
    _ arguments: UnsafePointer<UnsafeMutablePointer<CChar>>,
    _ communicationsPipe: UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
) -> OSStatus

public struct DeletionRequest: Sendable {
    public let candidate: ScanCandidate
    public let confirmed: Bool

    public init(candidate: ScanCandidate, confirmed: Bool) {
        self.candidate = candidate
        self.confirmed = confirmed
    }
}

public enum DeletionResult: Sendable, Equatable {
    case dryRun(URL)
    case deleted(URL)
    case skipped(URL, String)
}

public struct AuditEvent: Codable, Sendable {
    public let timestamp: Date
    public let operation: String
    public let path: String
    public let ruleID: String
    public let risk: RiskLevel
    public let result: String
    public let detail: String?
}

public actor AuditLog {
    private let fileURL: URL
    private let encoder = JSONEncoder()

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func append(_ event: AuditEvent) throws {
        let data = try encoder.encode(event)
        let line = data + Data([0x0A])
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
        } else {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try line.write(to: fileURL, options: .atomic)
        }
    }
}

public struct DeletionEngine: Sendable {
    private let pathGuard: PathGuard
    private let auditLog: AuditLog

    public init(pathGuard: PathGuard, auditLog: AuditLog) {
        self.pathGuard = pathGuard
        self.auditLog = auditLog
    }

    public func execute(_ requests: [DeletionRequest], dryRun: Bool = false) async -> [DeletionResult] {
        var results: [DeletionResult] = []
        for request in requests {
            let url = request.candidate.url
            do {
                let validated = try pathGuard.validate(url)
                guard request.confirmed else {
                    results.append(.skipped(validated, "未确认"))
                    continue
                }
                guard request.candidate.risk != .prohibited else { throw PathGuardError.prohibitedPath }
                if dryRun {
                    results.append(.dryRun(validated))
                    try? await auditLog.append(AuditEvent(timestamp: Date(), operation: "delete", path: validated.path, ruleID: request.candidate.ruleID, risk: request.candidate.risk, result: "dry_run", detail: nil))
                } else {
                    do {
                        try FileManager.default.removeItem(at: validated)
                        results.append(.deleted(validated))
                        try? await auditLog.append(AuditEvent(timestamp: Date(), operation: "delete", path: validated.path, ruleID: request.candidate.ruleID, risk: request.candidate.risk, result: "deleted", detail: nil))
                    } catch {
                        guard request.candidate.ruleID == "app.uninstall",
                              validated.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
                              isPermissionError(error) else { throw error }
                        try await removeWithAdministratorPrivileges(validated)
                        results.append(.deleted(validated))
                        try? await auditLog.append(AuditEvent(timestamp: Date(), operation: "delete", path: validated.path, ruleID: request.candidate.ruleID, risk: request.candidate.risk, result: "deleted", detail: "使用管理员授权删除"))
                    }
                }
            } catch {
                let detail = String(describing: error)
                results.append(.skipped(url, detail))
                try? await auditLog.append(AuditEvent(timestamp: Date(), operation: "delete", path: url.path, ruleID: request.candidate.ruleID, risk: request.candidate.risk, result: "skipped", detail: detail))
            }
        }
        return results
    }

    private func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return (nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.Code.fileWriteNoPermission.rawValue)
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == EACCES)
    }

    private func removeWithAdministratorPrivileges(_ url: URL) async throws {
        let authenticatedWithTouchID = await Self.authenticateWithTouchIDIfAvailable()
        try await Task.detached(priority: .userInitiated) {
            try Self.runPrivilegedRemoval(url, authenticatedWithTouchID: authenticatedWithTouchID)
        }.value
    }

    private static func authenticateWithTouchIDIfAvailable() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let context = LAContext()
                context.localizedFallbackTitle = "使用管理员密码"
                var availabilityError: NSError?
                guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &availabilityError) else {
                    continuation.resume(returning: false)
                    return
                }
                context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "验证身份以卸载受保护的应用") { success, _ in
                    continuation.resume(returning: success)
                }
            }
        }
    }

    private static func runPrivilegedRemoval(_ url: URL, authenticatedWithTouchID: Bool) throws {
        let toolPath = "/bin/rm"
        var authorization: AuthorizationRef?
        var status = AuthorizationCreate(nil, nil, [.interactionAllowed], &authorization)
        guard status == errAuthorizationSuccess, let authorization else {
            throw authorizationError(status)
        }
        defer { AuthorizationFree(authorization, []) }

        try toolPath.withCString { toolCString in
            try kAuthorizationRightExecute.withCString { rightNameCString in
                var rightItem = AuthorizationItem(
                    name: rightNameCString,
                    valueLength: toolPath.utf8.count + 1,
                    value: UnsafeMutableRawPointer(mutating: toolCString),
                    flags: 0
                )
                status = withUnsafeMutablePointer(to: &rightItem) { rightItemPointer in
                    var rights = AuthorizationRights(count: 1, items: rightItemPointer)
                    var flags: AuthorizationFlags = [.interactionAllowed, .extendRights]
                    if authenticatedWithTouchID {
                        flags.insert(.preAuthorize)
                    }
                    return AuthorizationCopyRights(authorization, &rights, nil, flags, nil)
                }
                guard status == errAuthorizationSuccess else {
                    throw authorizationError(status)
                }

                let arguments = [strdup("-rf"), strdup("--"), strdup(url.path)]
                defer { arguments.forEach { free($0) } }
                let argumentPointers = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: arguments.count + 1)
                defer { argumentPointers.deallocate() }
                for (index, argument) in arguments.enumerated() {
                    argumentPointers[index] = argument
                }
                argumentPointers[arguments.count] = nil
                let cArguments = UnsafeRawPointer(argumentPointers).assumingMemoryBound(to: UnsafeMutablePointer<CChar>.self)

                var communicationPipe: UnsafeMutablePointer<FILE>?
                status = executeWithPrivileges(authorization, toolCString, [], cArguments, &communicationPipe)
                guard status == errAuthorizationSuccess else {
                    throw authorizationError(status)
                }
                if let communicationPipe {
                    var buffer = [UInt8](repeating: 0, count: 256)
                    while fread(&buffer, 1, buffer.count, communicationPipe) > 0 {}
                    fclose(communicationPipe)
                }
            }
        }

        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "管理员授权后仍无法删除：\(url.path)"])
        }
    }

    private static func authorizationError(_ status: OSStatus) -> NSError {
        let detail: String
        switch status {
        case errAuthorizationCanceled, errAuthorizationDenied:
            detail = "管理员授权已取消或被拒绝"
        default:
            detail = "管理员授权失败（状态码 \(status)）"
        }
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: detail])
    }
}
