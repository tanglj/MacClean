import SwiftUI
import AppKit
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

    private var cleanupRoots: [URL] {
        ScanOptions.smartCleanup().roots
    }

    func toggleDirectory(_ directory: CandidateDirectory) {
        let selected = selection.count(groupID: directory.id, risk: selectedRisk) != directory.fileCount
        updateSelection(directory.descendants.filter { $0.ruleID != "app.orphan" }, selected: selected)
    }

    func toggleGroup(_ group: CandidateGroup) {
        let selected = selection.count(groupID: group.id, risk: selectedRisk) != group.candidates.count
        updateSelection(group.candidates.filter { $0.ruleID != "app.orphan" }, selected: selected)
    }

    func toggleType(_ type: ScanPresentation.CleanupTypeGroup) {
        guard type.id != "app.orphan" else { return }
        let selected = selection.count(groupID: type.id, risk: selectedRisk) != type.candidates.count
        updateSelection(type.candidates, selected: selected)
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
        let roots = cleanupRoots
        scanTask = Task { [scanner] in
            let (result, prepared, initialSelection) = await Task.detached(priority: .userInitiated) {
                let report = scanner.scan(ScanOptions(roots: roots))
                let prepared = ScanPresentation(candidates: report.candidates, skippedPaths: report.skippedPaths)
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

    func selectVisible() { updateSelection(visibleCandidates.filter { $0.ruleID != "app.orphan" }, selected: true) }
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
        let engine = DeletionEngine(pathGuard: PathGuard(allowedRoots: cleanupRoots), auditLog: AuditLog(fileURL: auditURL))
        Task {
            let results = await engine.execute(candidates.map { DeletionRequest(candidate: $0, confirmed: true) })
            let previousReport = report
            let previousIDs = selectedIDs
            let (updatedReport, prepared, remainingSelection) = await Task.detached {
                let updated = previousReport?.applyingDeletionResults(results)
                let prepared = ScanPresentation(candidates: updated?.candidates ?? [], skippedPaths: updated?.skippedPaths ?? [])
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
            deletionSummary = "已清理 \(deletedCount) 个文件" + (deletionFailures.isEmpty ? "" : "，\(deletionFailures.count) 项未清理，已保留在列表中")
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
        HStack(spacing: 0) {
            Sidebar(model: model, page: $page)
                .frame(width: 220)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(.accentColor)
        .frame(minWidth: 920, minHeight: 620)
        .alert("确认清理所选文件", isPresented: $model.showDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确认清理", role: .destructive) { model.confirmDelete() }
        } message: {
            let residuals = model.selectedCandidates.filter { $0.ruleID == "app.orphan" }.count
            Text("移入废纸篓：\(residuals) 项。永久删除：\(model.selectedIDs.count - residuals) 项。共 \(FileSizeFormatter.string(fromByteCount: model.selectedSize))。")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if page == "apps" { UninstallView(model: uninstallModel) }
        else if page == "duplicates" { DuplicateView(model: duplicateModel) }
        else { Dashboard(model: model) }
    }
}

private struct Sidebar: View {
    @ObservedObject var model: ScanViewModel
    @Binding var page: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mac Clean")
                        .font(.system(size: 17, weight: .semibold))
                    Text("本地磁盘清理")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .padding(.bottom, 15)

            Text("清理工具")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)

            VStack(spacing: 4) {
                navigationButton("智能清理", icon: "sparkles", destination: "clean")
                navigationButton("应用卸载", icon: "app.badge.checkmark", destination: "apps")
                navigationButton("重复文件", icon: "square.on.square", destination: "duplicates")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func navigationButton(_ title: String, icon: String, destination: String) -> some View {
        Button { page = destination } label: {
            Label(title, systemImage: icon)
                .fontWeight(page == destination ? .semibold : .regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(page == destination ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

}

private struct Dashboard: View {
    @ObservedObject var model: ScanViewModel
    @State private var expandedTypeIDs: Set<String> = []

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
                Text("按类型查看空间占用，展开确认应用和文件").foregroundStyle(.secondary)
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
            Text("扫描缓存、日志、废纸篓和已卸载应用残留。").foregroundStyle(.secondary)
            Button("开始扫描") { model.startScan() }.buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanning: some View {
        VStack(spacing: 16) { ProgressView().controlSize(.large); Text("正在扫描用户资源库…").font(.headline); Text("正在检查缓存、日志、废纸篓和已卸载应用残留").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var results: some View {
        let grouped = model.presentation.results(risk: model.selectedRisk)
        let topLevelCount = grouped.categories.count
        return VStack(alignment: .leading, spacing: 0) {
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
                Text("发现 \(model.visibleCandidates.count) 项，分为 \(topLevelCount) 类 · 共 \(FileSizeFormatter.string(fromByteCount: totalSize)) · 已选 \(FileSizeFormatter.string(fromByteCount: selectedSize))")
                    .font(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("选择当前结果") { model.selectVisible() }.disabled(model.isDeleting)
                Button("取消全选") { model.deselectVisible() }.disabled(model.isDeleting)
            }.padding(.horizontal, 24).padding(.vertical, 16)
            if let skipped = model.report?.skippedPaths, !skipped.isEmpty {
                DisclosureGroup("跳过了 \(skipped.count) 个路径，空间仅统计已读取的文件") {
                    ScrollView {
                        Text(skipped.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 100)
                }.padding(.horizontal, 24)
            }
            List {
                ForEach(grouped.categories) { category in
                    typeSection(category)
                }
            }
            .listStyle(.inset)
            .disabled(model.isDeleting)
            Divider()
            HStack(spacing: 14) {
                Image(systemName: "checkmark.square.fill").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(FileSizeFormatter.string(fromByteCount: model.selectedSize))
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

    private func resultRow(_ group: CandidateGroup) -> some View {
        ResultGroupRow(group: group, selectedIDs: model.selectedIDs,
            selectedCount: model.selection.count(groupID: group.id, risk: model.selectedRisk),
            toggleGroup: { model.toggleGroup(group) }, toggleFile: { model.toggle($0) },
            selection: model.selection, risk: model.selectedRisk, toggleDirectory: { model.toggleDirectory($0) })
    }

    private func typeSection(_ category: ScanPresentation.CleanupTypeGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CleanupTypeHeader(
                category: category,
                selectedCount: model.selection.count(groupID: category.id, risk: model.selectedRisk),
                expanded: category.isExpandable && expandedTypeIDs.contains(category.id),
                toggle: { model.toggleType(category) },
                toggleExpanded: {
                    guard category.isExpandable else { return }
                    if expandedTypeIDs.contains(category.id) {
                        expandedTypeIDs.remove(category.id)
                    } else {
                        expandedTypeIDs.insert(category.id)
                    }
                }
            )
            if category.isExpandable && expandedTypeIDs.contains(category.id) {
                ForEach(category.groups) { group in
                    resultRow(group)
                }
                .padding(.leading, 16)
            }
        }
    }
}

private struct CleanupTypeHeader: View {
    let category: ScanPresentation.CleanupTypeGroup
    let selectedCount: Int
    let expanded: Bool
    let toggle: () -> Void
    let toggleExpanded: () -> Void

    var body: some View {
        let hasCandidates = !category.candidates.isEmpty
        let content = HStack(spacing: 12) {
            Image(systemName: category.icon)
                .font(.title2)
                .frame(width: 42, height: 42)
                .background(Color.secondary.opacity(0.12), in: Circle())
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(category.title).font(.headline)
                Text(category.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                Text(category.isUnavailable ? "需要权限" : (hasCandidates ? "\(category.candidates.count) 个项目" : "无可清理项目"))
                    .font(.headline)
                    .monospacedDigit()
                Text(category.isUnavailable ? "暂不可读取" : (hasCandidates ? FileSizeFormatter.string(fromByteCount: category.size) : "—"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if category.isExpandable && hasCandidates {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
        }
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: category.isUnavailable
                    ? "lock.fill"
                    : (!hasCandidates ? "square"
                    : (selectedCount == category.candidates.count
                        ? "checkmark.square.fill"
                        : (selectedCount == 0 ? "square" : "minus.square.fill"))))
                    .font(.title3)
                    .foregroundStyle(category.isUnavailable ? .orange : (hasCandidates && selectedCount == category.candidates.count ? .blue : .secondary))
            }
            .buttonStyle(.plain)
            .disabled(category.isUnavailable || !hasCandidates || category.id == "app.orphan")
            Group {
                if category.isExpandable {
                    Button(action: toggleExpanded) {
                        content.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(category.isUnavailable || !hasCandidates)
                } else {
                    content
                        .contentShape(Rectangle())
                }
            }
            .accessibilityLabel(category.title)
            .accessibilityValue(category.isUnavailable ? "需要完全磁盘访问权限" : "\(category.candidates.count) 个项目，\(FileSizeFormatter.string(fromByteCount: category.size))")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.45)
        }
    }
}

private struct GroupHeader: View {
    let group: CandidateGroup
    let selectedCount: Int
    let expanded: Bool
    let toggle: () -> Void
    let toggleExpanded: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: toggle) {
                Image(systemName: selectedCount == group.candidates.count ? "checkmark.square.fill" : (selectedCount == 0 ? "square" : "minus.square.fill"))
                    .foregroundStyle(selectedCount == group.candidates.count ? .blue : .secondary)
                    .font(.title3)
                    .frame(width: 22, height: 24)
            }
            .buttonStyle(.plain)
            .padding(.top, 9)

            GroupIcon(group: group)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button(action: toggle) {
                        Text(group.title).font(.headline)
                    }
                    .buttonStyle(.plain)

                    Button(action: toggleExpanded) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption.bold())
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "收起目录" : "展开目录")

                    Spacer(minLength: 0)
                }

                Button(action: toggle) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(group.locationDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(group.locations.map(\.path).joined(separator: "\n"))
                        Text(group.categories.joined(separator: "、") + " · " + group.risk.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(group.impact)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(group.impact)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 4) {
                Text(FileSizeFormatter.string(fromByteCount: group.size))
                    .font(.headline)
                    .monospacedDigit()
                Text("\(group.candidates.count) 个文件 · 已选 \(selectedCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(group.risk.displayName)
                    .font(.caption)
                    .foregroundStyle(group.risk.requiresExplicitSelection ? .orange : .green)
            }
            .frame(width: 150, alignment: .topTrailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .accessibilityLabel("选择目录 " + group.title)
        .accessibilityValue("已选 \(selectedCount) / \(group.candidates.count)")
    }
}

private struct GroupIcon: View {
    let group: CandidateGroup

    var body: some View {
        Group {
            if let image = ApplicationIconResolver.image(for: group) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 42, height: 42)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .accessibilityHidden(true)
    }
}

@MainActor
private enum ApplicationIconResolver {
    private static var imageCache: [String: NSImage] = [:]
    private static var applicationURLs: [URL]? = nil

    static func image(for group: CandidateGroup) -> NSImage? {
        let cacheKey = group.id
        if let image = imageCache[cacheKey] { return image }
        guard let appURL = applicationURL(for: group) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: appURL.path)
        image.size = NSSize(width: 42, height: 42)
        imageCache[cacheKey] = image
        return image
    }

    private static func applicationURL(for group: CandidateGroup) -> URL? {
        if group.directory.pathExtension == "app" {
            return group.directory
        }

        for location in group.locations {
            for component in location.pathComponents.reversed() {
                guard component.contains(".") else { continue }
                if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: component) {
                    return appURL
                }
            }
        }

        let targetName = group.title.caseInsensitiveCompare("已卸载应用") == .orderedSame ? nil : group.title
        return installedApplications.first { url in
            guard let targetName else { return false }
            let appName = Bundle(url: url)?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                ?? Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            let bundleID = Bundle(url: url)?.bundleIdentifier
            let mappedName = bundleID.flatMap { ApplicationNameMapping.shared.displayName(for: $0) } ?? appName
            return mappedName.caseInsensitiveCompare(targetName) == .orderedSame
        }
    }

    private static var installedApplications: [URL] {
        if let applicationURLs { return applicationURLs }
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        applicationURLs = roots.flatMap { root in
            (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "app" } ?? []
        }
        return applicationURLs ?? []
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
                Spacer(); VStack(alignment: .trailing, spacing: 4) { Text(FileSizeFormatter.string(fromByteCount: candidate.size)); Text(candidate.risk.displayName).font(.caption).foregroundStyle(candidate.risk.requiresExplicitSelection ? .orange : .green) }
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
            GroupHeader(
                group: group,
                selectedCount: selectedCount,
                expanded: expanded,
                toggle: group.candidates.first?.ruleID == "app.orphan" ? { expanded.toggle() } : toggleGroup,
                toggleExpanded: { expanded.toggle() }
            )
            if expanded {
                DirectoryContents(directory: group.tree, selection: selection, risk: risk,
                    toggleDirectory: toggleDirectory, toggleFile: toggleFile)
                    .padding(.leading, 28)
            }
        }
        .overlay(alignment: .bottom) {
            Divider().opacity(0.45)
        }
        .accessibilityElement(children: .contain)
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
                        Text(FileSizeFormatter.string(fromByteCount: directory.size)).monospacedDigit()
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
