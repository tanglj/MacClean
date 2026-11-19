import AppKit
import MacCleanCore
import SwiftUI

@MainActor
final class DuplicateGroupState: ObservableObject, Identifiable {
    let group: DuplicateGroup
    nonisolated var id: String { group.id }
    private(set) var selection: DuplicateSelection
    @Published private(set) var selectedCount: Int
    var selectedSize: Int64 { selection.size }

    init(group: DuplicateGroup, selection: DuplicateSelection) {
        self.group = group
        self.selection = selection
        selectedCount = selection.count
    }
    func contains(_ file: DuplicateFile) -> Bool { selection.contains(file.id) }
    func toggle(_ file: DuplicateFile) { selection.toggle(file.id); selectedCount = selection.count }
}

@MainActor
final class DuplicateModel: ObservableObject {
    enum State: Equatable { case idle, scanning, finished, failed(String) }

    @Published var state: State = .idle
    @Published private(set) var report: DuplicateScanReport?
    @Published private(set) var groups: [DuplicateGroupState] = []
    @Published var roots: [URL]
    @Published private(set) var selectedCount = 0
    @Published private(set) var selectedSize: Int64 = 0
    @Published private(set) var progress = DuplicateScanProgress()
    @Published var showDeleteConfirmation = false
    @Published var isDeleting = false
    @Published var message: String?
    @Published var failures: [String] = []
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let directoryStore = DuplicateScanDirectoryStore()
    private var task: Task<Void, Never>?
    private var control: DuplicateScanControl?
    private var scanID = UUID()

    init() {
        let currentHome = FileManager.default.homeDirectoryForCurrentUser
        let defaultRoots = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"].map {
            currentHome.appendingPathComponent($0)
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
        roots = directoryStore.load(fallback: defaultRoots)
        if UserDefaults.standard.stringArray(forKey: DuplicateScanDirectoryStore.rootsKey) == nil {
            directoryStore.save(roots)
        }
    }
    deinit { control?.cancel(); task?.cancel() }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "选择目录"
        guard panel.runModal() == .OK else { return }
        let previousRoots = roots
        for url in panel.urls where !roots.contains(url.standardizedFileURL) { roots.append(url.standardizedFileURL) }
        guard roots != previousRoots else { return }
        directoryStore.save(roots)
        invalidateResults()
    }

    func removeFolder(_ root: URL) {
        guard !isDeleting, state != .scanning else { return }
        let normalizedRoot = root.standardizedFileURL
        let updatedRoots = roots.filter { $0.standardizedFileURL != normalizedRoot }
        guard updatedRoots.count != roots.count else { return }
        roots = updatedRoots
        directoryStore.save(roots)
        invalidateResults()
    }

    private func invalidateResults() {
        report = nil
        groups = []
        selectedCount = 0
        selectedSize = 0
        message = nil
        failures = []
        state = .idle
    }

    func scan() {
        guard !roots.isEmpty, !isDeleting, state != .scanning else { return }
        control?.cancel()
        task?.cancel()
        let token = DuplicateScanControl()
        control = token
        let id = UUID()
        scanID = id
        state = .scanning
        report = nil
        groups = []
        selectedCount = 0
        selectedSize = 0
        progress = DuplicateScanProgress()
        message = nil
        failures = []
        let scanRoots = roots
        let onProgress: @Sendable (DuplicateScanProgress) -> Void = { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self, self.scanID == id, self.state == .scanning else { return }
                self.progress = update
            }
        }
        task = Task {
            let worker = Task.detached(priority: .utility) {
                let report = DuplicateScanner().scan(DuplicateScanOptions(roots: scanRoots), control: token, progress: onProgress)
                let prepared = report.wasCancelled ? [] : report.groups.map { ($0, DuplicateSelection(group: $0)) }
                return (report, prepared)
            }
            let (result, prepared) = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { token.cancel(); worker.cancel() }
            guard !Task.isCancelled, scanID == id else { return }
            guard !result.wasCancelled else { state = .idle; message = "已取消扫描"; return }
            report = result
            groups = prepared.map { DuplicateGroupState(group: $0.0, selection: $0.1) }
            state = .finished
        }
    }

    func cancelScan() { control?.cancel() }

    func toggle(_ file: DuplicateFile, in group: DuplicateGroupState) {
        let previousCount = group.selectedCount
        let previousSize = group.selectedSize
        group.toggle(file)
        selectedCount += group.selectedCount - previousCount
        selectedSize += group.selectedSize - previousSize
    }
    func deleteSelected() {
        guard !isDeleting, selectedCount > 0 else { return }
        showDeleteConfirmation = true
    }

    func confirmDelete() {
        guard !isDeleting, selectedCount > 0, let current = report else { return }
        showDeleteConfirmation = false
        isDeleting = true
        message = nil
        failures = []
        // Materialize selected paths once, off the main thread, at execution time.
        let snapshot = groups.map { ($0.group, $0.selection) }
        let allowedRoots = roots
        let audit = AuditLog(fileURL: home.appendingPathComponent("Library/Logs/MacClean/operations.ndjson"))
        let engine = DeletionEngine(pathGuard: PathGuard(allowedRoots: allowedRoots), auditLog: audit)
        Task {
            let (results, updated, prepared, deletedSize) = await Task.detached(priority: .userInitiated) {
                let targets = snapshot.flatMap { group, selection in group.files.filter { selection.contains($0.id) } }
                let requests = targets.map {
                    DeletionRequest(candidate: ScanCandidate(url: $0.url, size: $0.size, ruleID: "duplicate.file", risk: .personalData, explanation: "手动勾选的重复文件", selectedByDefault: false), confirmed: true)
                }
                let results = await engine.execute(requests)
                let deleted = Set(results.compactMap { result -> URL? in
                    if case let .deleted(url) = result { return url.standardizedFileURL }; return nil
                })
                let remaining = current.groups.compactMap { group -> DuplicateGroup? in
                    let files = group.files.filter { !deleted.contains($0.id) }
                    return files.count > 1 ? DuplicateGroup(digest: group.digest, files: files) : nil
                }
                let updated = DuplicateScanReport(startedAt: current.startedAt, finishedAt: Date(), groups: remaining,
                    scannedFileCount: current.scannedFileCount, skippedPaths: current.skippedPaths,
                    skippedSymbolicLinkCount: current.skippedSymbolicLinkCount, bytesRead: current.bytesRead,
                    fullyHashedFileCount: current.fullyHashedFileCount)
                let oldSelections = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.0.id, $0.1) })
                let prepared = remaining.map { group -> (DuplicateGroup, DuplicateSelection) in
                    var selection = DuplicateSelection(group: group)
                    if let old = oldSelections[group.id] {
                        for file in group.files where old.contains(file.id) { selection.toggle(file.id) }
                    }
                    return (group, selection)
                }
                let bytes = targets.reduce(Int64(0)) { $0 + (deleted.contains($1.id) ? $1.size : 0) }
                return (results, updated, prepared, bytes)
            }.value
            report = updated
            groups = prepared.map { DuplicateGroupState(group: $0.0, selection: $0.1) }
            selectedCount = prepared.reduce(0) { $0 + $1.1.count }
            selectedSize = prepared.reduce(0) { $0 + $1.1.size }
            failures = results.compactMap { result in
                if case let .skipped(url, reason) = result { return "\(url.path)：\(reason)" }; return nil
            }
            let deletedCount = results.count - failures.count
            message = "已删除 \(deletedCount) 个重复文件，文件大小合计 " + ByteCountFormatter.string(fromByteCount: deletedSize, countStyle: .file)
            isDeleting = false
        }
    }
}

struct DuplicateView: View {
    @ObservedObject var model: DuplicateModel
    @State private var groupLimit = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.layoutPriority(1)
            Divider()
            if case .scanning = model.state { scanning }
            else if model.report == nil { empty }
            else {
                GeometryReader { viewport in
                    results.frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.state) { _ in groupLimit = 50 }
        .alert("确认永久删除重复文件", isPresented: $model.showDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("永久删除", role: .destructive) { model.confirmDelete() }
        } message: {
            Text("将永久删除已勾选的 \(model.selectedCount) 个文件，共 \(ByteCountFormatter.string(fromByteCount: model.selectedSize, countStyle: .file))。此操作无法恢复。")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("重复文件").font(.system(size: 28, weight: .bold, design: .rounded))
                Text("仅检测 1 MB 以上的文件").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            selectedRoots
            Button("选择目录") { model.addFolder() }.disabled(model.isDeleting || model.state == .scanning)
            Button { model.scan() } label: { Label(model.report == nil ? "开始扫描" : "重新扫描", systemImage: "arrow.clockwise") }
                .buttonStyle(.borderedProminent).disabled(model.isDeleting || model.state == .scanning || model.roots.isEmpty)
        }.padding(28)
    }

    private var selectedRoots: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("扫描目录").font(.caption).foregroundStyle(.secondary)
            ScrollView(.vertical) {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(model.roots, id: \.self) { root in
                        HStack(spacing: 4) {
                            Text(root.path)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 300, alignment: .trailing)
                            Button { model.removeFolder(root) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("移除扫描目录")
                            .accessibilityLabel("移除扫描目录 " + root.path)
                            .disabled(model.isDeleting || model.state == .scanning)
                        }
                    }
                }
            }
            .frame(width: 340, height: 76)
            .scrollIndicators(.hidden)
        }
        .frame(width: 350, alignment: .trailing)
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.on.square").font(.system(size: 42)).foregroundStyle(.secondary)
            Text("还没有扫描结果").font(.title2.bold())
            Text("扫描常用用户目录，查找内容完全相同的文件。").foregroundStyle(.secondary)
            Text(model.roots.map(\.path).joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("开始扫描") { model.scan() }.buttonStyle(.borderedProminent).disabled(model.roots.isEmpty)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanning: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(progressTitle).font(.headline)
            Text("已发现 \(model.progress.scannedFileCount) 个文件").monospacedDigit()
            if model.progress.totalFileCount > 0 {
                ProgressView(value: Double(model.progress.processedFileCount), total: Double(model.progress.totalFileCount)).frame(width: 280)
                Text("已处理 \(model.progress.processedFileCount) / \(model.progress.totalFileCount) · 已读取 \(size(model.progress.bytesRead))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button("取消扫描") { model.cancelScan() }
        }.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private var progressTitle: String {
        switch model.progress.phase {
        case .discovering: "正在遍历文件…"
        case .sampling: "正在快速比较文件…"
        case .verifying: "正在校验相同内容…"
        case .finished: "正在整理结果…"
        case .cancelled: "正在停止扫描…"
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let report = model.report {
                Text("扫描 \(report.scannedFileCount) 个文件，发现 \(report.groups.count) 组重复 · 待删除 \(size(model.selectedSize))")
                    .font(.headline).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24).padding(.vertical, 16)
                if report.skippedSymbolicLinkCount > 0 {
                    Text("已跳过 \(report.skippedSymbolicLinkCount) 个符号链接").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24)
                }
                if !report.skippedPaths.isEmpty {
                    DisclosureGroup("\(report.skippedPaths.count) 个路径无法读取") {
                        ScrollView { Text(report.skippedPaths.prefix(100).joined(separator: "\n")).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 90)
                    }.font(.caption).foregroundStyle(.orange).padding(.horizontal, 24)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.groups.prefix(groupLimit)) { group in
                        DuplicateGroupRow(state: group, toggleFile: { model.toggle($0, in: group) }).equatable()
                        Divider()
                    }
                    if let report = model.report, report.groups.count > groupLimit {
                        Button("显示更多重复组（剩余 \(report.groups.count - groupLimit) 组）") { groupLimit += 50 }
                            .padding(.vertical, 16)
                    }
                    if model.report?.groups.isEmpty == true {
                        Text("没有待处理的重复文件").foregroundStyle(.secondary).padding(32)
                    }
                }.padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .disabled(model.isDeleting)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) { Text(size(model.selectedSize)).font(.title3.bold()).monospacedDigit(); Text("待删除 \(model.selectedCount) 个文件").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if model.isDeleting { ProgressView().controlSize(.small) }
                Button("删除") { model.deleteSelected() }.buttonStyle(.borderedProminent).disabled((model.selectedCount == 0) || model.isDeleting)
            }.padding(20).background(.regularMaterial).layoutPriority(1)
            if let message = model.message { Text(message).font(.callout).padding(.horizontal, 24).padding(.vertical, 8) }
            if !model.failures.isEmpty { Text(model.failures.joined(separator: "\n")).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(.horizontal, 24).padding(.bottom, 8) }
        }
    }

    private func size(_ bytes: Int64) -> String { bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

private struct DuplicateGroupRow: View, Equatable {
    @ObservedObject var state: DuplicateGroupState
    private var group: DuplicateGroup { state.group }
    private let identity: ObjectIdentifier
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
    let toggleFile: (DuplicateFile) -> Void
    @State private var expanded = false
    @State private var fileLimit = 50
    @State private var hoveredFileID: URL?

    init(state: DuplicateGroupState, toggleFile: @escaping (DuplicateFile) -> Void) {
        self.state = state
        identity = ObjectIdentifier(state)
        self.toggleFile = toggleFile
    }

    private var selectedCount: Int { state.selectedCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 24, height: 28)
                    Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(group.files.first?.url.lastPathComponent ?? "重复文件") · \(group.files.count) 个文件").font(.headline).lineLimit(1)
                        Text("每个 \(format(group.size))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("待删除 \(selectedCount)/\(group.files.count)").font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.vertical, 8)
            if expanded {
                ForEach(group.files.prefix(fileLimit)) { file in
                    let isSelected = state.contains(file)
                    HStack(spacing: 10) {
                        Button { toggleFile(file) } label: {
                            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                .foregroundStyle(isSelected ? .blue : .secondary)
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Button { toggleFile(file) } label: {
                                    Text(file.url.lastPathComponent).lineLimit(1)
                                }
                                .buttonStyle(.plain)
                                Button { revealInFinder(file) } label: {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 22, height: 22)
                                }
                                .buttonStyle(.plain)
                                .opacity(hoveredFileID == file.id ? 1 : 0)
                                .allowsHitTesting(hoveredFileID == file.id)
                                .help("在 Finder 中显示")
                                .accessibilityLabel("在 Finder 中显示 " + file.url.path)
                            }
                            Text(file.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(format(file.size)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("选择待删除文件 " + file.url.path)
                    .accessibilityValue(isSelected ? "已勾选" : "未勾选")
                    .contentShape(Rectangle())
                    .padding(.leading, 44)
                    .padding(.vertical, 5)
                    .onHover { isHovered in
                        hoveredFileID = isHovered ? file.id : nil
                    }
                }
                if group.files.count > fileLimit {
                    Button("显示更多文件（剩余 \(group.files.count - fileLimit) 个）") { fileLimit += 50 }
                        .padding(.leading, 44).padding(.vertical, 10)
                }
            }
        }
    }

    private func revealInFinder(_ file: DuplicateFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    private func format(_ bytes: Int64) -> String { bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
