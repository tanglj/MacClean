import Foundation

/// A virtual directory tree containing only scanned candidates, never unscanned disk content.
public struct CandidateDirectory: Identifiable, Sendable {
    public let url: URL
    public let directories: [CandidateDirectory]
    public let files: [ScanCandidate]
    public let size: Int64
    public let fileCount: Int
    public var id: String { url.path }

    init(url: URL, candidates: [ScanCandidate]) {
        self.url = url
        let depth = url.pathComponents.count
        var direct: [ScanCandidate] = []
        var buckets: [String: [ScanCandidate]] = [:]
        for candidate in candidates {
            let components = candidate.url.pathComponents
            if components.count <= depth + 1 { direct.append(candidate) }
            else { buckets[components[depth], default: []].append(candidate) }
        }
        files = direct.sorted { $0.size == $1.size ? $0.url.path < $1.url.path : $0.size > $1.size }
        directories = buckets.map { name, files in
            CandidateDirectory(url: url.appendingPathComponent(name, isDirectory: true), candidates: files)
        }.sorted { $0.size == $1.size ? $0.id < $1.id : $0.size > $1.size }
        size = candidates.reduce(0) { $0 + $1.size }
        fileCount = candidates.count
    }

    /// Used only for explicit directory selection; drawing a row never flattens the subtree.
    public var descendants: [ScanCandidate] { files + directories.flatMap(\.descendants) }
}
