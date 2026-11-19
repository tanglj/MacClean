import SwiftUI
import AppKit
import MacCleanCore

@MainActor
final class UninstallModel: ObservableObject {
    @Published var apps: [AppInfo] = []
    @Published var footprints: [URL: ApplicationFootprint] = [:]
    @Published var applicationFootprints: [URL: ApplicationFootprint] = [:]
    @Published var associationFootprints: [URL: ApplicationFootprint] = [:]
    @Published var selected: AppInfo?
    @Published var associations: [AppAssociation] = []
    @Published var checked = Set<URL>()
    @Published var busy = false
    @Published var inspecting = false
    @Published var message: String?
    @Published var confirm = false
    private var measurement: Task<Void, Never>?
    private var inspection: Task<Void, Never>?
    private let home = FileManager.default.homeDirectoryForCurrentUser
    var roots: [URL] { [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] }
    var dataRoots: [URL] {
        ["Caches", "Logs", "Preferences", "Application Support", "Saved Application State", "HTTPStorages", "WebKit", "Containers", "Group Containers"]
            .map { home.appendingPathComponent("Library/" + $0) }
    }
    var uninstallBlockReason: String? {
        guard let app = selected else { return nil }
        if isCurrentApp(app) {
            return "Mac Clean 正在运行，不能卸载自身；请退出后使用其他卸载工具操作。"
        }
        if isSystemApp(app) { return "系统应用受保护，无法卸载。" }
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
            return "请先退出 \(app.displayName)，再进行卸载。"
        }
        return nil
    }

    func refresh() {
        guard !busy else { return }
        let roots = roots
        let relatedRoots = dataRoots
        measurement?.cancel()
        inspection?.cancel()
        inspecting = false
        selected = nil
        associations = []
        checked = []
        footprints = [:]
        applicationFootprints = [:]
        associationFootprints = [:]
        busy = true
        Task {
            let found = await Task.detached { () -> [AppInfo] in
                var found: [AppInfo] = []
                for root in roots {
                    let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
                    for child in children where child.pathExtension == "app" {
                        if let app = AppUninstaller().inspect(appURL: child, searchRoots: [])?.app { found.append(app) }
                    }
                }
                return found.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            }.value
            apps = found
            busy = false
            measurement = Task {
                for app in found {
                    guard !Task.isCancelled else { return }
                    let worker = Task.detached(priority: .utility) {
                        let related = AppUninstaller().inspect(appURL: app.url, searchRoots: relatedRoots)?.associations ?? []
                        let appOnly = ApplicationFootprint.measure(at: app.url)
                        let total = ApplicationFootprint.measure(at: [app.url] + related.map(\.url))
                        return (appOnly, total)
                    }
                    let footprint = await withTaskCancellationHandler {
                        await worker.value
                    } onCancel: { worker.cancel() }
                    guard !Task.isCancelled else { return }
                    if apps.contains(where: { $0.url == app.url }) {
                        applicationFootprints[app.url] = footprint.0
                        footprints[app.url] = footprint.1
                    }
                }
            }
        }
    }

    func inspect(_ app: AppInfo) {
        inspection?.cancel()
        inspecting = true
        selected = app
        checked = [app.url]
        associations = []
        message = nil
        let roots = dataRoots
        inspection = Task {
            let result = await Task.detached { AppUninstaller().inspect(appURL: app.url, searchRoots: roots) }.value
            guard !Task.isCancelled, selected?.url == app.url else { return }
            associations = result?.associations ?? []
            checked.formUnion(associations.map(\.url))
            let items = associations
            let measured = await Task.detached {
                items.reduce(into: [URL: ApplicationFootprint]()) { result, item in
                    result[item.url] = ApplicationFootprint.measure(at: item.url)
                }
            }.value
            guard !Task.isCancelled, selected?.url == app.url else { return }
            associationFootprints = measured
            // Selection was initialized above. Do not overwrite user changes
            // made while size measurement was running.
            inspecting = false
        }
    }

    func toggle(_ url: URL) {
        if checked.contains(url) { checked.remove(url) } else { checked.insert(url) }
    }

    func uninstall() {
        guard !busy, !inspecting, let app = selected, !checked.isEmpty else { return }
        if let reason = uninstallBlockReason {
            message = reason
            return
        }
        let allowed = Set([app.url] + associations.map(\.url))
        let targets = checked.intersection(allowed)
        let requests = targets.map {
            DeletionRequest(candidate: ScanCandidate(url: $0, size: 0, ruleID: "app.uninstall", risk: .personalData, explanation: "用户确认卸载", selectedByDefault: false), confirmed: true)
        }
        let engine = DeletionEngine(pathGuard: PathGuard(allowedRoots: Array(allowed)), auditLog: AuditLog(fileURL: home.appendingPathComponent("Library/Logs/MacClean/operations.ndjson")))
        busy = true
        Task {
            let results = await engine.execute(requests)
            let deleted = Set(results.compactMap { if case let .deleted(url) = $0 { return url.standardizedFileURL }; return nil })
            associations.removeAll { deleted.contains($0.url.standardizedFileURL) }
            checked = checked.filter { !deleted.contains($0.standardizedFileURL) }
            if deleted.contains(app.url.standardizedFileURL) { apps.removeAll { $0.url == app.url }; selected = nil }
            let failures = results.compactMap { if case let .skipped(url, reason) = $0 { return "\(url.path)：\(reason)" }; return nil }
            message = "已删除 \(deleted.count) 项" + (failures.isEmpty ? "" : "\n" + failures.joined(separator: "\n"))
            busy = false
        }
    }

    private func isCurrentApp(_ app: AppInfo) -> Bool {
        app.url.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    private func isSystemApp(_ app: AppInfo) -> Bool {
        let path = app.url.standardizedFileURL.path
        return path == "/System/Applications"
            || path.hasPrefix("/System/Applications/")
            || path.hasPrefix("/System/Library/CoreServices/")
    }
}

struct UninstallView: View {
    @ObservedObject var model: UninstallModel
    @State private var search = ""
    private enum AppSort: String, CaseIterable { case name = "名称"; case size = "大小" }
    @State private var sort: AppSort = .name

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("应用卸载").font(.largeTitle.bold())
                Spacer()
                Button("刷新应用") { model.refresh() }.disabled(model.busy)
            }
            HStack(spacing: 10) {
                Picker("排序", selection: $sort) {
                    ForEach(AppSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu).frame(width: 90)
                TextField("搜索应用名称或 Bundle ID", text: $search).textFieldStyle(.roundedBorder)
            }
            HStack(alignment: .top, spacing: 20) {
                List(sortedApps, id: \.url) { app in
                    Button { model.inspect(app) } label: {
                        HStack {
                            ApplicationIcon(path: app.url.path)
                            VStack(alignment: .leading) {
                                Text(app.displayName).fontWeight(model.selected?.url == app.url ? .bold : .regular)
                                Text(app.version ?? "未知版本").font(.caption).foregroundStyle(.secondary)
                                Text(totalSizeLabel(app.url)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(model.selected?.url == app.url ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                .frame(minWidth: 220, maxWidth: 300, maxHeight: .infinity)
                .disabled(model.busy)
                VStack(alignment: .leading, spacing: 12) {
                    if let app = model.selected {
                        Text(app.displayName).font(.title2.bold())
                        Text(app.bundleIdentifier).foregroundStyle(.secondary).textSelection(.enabled)
                        Label("总占用：" + totalSizeLabel(app.url), systemImage: "internaldrive")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if model.footprints[app.url]?.isComplete == false {
                            Label("部分数据无法读取。请打开“系统设置 > 隐私与安全性 > 完全磁盘访问权限”，开启 Mac Clean 后重新检查。", systemImage: "lock.shield")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                        if let reason = model.uninstallBlockReason {
                            Label(reason, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                        List {
                            pathRow(app.url, title: app.displayName + " 应用本体", size: sizeLabel(app.url))
                            ForEach(model.associations) { item in
                                pathRow(item.url, title: associationTitle(item.url), size: associationSizeLabel(item.url))
                            }
                        }.disabled(model.busy)
                        Button("永久删除所选 \(model.checked.count) 项", role: .destructive) { model.confirm = true }
                            .disabled(model.busy || model.inspecting || model.checked.isEmpty || model.uninstallBlockReason != nil)
                    } else {
                        Spacer()
                        VStack(spacing: 10) {
                            Image(systemName: model.busy ? "hourglass" : "app.badge")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                            Text(model.busy ? "正在读取应用…" : "选择应用，查看卸载项目")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        Spacer()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if let message = model.message {
                ScrollView {
                    Text(message)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
        .task { if model.apps.isEmpty && !model.busy { model.refresh() } }
        .alert("确认永久卸载", isPresented: $model.confirm) {
            Button("取消", role: .cancel) {}
            Button("永久删除", role: .destructive) { model.uninstall() }
        } message: {
            Text("将彻底删除所选应用和关联项目，无法恢复。请确认上方列表中的路径。")
        }
    }

    private var sortedApps: [AppInfo] {
        let filtered = model.apps.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) || $0.bundleIdentifier.localizedCaseInsensitiveContains(search) }
        switch sort {
        case .name: return filtered.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .size: return filtered.sorted { (model.footprints[$0.url]?.allocatedBytes ?? 0) > (model.footprints[$1.url]?.allocatedBytes ?? 0) }
        }
    }

    private func associationSizeLabel(_ url: URL) -> String {
        guard let footprint = model.associationFootprints[url] else { return "正在计算空间…" }
        let size = footprint.allocatedBytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: footprint.allocatedBytes, countStyle: .file)
        return footprint.isComplete ? size : "至少 " + size + "（部分无法读取）"
    }

    private func totalSizeLabel(_ url: URL) -> String {
        guard let footprint = model.footprints[url] else { return "正在计算空间…" }
        let size = footprint.allocatedBytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: footprint.allocatedBytes, countStyle: .file)
        return footprint.isComplete ? size : "至少 " + size + "（部分无法读取）"
    }

    private func sizeLabel(_ url: URL) -> String {
        guard let footprint = model.applicationFootprints[url] else { return "正在计算空间…" }
        let size = footprint.allocatedBytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: footprint.allocatedBytes, countStyle: .file)
        return footprint.isComplete ? size : "至少 " + size + "（部分无法读取）"
    }

    private func associationTitle(_ url: URL) -> String {
        let components = url.standardizedFileURL.pathComponents
        if let developerIndex = components.firstIndex(of: "Developer"), developerIndex + 2 < components.count,
           components[developerIndex + 1] == "Xcode" {
            switch components[developerIndex + 2] {
            case "DerivedData":
                return "Xcode 构建数据与索引：DerivedData"
            case "iOS DeviceSupport":
                return "Xcode iOS 设备支持：iOS DeviceSupport"
            case "DeviceLogs":
                return "Xcode 设备日志：DeviceLogs"
            case "Archives":
                return "Xcode 归档：Archives"
            case "UserData":
                return "Xcode 用户配置：UserData"
            case "Previews":
                return "Xcode 预览数据：Previews"
            default:
                return "Xcode 开发数据：" + components[developerIndex + 2]
            }
        }
        guard let libraryIndex = components.firstIndex(of: "Library"), libraryIndex + 1 < components.count else {
            return "关联数据：" + url.lastPathComponent
        }

        let category = components[libraryIndex + 1]
        let type: String
        switch category {
        case "Application Support":
            type = "应用支持数据"
        case "Caches":
            type = "缓存数据"
        case "Logs":
            type = "日志数据"
        case "Preferences":
            type = "偏好设置"
        case "Saved Application State":
            type = "应用状态数据"
        case "HTTPStorages":
            type = url.lastPathComponent.lowercased().contains("binarycookies") ? "网络 Cookie 数据" : "网络存储数据"
        case "WebKit":
            type = "Web 浏览数据"
        case "Containers":
            type = "应用沙盒数据"
        case "Group Containers":
            type = "共享容器数据"
        default:
            type = "关联数据"
        }
        return type + "：" + url.lastPathComponent
    }

    private func pathRow(_ url: URL, title: String, size: String) -> some View {
        Toggle(isOn: Binding(get: { model.checked.contains(url) }, set: { _ in model.toggle(url) })) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                    Spacer()
                    Text(size).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.secondary.opacity(0.16))
                .frame(height: 1)
        }
    }
}

private struct ApplicationIcon: View {
    let path: String
    @State private var icon: NSImage?
    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable() }
            else { Image(systemName: "app").resizable() }
        }.frame(width: 32, height: 32)
            .task(id: path) {
                // LaunchServices may retain a stale icon for the app being
                // inspected. Read our bundled ICNS directly so the uninstall
                // list always reflects the current application artwork.
                if path == Bundle.main.bundleURL.path {
                    let bundledIcon = URL(fileURLWithPath: path)
                        .appendingPathComponent("Contents/Resources/AppIcon.icns")
                    icon = NSImage(contentsOf: bundledIcon)
                } else {
                    icon = NSWorkspace.shared.icon(forFile: path)
                }
            }
    }
}
