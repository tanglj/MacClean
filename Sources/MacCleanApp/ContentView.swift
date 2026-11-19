import SwiftUI
import MacCleanCore

@MainActor
final class ScanViewModel: ObservableObject {
    enum State: Equatable { case idle, scanning, finished, failed(String) }

    @Published var state: State = .idle
    @Published var report: ScanReport?
    @Published private(set) var selection = ScanSelection()
    @Published private(set) var presentation = ScanPresentation(candidates: [])
    var selectedIDs: Set<UUID> { selection.ids }
    @Published var selectedRisk: RiskLevel?
    @Published var showDeleteConfirmation = false
    @Published var isDeleting = false
    @Published var deletionSummary: String?
    @Published var deletionFailures: [String] = []

    private let scanner = MacCleanCore.Scanner()
    private var scanTask: Task<Void, Never>?

    deinit { scanTask?.cancel() }

    var visibleCandidates: [ScanCandidate] { presentation.candidates(risk: selectedRisk) }
    var selectedCandidates: [ScanCandidate] { selectedIDs.compactMap { presentation.candidatesByID[$0] } }
    var selectedSize: Int64 { selection.size }
    var groupedCandidates: [CandidateGroup] { presentation.groups(risk: selectedRisk) }

    func toggleDirectory(_ directory: CandidateDirectory) {
        let selected = selection.count(groupID: directory.id, risk: selectedRisk) != directory.fileCount
        updateSelection(directory.descendants, selected: selected)
    }

    func toggleGroup(_ group: CandidateGroup) {
        let selected = selection.count(groupID: group.id, risk: selectedRisk) != group.candidates.count
        updateSelection(group.candidates, selected: selected)
    }

    private func updateSelection(_ candidates: [ScanCandidate], selected: Bool) {
        var next = selection
        next.set(candidates, selected: selected, in: presentation)
        selection = next
    }
    func startScan() {
        guard !isDeleting else { return }
        deletionSummary = nil
        deletionFailures = []
        scanTask?.cancel()
        state = .scanning
        report = nil
        selection = ScanSelection()
        let roots = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")]
        scanTask = Task { [scanner] in
            let (result, prepared, initialSelection) = await Task.detached(priority: .userInitiated) {
                let report = scanner.scan(ScanOptions(roots: roots))
                let prepared = ScanPresentation(candidates: report.candidates)
                var initial = ScanSelection()
                initial.set(report.candidates.filter(\.selectedByDefault), selected: true, in: prepared)
                return (report, prepared, initial)
            }.value
            guard !Task.isCancelled else { return }
            report = result
            presentation = prepared
            selection = initialSelection
            state = .finished
        }
    }

    func toggle(_ candidate: ScanCandidate) {
        updateSelection([candidate], selected: !selectedIDs.contains(candidate.id))
    }

    func selectVisible() { updateSelection(visibleCandidates, selected: true) }
    func deselectVisible() { updateSelection(visibleCandidates, selected: false) }

    func deleteSelected() {
        guard !isDeleting, state != .scanning, !selectedCandidates.isEmpty else { return }
        showDeleteConfirmation = true
    }

    func confirmDelete() {
        guard !isDeleting, state != .scanning, !selectedCandidates.isEmpty else { return }
        isDeleting = true
        deletionSummary = nil
        deletionFailures = []
        let candidates = selectedCandidates
        showDeleteConfirmation = false
        let auditURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacClean/operations.ndjson")
        let engine = DeletionEngine(pathGuard: PathGuard(allowedRoots: [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")]), auditLog: AuditLog(fileURL: auditURL))
        Task {
            let results = await engine.execute(candidates.map { DeletionRequest(candidate: $0, confirmed: true) })
            let previousReport = report
            let previousIDs = selectedIDs
            let (updatedReport, prepared, remainingSelection) = await Task.detached {
                let updated = previousReport?.applyingDeletionResults(results)
                let prepared = ScanPresentation(candidates: updated?.candidates ?? [])
                var remaining = ScanSelection()
                remaining.set(prepared.candidates.filter { previousIDs.contains($0.id) }, selected: true, in: prepared)
                return (updated, prepared, remaining)
            }.value
            report = updatedReport
            presentation = prepared
            selection = remainingSelection
            let deletedCount = results.filter { if case .deleted = $0 { return true }; return false }.count
            deletionFailures = results.compactMap { result in
                if case let .skipped(url, reason) = result { return "\(url.path)：\(reason)" }
                return nil
            }
            deletionSummary = "已删除 \(deletedCount) 个文件" + (deletionFailures.isEmpty ? "" : "，\(deletionFailures.count) 项未删除，已保留在列表中")
            isDeleting = false
        }
    }
}

struct ContentView: View {
    @StateObject private var model = ScanViewModel()
    @State private var page = "clean"
    @StateObject private var uninstallModel = UninstallModel()
    @StateObject private var duplicateModel = DuplicateModel()

    var body: some View {
        GeometryReader { geometry in
            NavigationSplitView {
                Sidebar(model: model, page: $page)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
            } detail: {
                if page == "apps" { UninstallView(model: uninstallModel) }
                else if page == "duplicates" { DuplicateView(model: duplicateModel) }
                else { Dashboard(model: model) }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .alert("确认永久删除", isPresented: $model.showDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("永久删除", role: .destructive) { model.confirmDelete() }
        } message: {
            Text("将永久删除 \(model.selectedIDs.count) 项，共 \(ByteCountFormatter.string(fromByteCount: model.selectedSize, countStyle: .file))。此操作无法恢复，请确认已检查路径和风险说明。")
        }
    }
}

private struct Sidebar: View {
    @ObservedObject var model: ScanViewModel
    @Binding var page: String

    var body: some View {
        List {
            Section("清理工具") {
                navigationButton("智能清理", icon: "sparkles", destination: "clean")
                navigationButton("应用卸载", icon: "app.badge.checkmark", destination: "apps")
                navigationButton("重复文件", icon: "square.on.square", destination: "duplicates")
            }
        }
        .navigationTitle("Mac Clean")
        .listStyle(.sidebar)
    }

    private func navigationButton(_ title: String, icon: String, destination: String) -> some View {
        Button { page = destination } label: {
            Label(title, systemImage: icon)
                .fontWeight(page == destination ? .semibold : .regular)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(page == destination ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

}

private struct Dashboard: View {
    @ObservedObject var model: ScanViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if case .scanning = model.state { scanning }
            else if model.report == nil { emptyState }
            else { results }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("智能清理").font(.system(size: 28, weight: .bold, design: .rounded))
                Text("按目录查看空间占用，确认后清理所选文件").foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.startScan() } label: { Label(model.report == nil ? "开始扫描" : "重新扫描", systemImage: "arrow.clockwise") }
                .buttonStyle(.borderedProminent)
                .disabled(model.isDeleting || model.state == .scanning)
        }.padding(28)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.questionmark").font(.system(size: 42)).foregroundStyle(.secondary)
            Text("还没有扫描结果").font(.title2.bold())
            Text("扫描你的用户资源库，找出可以清理的缓存和日志。").foregroundStyle(.secondary)
            Button("开始扫描") { model.startScan() }.buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanning: some View {
        VStack(spacing: 16) { ProgressView().controlSize(.large); Text("正在扫描用户资源库…").font(.headline); Text("首次扫描可能需要一些时间").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let summary = model.deletionSummary {
                VStack(alignment: .leading, spacing: 8) {
                    Label(summary, systemImage: model.deletionFailures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                    if !model.deletionFailures.isEmpty {
                        DisclosureGroup("查看未删除原因") {
                            ScrollView {
                                Text(model.deletionFailures.joined(separator: "\n"))
                                    .font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 100)
                        }
                    }
                }.padding(.horizontal, 24).padding(.vertical, 12)
            }
            HStack(spacing: 16) {
                let totalSize = model.groupedCandidates.reduce(Int64(0)) { $0 + $1.size }
                let selectedSize = model.selectedRisk.map { model.selection.riskSizes[$0] ?? 0 } ?? model.selectedSize
                Text("发现 \(model.visibleCandidates.count) 项，分为 \(model.groupedCandidates.count) 组 · 共 \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)) · 已选 \(ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file))")
                    .font(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("选择当前结果") { model.selectVisible() }.disabled(model.isDeleting)
                Button("取消全选") { model.deselectVisible() }.disabled(model.isDeleting)
            }.padding(.horizontal, 24).padding(.vertical, 16)
            List(model.groupedCandidates) { group in
                ResultGroupRow(group: group, selectedIDs: model.selectedIDs,
                    selectedCount: model.selection.count(groupID: group.id, risk: model.selectedRisk),
                    toggleGroup: { model.toggleGroup(group) }, toggleFile: { model.toggle($0) },
                    selection: model.selection, risk: model.selectedRisk, toggleDirectory: { model.toggleDirectory($0) })
            }.listStyle(.inset).disabled(model.isDeleting)
            Divider()
            HStack(spacing: 14) {
                Image(systemName: "checkmark.square.fill").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ByteCountFormatter.string(fromByteCount: model.selectedSize, countStyle: .file))
                        .font(.title3.bold()).monospacedDigit()
                    Text("已选择 \(model.selectedIDs.count) 个文件").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isDeleting { ProgressView().controlSize(.small) }
                Button(model.isDeleting ? "正在删除…" : "检查并清理") { model.deleteSelected() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.selectedIDs.isEmpty || model.isDeleting)
            }.padding(.horizontal, 24).padding(.vertical, 14)
                .background(.regularMaterial)

        }
    }
}

private struct GroupHeader: View {
    let group: CandidateGroup
    let selectedCount: Int
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: selectedCount == group.candidates.count ? "checkmark.square.fill" : (selectedCount == 0 ? "square" : "minus.square.fill"))
                    .foregroundStyle(selectedCount == group.candidates.count ? .blue : .secondary)
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(group.title).font(.headline)
                    Text(group.directory.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(group.directory.path)
                    Text(group.categories.joined(separator: "、") + " · " + group.risk.displayName)
                        .font(.caption).foregroundStyle(.secondary)
                    Text(group.impact).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(group.impact)
                }

                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(ByteCountFormatter.string(fromByteCount: group.size, countStyle: .file)).font(.headline).monospacedDigit()
                    Text("\(group.candidates.count) 个文件 · 已选 \(selectedCount)").font(.caption).foregroundStyle(.secondary)
                }
                Text(group.risk.displayName).font(.caption).foregroundStyle(group.risk.requiresExplicitSelection ? .orange : .green)
            }
        }.buttonStyle(.plain).padding(.vertical, 6)
            .accessibilityLabel("选择目录 " + group.title)
            .accessibilityValue("已选 \(selectedCount) / \(group.candidates.count)")
    }
}

private struct CandidateRow: View {
    let candidate: ScanCandidate
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.square.fill" : "square").foregroundStyle(selected ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 4) { Text(candidate.url.lastPathComponent).font(.headline); Text(candidate.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(candidate.url.path); Text(candidate.explanation).font(.caption).foregroundStyle(.orange).lineLimit(1) }
                Spacer(); VStack(alignment: .trailing, spacing: 4) { Text(ByteCountFormatter.string(fromByteCount: candidate.size, countStyle: .file)); Text(candidate.risk.displayName).font(.caption).foregroundStyle(candidate.risk.requiresExplicitSelection ? .orange : .green) }
            }.contentShape(Rectangle()).padding(.vertical, 5)
        }.buttonStyle(.plain)
    }
}

private struct ResultGroupRow: View {
    let group: CandidateGroup
    let selectedIDs: Set<UUID>
    let selectedCount: Int
    let toggleGroup: () -> Void
    let toggleFile: (ScanCandidate) -> Void
    let selection: ScanSelection
    let risk: RiskLevel?
    let toggleDirectory: (CandidateDirectory) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.bold()).frame(width: 28, height: 36).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(expanded ? "收起目录" : "展开目录")
                GroupHeader(group: group, selectedCount: selectedCount, toggle: toggleGroup)
            }
            if expanded {
                DirectoryContents(directory: group.tree, selection: selection, risk: risk,
                    toggleDirectory: toggleDirectory, toggleFile: toggleFile)
                    .padding(.leading, 28)
            }
        }.accessibilityElement(children: .contain)
    }
}

private struct DirectoryContents: View {
    let directory: CandidateDirectory
    let selection: ScanSelection
    let risk: RiskLevel?
    let toggleDirectory: (CandidateDirectory) -> Void
    let toggleFile: (ScanCandidate) -> Void
    @State private var limit = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(directory.directories.prefix(limit)) { child in
                DirectoryRow(directory: child, selection: selection, risk: risk,
                    toggleDirectory: toggleDirectory, toggleFile: toggleFile)
            }
            ForEach(directory.files.prefix(max(0, limit - directory.directories.count))) { file in
                CandidateRow(candidate: file, selected: selection.ids.contains(file.id)) { toggleFile(file) }
                    .padding(.leading, 36)
            }
            if directory.directories.count + directory.files.count > limit {
                Button("显示更多（剩余 \(directory.directories.count + directory.files.count - limit) 个项目）") { limit += 100 }
                    .padding(.leading, 36).padding(.vertical, 10)
            }
        }
    }
}

private struct DirectoryRow: View {
    let directory: CandidateDirectory
    let selection: ScanSelection
    let risk: RiskLevel?
    let toggleDirectory: (CandidateDirectory) -> Void
    let toggleFile: (ScanCandidate) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.bold()).frame(width: 28, height: 36).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel((expanded ? "收起 " : "展开 ") + directory.url.lastPathComponent)
                let count = selection.count(groupID: directory.id, risk: risk)
                Button { toggleDirectory(directory) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: count == directory.fileCount ? "checkmark.square.fill" : (count == 0 ? "square" : "minus.square.fill"))
                            .foregroundStyle(count == 0 ? Color.secondary : Color.accentColor)
                        Image(systemName: "folder.fill").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(directory.url.lastPathComponent).font(.headline)
                            Text("\(directory.fileCount) 个候选文件 · 已选 \(count)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: directory.size, countStyle: .file)).monospacedDigit()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help(directory.url.path)
            }.padding(.vertical, 6)
            if expanded {
                AnyView(DirectoryContents(directory: directory, selection: selection, risk: risk,
                    toggleDirectory: toggleDirectory, toggleFile: toggleFile))
                    .padding(.leading, 28)
            }
        }.accessibilityElement(children: .contain)
    }
}
