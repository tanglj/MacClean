import Foundation

public struct DuplicateSelection: Sendable {
    private let sizes: [URL: Int64]
    private var selected: Set<URL> = []
    public var count: Int { selected.count }
    public private(set) var size: Int64 = 0

    public init(group: DuplicateGroup) {
        sizes = Dictionary(group.files.map { ($0.id, $0.size) }, uniquingKeysWith: { first, _ in first })
    }

    public func contains(_ id: URL) -> Bool {
        selected.contains(id)
    }

    public mutating func toggle(_ id: URL) {
        guard let bytes = sizes[id] else { return }
        if selected.remove(id) != nil {
            size -= bytes
        } else {
            selected.insert(id)
            size += bytes
        }
    }
}
