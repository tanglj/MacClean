import Foundation

public enum PathGuardError: Error, Equatable, Sendable {
    case outsideAllowedRoot
    case symbolicLink
    case missingPath
    case prohibitedPath
    case pathChanged
}

public struct PathGuard: Sendable {
    public let allowedRoots: [URL]

    public init(allowedRoots: [URL]) {
        self.allowedRoots = allowedRoots.map { $0.standardizedFileURL }
    }

    public func validate(_ url: URL, allowMissing: Bool = false) throws -> URL {
        let standardized = url.standardizedFileURL
        guard allowMissing || FileManager.default.fileExists(atPath: standardized.path) else { throw PathGuardError.missingPath }
        guard !isSymbolicLink(standardized) else { throw PathGuardError.symbolicLink }
        guard allowedRoots.contains(where: { isDescendantOrEqual(standardized, of: $0) }) else { throw PathGuardError.outsideAllowedRoot }
        return standardized
    }

    public func isAllowed(_ url: URL) -> Bool {
        (try? validate(url)) != nil
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else { return true }
        return values.isSymbolicLink == true
    }

    private func isDescendantOrEqual(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
    }
}
