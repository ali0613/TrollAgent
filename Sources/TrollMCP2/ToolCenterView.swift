import SwiftUI

// MARK: - 工具中心（给用户看的分层工具总览）
// v6.1.5-14bm：按执行环境分三层（iOS 系统 / 原生 / Alpine），数据来自真实注册表。
// v6.1.5-14bo：并入原"工具权限策略"页内容——系统权限/自动化入口、搜索、仅真实实现过滤、
//              ★常驻核心 + 真实/占位 徽标，设置页删掉重复入口（工具中心为唯一主入口）。

enum ToolLayer: String, CaseIterable {
    // v6.6.0-fix33: 三层重构——封装工具（MCP）/ 原生工具（iOS 芯片直跑命令）/ Alpine 工具（Linux 沙箱命令）
    case packaged = "封装工具"
    case native = "原生工具"
    case alpine = "Alpine 工具"

    var subtitle: String {
        switch self {
        case .packaged: return "注册的大工具（ToolRegistry——AI 可直接调用的封装能力）"
        case .native: return "iOS 芯片直跑：sqlite3/plutil/jtool2/py3-native/node-native + 注入链"
        case .alpine: return "Linux 沙箱工具链：busybox 全套 + apk 可装任意工具"
        }
    }

    /// 全部 MCP 工具归"封装工具"层；原生/Alpine 层展示静态命令清单（shell.exec 内可用）
    static func layers(for def: ToolDefinition) -> [ToolLayer] {
        return [.packaged]
    }
}

/// 工具中心一行（工具 + 可选命令分支标注）
struct ToolRowItem: Identifiable {
    let def: ToolDefinition
    let branch: String?
    var isReal: Bool = true   // v6.6.0-fix33: 原生/Alpine 命令都是真实命令（不标占位）
    var id: String { def.name }
}

struct ToolCenterView: View {
    @ObservedObject private var registry = ToolRegistry.shared
    @Environment(\.presentationMode) private var presentationMode
    @State private var searchText = ""
    @State private var showOnlyReal = false  // v6.6.0-fix35: 默认显示全部注册工具（注册=有 handler——不再有"占位"概念）；开关改"仅真机验证"

    // v6.1.5-14bo：真实实现清单（并入原权限页）——区分"有真实实现" vs "占位/文档"
    // v6.6.0-fix33: 原生工具命令清单（shell.exec 内可用——iOS 芯片直跑）
    private let nativeCommands: [(String, String)] = [
        // iOS 系统自带
        ("sqlite3", "SQLite 数据库（iOS 系统自带）"),
        ("plutil", "plist 读写（iOS 系统自带）"),
        ("ta", "文件属性（iOS 系统自带）"),
        // bin/ 内置
        ("jtool2", "Mach-O 解析（签名/权限/元数据）"),
        ("py3-native", "原生 Python 3.14（芯片直跑 numpy/pandas）"),
        ("node-native", "原生 Node.js（芯片直跑重负载 JS）"),
        ("git.py", "Git 封装（纯 Python——rootfs 缺失兜底）"),
        ("nscan.py", "网络扫描脚本"),
        // 注入链工具（Resources/bin）
        ("ldid", "签名工具（伪签/entitlements）"),
        ("insert_dylib", "dylib 注入"),
        ("optool", "Mach-O 操作"),
        ("ct_bypass", "代码签名绕过"),
        ("opainject", "TrollStore 注入"),
        ("install_name_tool", "dylib 路径修改"),
        ("chown", "更改属主（iOS 系统）"),
        ("cp", "复制（iOS 系统）"),
        ("mkdir", "建目录（iOS 系统）"),
        ("mv", "移动（iOS 系统）"),
        ("rm", "删除（iOS 系统）"),
    ]

    // v6.6.0-fix33: Alpine 工具命令清单（常用——完整 busybox 全套 + apk 可装）
    private let alpineCommands: [(String, String)] = [
        ("ls/cp/mv/rm/mkdir/cat/head/tail/wc", "文件操作"),
        ("find/grep/sed/awk/sort/uniq/tr", "文本处理"),
        ("tar/unzip/gzip/xz", "压缩解压"),
        ("ps/top/df/du/date/uname/whoami/id", "系统信息"),
        ("curl/wget/ping/nc/ssh", "网络"),
        ("apk", "装任意工具（apk add <包名>）"),
        ("sh/bash/python3/nodejs/gcc/make/git", "编程环境"),
        ("vi/nano/echo/printf", "文本编辑/输出"),
    ]

    private func passesFilter(_ def: ToolDefinition) -> Bool {
        // v6.6.0-fix35: 白名单删除——"真实实现"= 已注册（都有 handler）；开关改为"仅真机验证"（def.verified）
        if showOnlyReal && !def.verified { return false }
        if searchText.isEmpty { return true }
        return def.name.localizedCaseInsensitiveContains(searchText)
            || def.displaySummary.localizedCaseInsensitiveContains(searchText)
    }

    private var grouped: [(layer: ToolLayer, rows: [ToolRowItem])] {
        var result: [(layer: ToolLayer, rows: [ToolRowItem])] = []
        for layer in ToolLayer.allCases {
            var rows: [ToolRowItem] = []
            switch layer {
            case .packaged:
                // 封装工具层：平铺全部注册工具（注册 = 有 handler——无占位概念）
                for def in registry.definitions.sorted(by: { $0.name < $1.name }) {
                    guard passesFilter(def) else { continue }
                    var branch: String? = nil
                    if def.name == "shell.exec" {
                        branch = "统一环境执行（iOS 原生命令 + Alpine 工具链）"
                    }
                    rows.append(ToolRowItem(def: def, branch: branch, isReal: true))
                }
            case .native:
                // 原生工具层：静态命令清单（搜索过滤）
                for (cmd, desc) in nativeCommands {
                    if !searchText.isEmpty && !cmd.localizedCaseInsensitiveContains(searchText) && !desc.localizedCaseInsensitiveContains(searchText) { continue }
                    rows.append(ToolRowItem(def: ToolDefinition(name: cmd, summary: desc), branch: nil))
                }
            case .alpine:
                // Alpine 工具层：静态命令清单（搜索过滤）
                for (cmd, desc) in alpineCommands {
                    if !searchText.isEmpty && !cmd.localizedCaseInsensitiveContains(searchText) && !desc.localizedCaseInsensitiveContains(searchText) { continue }
                    rows.append(ToolRowItem(def: ToolDefinition(name: cmd, summary: desc), branch: nil))
                }
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
                        Text("工具分三层")
                            .font(.headline)
                        Text("封装工具 = 注册的大工具（AI 直接调用——✓ 已验证 = 真机实测过）；原生工具 = iOS 芯片直跑命令；Alpine 工具 = Linux 沙箱工具链。")
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
                    Toggle("仅真机验证", isOn: $showOnlyReal)
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
                            ToolRow(def: row.def, branch: row.branch, isCore: registry.isCore(row.def.name), isReal: row.isReal)
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
