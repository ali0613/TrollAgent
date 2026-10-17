import SwiftUI

// MARK: - 工具中心（给用户看的分层工具总览）
// v6.1.5-14bm：按执行环境分三层（iOS 系统 / 原生 / Alpine），数据来自真实注册表。

enum ToolLayer: String, CaseIterable {
    case ios = "iOS 系统工具"
    case native = "原生工具"
    case alpine = "Alpine 工具"

    var subtitle: String {
        switch self {
        case .ios: return "直接操作 iPhone：启停 App、注入、UI 自动化、容器、定位"
        case .native: return "App 内执行：网络、文件、OCR、宏、构建、知识库"
        case .alpine: return "Linux 沙箱：装包、解包、编译、复杂脚本"
        }
    }

    /// 按工具名前缀/白名单映射到层（可跨层：shell.exec 含 iOS 原生命令 + Alpine 命令两个分支）
    static func layers(for def: ToolDefinition) -> [ToolLayer] {
        let n = def.name
        // 跨层命令工具：shell.exec runtime=auto 路由——纯文件/系统/网络→iOS 原生命令；
        // 装包/解包/编译/复杂脚本→Alpine。两层的命令工具都列出来。
        if n == "shell.exec" {
            return [.native, .alpine]
        }
        if n == "env.setup_re" {
            return [.alpine]
        }
        // iOS 系统层：直接操作设备/已装 App
        let iosPrefixes = ["app", "inject", "control.", "container.", "device.", "location.",
                           "memory", "process.", "scan.", "contacts.", "reminder", "calendar",
                           "phone", "bind.", "browser.", "diagnose.", "ssh"]
        if iosPrefixes.contains(where: { n == $0 || n.hasPrefix($0) }) {
            return [.ios]
        }
        return [.native]
    }
}

/// 工具中心一行（工具 + 可选命令分支标注）
struct ToolRowItem: Identifiable {
    let def: ToolDefinition
    let branch: String?
    var id: String { def.name }
}

struct ToolCenterView: View {
    @ObservedObject private var registry = ToolRegistry.shared
    @Environment(\.presentationMode) private var presentationMode

    private var grouped: [(layer: ToolLayer, rows: [ToolRowItem])] {
        var result: [(layer: ToolLayer, rows: [ToolRowItem])] = []
        for layer in ToolLayer.allCases {
            var rows: [ToolRowItem] = []
            for def in registry.definitions.sorted(by: { $0.name < $1.name }) {
                guard ToolLayer.layers(for: def).contains(layer) else { continue }
                var branch: String? = nil
                if def.name == "shell.exec" {
                    branch = (layer == .native) ? "iOS 原生命令" : "Alpine Linux 命令"
                }
                rows.append(ToolRowItem(def: def, branch: branch))
            }
            if !rows.isEmpty {
                result.append((layer, rows))
            }
        }
        return result
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("工具按执行环境分三层")
                            .font(.headline)
                        Text("iOS 系统层直接操作 iPhone；原生层在 App 内执行；Alpine 层跑 Linux 工具链（装包/编译）。shell.exec 自动路由到合适环境。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                ForEach(grouped, id: \.layer.rawValue) { item in
                    Section(header: VStack(alignment: .leading, spacing: 2) {
                        Text(item.layer.rawValue)
                            .font(.system(size: 15, weight: .bold))
                        Text(item.layer.subtitle)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }) {
                        ForEach(item.rows) { row in
                            ToolRow(def: row.def, branch: row.branch)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("工具中心")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

private struct ToolRow: View {
    let def: ToolDefinition
    var branch: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(def.name)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                if let branch = branch {
                    Text(branch)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.green.opacity(0.15))
                        .foregroundColor(.green)
                        .clipShape(Capsule())
                }
                if def.verified {
                    Text("✅")
                        .font(.system(size: 11))
                }
                if def.requiresTrollStore {
                    badge("TrollStore", .purple)
                }
                if def.requiresJailbreak {
                    badge("越狱", .orange)
                }
            }
            if def.displaySummary.count > 0 {
                Text(def.displaySummary)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}
