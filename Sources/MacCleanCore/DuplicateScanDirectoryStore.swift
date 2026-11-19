import Foundation

/// Persists duplicate-scan roots independently of the installed app bundle.
public struct DuplicateScanDirectoryStore {
    public static let rootsKey = "duplicateScanRoots"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(fallback: [URL]) -> [URL] {
        guard let paths = defaults.stringArray(forKey: Self.rootsKey), !paths.isEmpty else {
            return normalizedUnique(fallback)
        }
        return normalizedUnique(paths.map { URL(fileURLWithPath: $0) })
    }

    public func save(_ roots: [URL]) {
        defaults.set(normalizedUnique(roots).map(\.path), forKey: Self.rootsKey)
    }

    private func normalizedUnique(_ roots: [URL]) -> [URL] {
        var seen = Set<URL>()
        return roots.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
    }
}
