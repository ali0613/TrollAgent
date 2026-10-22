import SwiftUI

// MARK: - 工具中心（给用户看的分层工具总览）
// v6.1.5-14bm：按执行环境分三层（iOS 系统 / 原生 / Alpine），数据来自真实注册表。
// v6.1.5-14bo：并入原"工具权限策略"页内容——系统权限/自动化入口、搜索、仅真实实现过滤、
//              ★常驻核心 + 真实/占位 徽标，设置页删掉重复入口（工具中心为唯一主入口）。

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
        // v6.6.0: shell.exec 统一环境（TrollRuntime/Alpine 完整工具链 + iOS 原生兜底）——不再有 runtime 路由。
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
    @State private var searchText = ""
    @State private var showOnlyReal = false

    // v6.1.5-14bo：真实实现清单（并入原权限页）——区分"有真实实现" vs "占位/文档"
    private let realTools: Set<String> = [
        "ping", "device.info", "device.probe",
        "artifact.read_text", "artifact.write_text", "artifact.list", "workspace.info",
        "assistant.memory_set", "assistant.memory_list", "assistant.memory_delete",
        "apps.cache_inspect", "apps.cache_clear", "apps.open", "apps.open_and_input",
        "wechat.prepare_message", "container.write_text", "container.delete",
        "contacts.search", "calendar.list", "reminder.create", "location.get",
        "notification.send", "scan.qr", "process.list",
        "build.runner.token", "project.generate_tweak",
        "model.config", "model.authentication", "model.selectedProfileID",
        "injection.enable", "injection.disable", "injection.status",
        "injection.inspect", "injection.list", "injection.remove",
        "skills.list", "skills.read", "skills.set_enabled"
    ]

    private func passesFilter(_ def: ToolDefinition) -> Bool {
        if showOnlyReal && !realTools.contains(def.name) { return false }
        if searchText.isEmpty { return true }
        return def.name.localizedCaseInsensitiveContains(searchText)
            || def.displaySummary.localizedCaseInsensitiveContains(searchText)
    }

    private var grouped: [(layer: ToolLayer, rows: [ToolRowItem])] {
        var result: [(layer: ToolLayer, rows: [ToolRowItem])] = []
        for layer in ToolLayer.allCases {
            var rows: [ToolRowItem] = []
            for def in registry.definitions.sorted(by: { $0.name < $1.name }) {
                guard ToolLayer.layers(for: def).contains(layer) else { continue }
                guard passesFilter(def) else { continue }
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
                        Text("统一环境（TrollRuntime）：iOS 原生能力 + Alpine Linux 完整工具链，shell.exec 统一执行——iOS 路径自动 bind 直读直写，无需选择环境。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                // v6.1.5-14bo：并入权限页入口（系统权限 / 自动化）
                Section {
                    NavigationLink(destination: SystemCapabilitiesView()) {
                        HStack(spacing: 12) {
                            Image(systemName: "hand.raised.fill")
                                .foregroundColor(.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("系统权限")
                                    .foregroundColor(.primary)
                                Text("通知/位置/通讯录/日历/快捷指令")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    NavigationLink(destination: AutomationCenterView()) {
                        HStack(spacing: 12) {
                            Image(systemName: "bolt.fill")
                                .foregroundColor(.yellow)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("自动化")
                                    .foregroundColor(.primary)
                                Text("任务 · 历史 · 重试")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // v6.1.5-14bo：搜索 + 过滤（并入权限页）
                Section {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                            .font(.system(size: 14))
                        TextField("搜索工具...", text: $searchText)
                            .font(.subheadline)
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    Toggle("仅显示真实实现", isOn: $showOnlyReal)
                        .accentColor(.tmCyan)
                }

                ForEach(grouped, id: \.layer.rawValue) { item in
                    Section(header: VStack(alignment: .leading, spacing: 2) {
                        Text("\(item.layer.rawValue)（\(item.rows.count)）")
                            .font(.system(size: 15, weight: .bold))
                        Text(item.layer.subtitle)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }) {
                        ForEach(item.rows) { row in
                            ToolRow(def: row.def, branch: row.branch, isCore: registry.isCore(row.def.name), isReal: realTools.contains(row.def.name))
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("工具中心（\(registry.toolCount)）")
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
    var isCore: Bool = false
    var isReal: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if isCore {
                    Text("★")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.blue)
                }
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
                if !isReal {
                    badge("占位", .orange)
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
