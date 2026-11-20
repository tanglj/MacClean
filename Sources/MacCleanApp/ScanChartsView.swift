import SwiftUI
import Charts
import MacCleanCore

struct ScanChartsView: View {
    let groups: [CandidateGroup]
    let selectedBytes: Int64
    @State private var expanded = true

    private var total: Int64 { groups.reduce(0) { $0 + $1.size } }
    private var selected: Int64 { selectedBytes }
    private var largest: [CandidateGroup] { Array(groups.prefix(5)) }
    private func size(_ bytes: Int64) -> String {
        FileSizeFormatter.string(fromByteCount: bytes)
    }
    private func label(_ group: CandidateGroup) -> String {
        group.directory.deletingLastPathComponent().lastPathComponent + "/" + group.title
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("目录占用前五名").font(.subheadline.bold())
                    Chart(largest) { group in
                        BarMark(
                            x: .value("文件大小", Double(group.size)),
                            y: .value("目录", group.id)
                        )
                        .foregroundStyle(.blue.gradient)
                        .cornerRadius(3)
                        .annotation(position: .trailing) {
                            Text(size(group.size)).font(.caption2).foregroundStyle(.secondary)
                        }
                        .accessibilityLabel(label(group))
                        .accessibilityValue(size(group.size))
                    }
                    .chartYScale(domain: largest.map(\.id))
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks { value in
                            AxisValueLabel {
                                if let id = value.as(String.self), let group = largest.first(where: { $0.id == id }) {
                                    Text(label(group)).lineLimit(1).truncationMode(.middle).help(group.directory.path)
                                }
                            }
                        }
                    }
                    .chartXScale(domain: 0...max(Double(largest.first?.size ?? 0), 1) * 1.35)
                    .frame(height: CGFloat(max(largest.count, 1)) * 26)
                    Text("与当前风险筛选一致；占用量按文件大小估算。").font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    Text("当前结果").font(.subheadline.bold())
                    Text(size(total)).font(.title2.bold()).monospacedDigit()
                    Text("已选 \(size(selected))").font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: Double(selected), total: max(Double(total), 1))
                        .accessibilityLabel("已选空间比例")
                    Text("已选 \(total > 0 ? Int(Double(selected) / Double(total) * 100) : 0)%")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("文件占用不等于实际可释放空间。")
                        .font(.caption2).foregroundStyle(.secondary)
                }.frame(width: 180, alignment: .leading)
            }.padding(.top, 10)
        } label: {
            Label("空间概览", systemImage: "chart.bar.xaxis").font(.headline)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24).padding(.top, 16)
    }
}
