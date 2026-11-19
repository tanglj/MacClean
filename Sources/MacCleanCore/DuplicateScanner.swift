import CryptoKit
import Foundation

/// A file that participates in a duplicate group.
public struct DuplicateFile: Identifiable, Hashable, Sendable {
    public let id: URL
    public let url: URL
    public let size: Int64
    public let modifiedAt: Date?

    public init(url: URL, size: Int64, modifiedAt: Date? = nil) {
        let normalized = url.standardizedFileURL
        self.id = normalized
        self.url = normalized
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

/// Files with the same byte content.
public struct DuplicateGroup: Identifiable, Sendable {
    public let digest: String
    public let files: [DuplicateFile]
    public let id: String
    public var size: Int64 { files.first?.size ?? 0 }
    /// The amount of space occupied by redundant copies beyond the shared content.
    public var reclaimableBytes: Int64 { size * Int64(max(0, files.count - 1)) }

    public init(digest: String, files: [DuplicateFile]) {
        self.digest = digest
        self.id = "\(digest)-\(files.first?.size ?? 0)"
        self.files = files.map { (file: $0, path: $0.url.path) }
            .sorted { $0.path < $1.path }
            .map(\.file)
    }
}

public struct DuplicateScanOptions: Sendable {
    public static let defaultMinimumFileSize: Int64 = 1024 * 1024

    public let roots: [URL]
    public let minimumFileSize: Int64
    public let excludedDirectoryNames: Set<String>
    public let excludedDirectorySuffixes: Set<String>
    public let excludedFileNames: Set<String>

    public init(roots: [URL], minimumFileSize: Int64 = DuplicateScanOptions.defaultMinimumFileSize,
                excludedDirectoryNames: Set<String> = DuplicateScanner.defaultExcludedDirectoryNames,
                excludedDirectorySuffixes: Set<String> = DuplicateScanner.defaultExcludedDirectorySuffixes,
                excludedFileNames: Set<String> = DuplicateScanner.defaultExcludedFileNames) {
        self.roots = roots
        self.minimumFileSize = minimumFileSize
        self.excludedDirectoryNames = Set(excludedDirectoryNames.map { $0.lowercased() })
        self.excludedDirectorySuffixes = Set(excludedDirectorySuffixes.map { $0.lowercased() })
        self.excludedFileNames = Set(excludedFileNames.map { $0.lowercased() })
    }
}

public struct DuplicateScanReport: Sendable {
    public let startedAt: Date
    public let finishedAt: Date
    public let groups: [DuplicateGroup]
    public let scannedFileCount: Int
    public let skippedPaths: [String]
    public let skippedSymbolicLinkCount: Int
    public let bytesRead: Int64
    public let fullyHashedFileCount: Int
    public let wasCancelled: Bool
    public let duplicateFileCount: Int
    public let reclaimableBytes: Int64

    public init(startedAt: Date, finishedAt: Date, groups: [DuplicateGroup], scannedFileCount: Int, skippedPaths: [String] = [], skippedSymbolicLinkCount: Int = 0, bytesRead: Int64 = 0, fullyHashedFileCount: Int = 0, wasCancelled: Bool = false) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.groups = groups
        self.scannedFileCount = scannedFileCount
        self.skippedPaths = skippedPaths
        self.skippedSymbolicLinkCount = skippedSymbolicLinkCount
        self.bytesRead = bytesRead
        self.fullyHashedFileCount = fullyHashedFileCount
        self.wasCancelled = wasCancelled
        duplicateFileCount = groups.reduce(0) { $0 + $1.files.count }
        reclaimableBytes = groups.reduce(0) { $0 + $1.reclaimableBytes }
    }

}

public struct DuplicateScanProgress: Sendable {
    public enum Phase: Sendable { case discovering, sampling, verifying, finished, cancelled }
    public var phase: Phase = .discovering
    public var scannedFileCount = 0
    public var processedFileCount = 0
    public var totalFileCount = 0
    public var bytesRead: Int64 = 0
    public init() {}
}

/// Shared by the owning task and the bounded I/O workers.
public final class DuplicateScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } }
}

private final class DuplicateScanTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var progress = DuplicateScanProgress()
    private var lastEmission = Date.distantPast
    private var failures: [String] = []
    private var fullCount = 0
    private let callback: (@Sendable (DuplicateScanProgress) -> Void)?

    init(callback: (@Sendable (DuplicateScanProgress) -> Void)?) { self.callback = callback }

    func update(force: Bool = false, _ edit: (inout DuplicateScanProgress) -> Void) {
        let snapshot: DuplicateScanProgress? = lock.withLock {
            edit(&progress)
            guard callback != nil else { return nil }
            let now = Date()
            guard force || now.timeIntervalSince(lastEmission) >= 0.2 else { return nil }
            lastEmission = now
            return progress
        }
        if let snapshot { callback?(snapshot) }
    }
    func failed(_ url: URL) { lock.withLock { failures.append(url.path) } }
    func fullyHashed() { lock.withLock { fullCount += 1 } }
    func snapshot() -> (DuplicateScanProgress, [String], Int) {
        lock.withLock { (progress, failures, fullCount) }
    }
}

private struct FileDigest: Sendable {
    let file: DuplicateFile
    let digest: String
}

/// Only workers mutate their own slot. Reads happen after concurrentPerform joins.
private final class DigestResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[FileDigest]]
    init(workers: Int) { values = Array(repeating: [], count: workers) }
    func store(_ items: [FileDigest], at worker: Int) { lock.withLock { values[worker] = items } }
    func joined() -> [FileDigest] { lock.withLock { values.flatMap { $0 } } }
}

/// Exact matching uses size -> head/tail -> full SHA-256. At most three workers
/// read files, and every read is cancellable between bounded chunks.
public struct DuplicateScanner: Sendable {
    /// These directories contain rebuildable or app-managed cache data rather
    /// than user files that should be compared for duplicate cleanup.
    public static let defaultExcludedDirectoryNames: Set<String> = [
        "cache", "caches", "cachedata", "code cache", "gpu cache", "shader cache", "shadercache", "webcache",
        "node_modules", "gomodcache", ".gomodcache", "vendor", ".pnpm", ".npm", "pods", "carthage",
        ".gradle", ".m2", ".pub-cache", ".nuget", "site-packages", "__pycache__"
    ]
    public static let defaultExcludedDirectorySuffixes: Set<String> = [".localized"]
    public static let defaultExcludedFileNames: Set<String> = [".ds_store"]

    private let chunkSize = 1024 * 1024
    private let sampleSize = 32 * 1024
    public init() {}

    public func scan(_ options: DuplicateScanOptions,
                     control: DuplicateScanControl = DuplicateScanControl(),
                     progress: (@Sendable (DuplicateScanProgress) -> Void)? = nil) -> DuplicateScanReport {
        let startedAt = Date()
        let fm = FileManager.default
        let tracker = DuplicateScanTracker(callback: progress)
        var skipped: [String] = []
        var symbolicLinks = 0
        var scannedCount = 0
        var bySize: [Int64: [DuplicateFile]] = [:]
        var roots: [URL] = []
        for root in Set(options.roots.map(\.standardizedFileURL)).sorted(by: { $0.path.count < $1.path.count }) {
            if !roots.contains(where: { root == $0 || root.path.hasPrefix($0.path + "/") }) { roots.append(root) }
        }
        let excludedDirectoryNames = options.excludedDirectoryNames
        let excludedDirectorySuffixes = options.excludedDirectorySuffixes
        let excludedFileNames = options.excludedFileNames
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        rootLoop: for root in roots {
            if control.isCancelled { break }
            if isExcludedDirectory(root, names: excludedDirectoryNames, suffixes: excludedDirectorySuffixes) { continue }
            guard let rootValues = try? root.resourceValues(forKeys: [.isSymbolicLinkKey]), rootValues.isSymbolicLink != true else {
                skipped.append(root.path)
                continue
            }
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsPackageDescendants], errorHandler: { url, _ in
                skipped.append(url.path)
                return !control.isCancelled
            }) else {
                skipped.append(root.path)
                continue
            }
            for case let url as URL in enumerator {
                if control.isCancelled { break rootLoop }
                do {
                    let values = try url.resourceValues(forKeys: keys)
                    if values.isSymbolicLink == true { enumerator.skipDescendants(); symbolicLinks += 1; continue }
                    if values.isDirectory == true && isExcludedDirectory(url, names: excludedDirectoryNames, suffixes: excludedDirectorySuffixes) {
                        enumerator.skipDescendants()
                        continue
                    }
                    guard values.isRegularFile == true, let rawSize = values.fileSize else { continue }
                    if excludedFileNames.contains(url.lastPathComponent.lowercased()) { continue }
                    let size = Int64(rawSize)
                    guard size >= options.minimumFileSize else { continue }
                    scannedCount += 1
                    bySize[size, default: []].append(DuplicateFile(url: url, size: size, modifiedAt: values.contentModificationDate))
                    tracker.update { $0.scannedFileCount = scannedCount }
                } catch { skipped.append(url.path) }
            }
        }
        let candidates = bySize.values.filter { $0.count > 1 }.flatMap { $0 }
        bySize.removeAll()
        tracker.update(force: true) { $0.phase = .sampling; $0.totalFileCount = candidates.count; $0.processedFileCount = 0 }
        let sampled = hashes(candidates, sample: true, control: control, tracker: tracker)
        let sampleGroups = Dictionary(grouping: sampled) { "\($0.file.size):\($0.digest)" }
        var groups: [DuplicateGroup] = []
        var fullCandidates: [DuplicateFile] = []
        for items in sampleGroups.values where items.count > 1 {
            if items[0].file.size <= Int64(sampleSize * 2) {
                // Small files were read in full once during the sampling stage.
                groups.append(DuplicateGroup(digest: items[0].digest, files: items.map(\.file)))
            } else { fullCandidates.append(contentsOf: items.map(\.file)) }
        }
        tracker.update(force: true) { $0.phase = .verifying; $0.totalFileCount = fullCandidates.count; $0.processedFileCount = 0 }
        let verified = hashes(fullCandidates, sample: false, control: control, tracker: tracker)
        for items in Dictionary(grouping: verified, by: { "\($0.file.size):\($0.digest)" }).values where items.count > 1 {
            groups.append(DuplicateGroup(digest: items[0].digest, files: items.map(\.file)))
        }
        groups.sort { $0.reclaimableBytes == $1.reclaimableBytes ? $0.id < $1.id : $0.reclaimableBytes > $1.reclaimableBytes }
        tracker.update(force: true) { $0.phase = control.isCancelled ? .cancelled : .finished }
        let (state, failures, fullCount) = tracker.snapshot()
        return DuplicateScanReport(startedAt: startedAt, finishedAt: Date(), groups: groups, scannedFileCount: scannedCount,
            skippedPaths: skipped + failures, skippedSymbolicLinkCount: symbolicLinks,
            bytesRead: state.bytesRead, fullyHashedFileCount: fullCount, wasCancelled: control.isCancelled)
    }

    private func isExcludedDirectory(_ url: URL, names: Set<String>, suffixes: Set<String>) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return names.contains(name) || suffixes.contains { name.hasSuffix($0) }
    }

    private func hashes(_ files: [DuplicateFile], sample: Bool, control: DuplicateScanControl, tracker: DuplicateScanTracker) -> [FileDigest] {
        guard !files.isEmpty, !control.isCancelled else { return [] }
        let workers = min(3, files.count)
        let results = DigestResults(workers: workers)
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            var local: [FileDigest] = []
            for index in stride(from: worker, to: files.count, by: workers) {
                if control.isCancelled { break }
                let file = files[index]
                let value: FileDigest? = autoreleasepool {
                    do {
                        return FileDigest(file: file, digest: try digest(file, sample: sample, control: control, tracker: tracker))
                    } catch {
                        if !control.isCancelled { tracker.failed(file.url) }
                        return nil
                    }
                }
                if let value { local.append(value) }
                tracker.update { $0.processedFileCount += 1 }
            }
            results.store(local, at: worker)
        }
        return results.joined()
    }

    private func digest(_ file: DuplicateFile, sample: Bool, control: DuplicateScanControl, tracker: DuplicateScanTracker) throws -> String {
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        var hasher = SHA256()
        if sample && file.size > Int64(sampleSize * 2) {
            guard !control.isCancelled else { throw CancellationError() }
            let head = try handle.read(upToCount: sampleSize) ?? Data()
            try handle.seek(toOffset: UInt64(file.size - Int64(sampleSize)))
            let tail = try handle.read(upToCount: sampleSize) ?? Data()
            guard head.count == sampleSize, tail.count == sampleSize else { throw CocoaError(.fileReadCorruptFile) }
            hasher.update(data: head); hasher.update(data: tail)
            tracker.update { $0.bytesRead += Int64(head.count + tail.count) }
        } else {
            var read: Int64 = 0
            let readChunkSize = Int(min(Int64(chunkSize), max(1, file.size)))
            while true {
                guard !control.isCancelled else { throw CancellationError() }
                guard let chunk = try handle.read(upToCount: readChunkSize), !chunk.isEmpty else { break }
                hasher.update(data: chunk)
                read += Int64(chunk.count)
                tracker.update { $0.bytesRead += Int64(chunk.count) }
            }
            guard read == file.size else { throw CocoaError(.fileReadCorruptFile) }
            tracker.fullyHashed()
        }
        // Avoid accepting a digest for content that changed during the scan.
        let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == file.size,
              file.modifiedAt == nil || attributes[.modificationDate] as? Date == file.modifiedAt else {
            throw CocoaError(.fileReadUnknown)
        }
        let hex = Array("0123456789abcdef".utf8)
        return String(decoding: hasher.finalize().flatMap { [hex[Int($0 >> 4)], hex[Int($0 & 15)]] }, as: UTF8.self)
    }
}
