import SwiftUI

// MARK: - 工具中心（给用户看的分层工具总览）
// v6.1.5-14bm：按执行环境分三层（iOS 系统 / 原生 / Alpine），数据来自真实注册表。
// v6.1.5-14bo：并入原"工具权限策略"页内容——系统权限/自动化入口、搜索、仅真实实现过滤、
//              ★常驻核心 + 真实/占位 徽标，设置页删掉重复入口（工具中心为唯一主入口）。

enum ToolLayer: String, CaseIterable {
    // v6.6.0-fix33: 三层重构——封装工具（MCP）/ 原生工具（iOS 芯片直跑命令）/ Alpine 工具（Linux 沙箱命令）
    case packaged = L10n.t("i18n_244")
    case native = L10n.t("i18n_245")
    case alpine = L10n.t("i18n_953")

    var subtitle: String {
        switch self {
        case .packaged: return L10n.t("i18n_246")
        case .native: return L10n.t("i18n_954")
        case .alpine: return L10n.t("i18n_955")
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
    var inSheet: Bool = true   // v7.0.4: true=sheet 呈现（显示"完成"关闭）；false=导航 push（无完成，标题与外层同高）

    // v6.1.5-14bo：真实实现清单（并入原权限页）——区分"有真实实现" vs "占位/文档"
    // v6.6.0-fix33: 原生工具命令清单（shell.exec 内可用——iOS 芯片直跑）
    private let nativeCommands: [(String, String)] = [
        // iOS 系统自带
        ("sqlite3", L10n.t("i18n_958")),
        ("plutil", L10n.t("i18n_959")),
        ("ta", L10n.t("i18n_249")),
        // bin/ 内置
        ("jtool2", L10n.t("i18n_250")),
        ("py3-native", L10n.t("i18n_960")),
        ("node-native", L10n.t("i18n_251")),
        ("git.py", L10n.t("i18n_961")),
        ("nscan.py", L10n.t("i18n_252")),
        // 注入链工具（Resources/bin）
        ("ldid", L10n.t("i18n_962")),
        ("insert_dylib", L10n.t("i18n_963")),
        ("optool", L10n.t("i18n_964")),
        ("ct_bypass", L10n.t("i18n_253")),
        ("opainject", L10n.t("i18n_965")),
        ("install_name_tool", L10n.t("i18n_966")),
        ("chown", L10n.t("i18n_254")),
        ("cp", L10n.t("i18n_255")),
        ("mkdir", L10n.t("i18n_256")),
        ("mv", L10n.t("i18n_257")),
        ("rm", L10n.t("i18n_258")),
    ]

    // v6.6.0-fix33: Alpine 工具命令清单（常用——完整 busybox 全套 + apk 可装）
    private let alpineCommands: [(String, String)] = [
        ("ls/cp/mv/rm/mkdir/cat/head/tail/wc", L10n.t("i18n_259")),
        ("find/grep/sed/awk/sort/uniq/tr", L10n.t("i18n_260")),
        ("tar/unzip/gzip/xz", L10n.t("i18n_261")),
        ("ps/top/df/du/date/uname/whoami/id", L10n.t("i18n_262")),
        ("curl/wget/ping/nc/ssh", L10n.t("i18n_263")),
        ("apk", L10n.t("i18n_264")),
        ("sh/bash/python3/nodejs/gcc/make/git", L10n.t("i18n_265")),
        ("vi/nano/echo/printf", L10n.t("i18n_266")),
    ]

    private func passesFilter(_ def: ToolDefinition) -> Bool {
        // v6.6.0-fix35: 白名单删除——"真实实现"= 已注册（都有 handler）；开关改为"仅真机验证"（def.verified）
        if showOnlyReal && !def.verified { return false }
        if searchText.isEmpty { return true }
        return def.name.localizedCaseInsensitiveContains(searchText)
            || def.displaySummary.localizedCaseInsensitiveContains(searchText)
    }

    /// v6.6.0-fix36: 层 → 家族分组（封装层按前缀家族 = 大工具子命令；原生/Alpine 单组）
    private var grouped: [(layer: ToolLayer, families: [(name: String, rows: [ToolRowItem])])] {
        var result: [(layer: ToolLayer, families: [(name: String, rows: [ToolRowItem])])] = []
        for layer in ToolLayer.allCases {
            var families: [(name: String, rows: [ToolRowItem])] = []
            switch layer {
            case .packaged:
                // 封装工具层：按前缀家族分组（大工具 → 子命令——container.write_text 归 container 家族）
                var byFamily: [String: [ToolRowItem]] = [:]
                for def in registry.definitions.sorted(by: { $0.name < $1.name }) {
                    guard passesFilter(def) else { continue }
                    let family = def.name.contains(".") ? String(def.name.split(separator: ".").first ?? "") : def.name
                    var branch: String? = nil
                    if def.name == "shell.exec" {
                        branch = L10n.t("i18n_268")
                    }
                    byFamily[family, default: []].append(ToolRowItem(def: def, branch: branch, isReal: true))
                }
                for name in byFamily.keys.sorted() {
                    families.append((name, byFamily[name] ?? []))
                }
            case .native:
                var nativeRows: [ToolRowItem] = []
                for (cmd, desc) in nativeCommands {
                    if !searchText.isEmpty && !cmd.localizedCaseInsensitiveContains(searchText) && !desc.localizedCaseInsensitiveContains(searchText) { continue }
                    nativeRows.append(ToolRowItem(def: ToolDefinition(name: cmd, summary: desc), branch: nil))
                }
                if !nativeRows.isEmpty { families.append((L10n.t("i18n_269"), nativeRows)) }
            case .alpine:
                var alpineRows: [ToolRowItem] = []
                for (cmd, desc) in alpineCommands {
                    if !searchText.isEmpty && !cmd.localizedCaseInsensitiveContains(searchText) && !desc.localizedCaseInsensitiveContains(searchText) { continue }
                    alpineRows.append(ToolRowItem(def: ToolDefinition(name: cmd, summary: desc), branch: nil))
                }
                if !alpineRows.isEmpty { families.append((L10n.t("i18n_967"), alpineRows)) }
            }
            if !families.isEmpty {
                result.append((layer, families))
            }
        }
        return result
    }

    @ViewBuilder private var toolList: some View {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.t("i18n_270"))
                            .font(.headline)
                        Text(L10n.t("i18n_271"))
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
                                Text(L10n.t("i18n_968"))
                                    .foregroundColor(.primary)
                                Text(L10n.t("i18n_366"))
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
                                Text(L10n.t("i18n_969"))
                                    .foregroundColor(.primary)
                                Text(L10n.t("i18n_367"))
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
                        TextField(L10n.t("i18n_365"), text: $searchText)
                            .font(.subheadline)
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    Toggle(L10n.t("i18n_314"), isOn: $showOnlyReal)
                        .accentColor(.tmCyan)
                }

                ForEach(grouped, id: \.layer.rawValue) { item in
                    Section(header: VStack(alignment: .leading, spacing: 2) {
                        Text("\(item.layer.rawValue)（\(item.families.reduce(0) { $0 + $1.rows.count })）")
                            .font(.system(size: 15, weight: .bold))
                        Text(item.layer.subtitle)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }) {
                        // v6.6.0-fix36: 大工具家族子 Section（container.write_text 归 container 家族）
                        ForEach(item.families, id: \.name) { family in
                            Section(header: Text(family.name)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.tmCyan)) {
                                ForEach(family.rows) { row in
                                    ToolRow(def: row.def, branch: row.branch, isCore: registry.isCore(row.def.name), isReal: row.isReal)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
    }

    var body: some View {
        if inSheet {
            NavigationView { toolList }
                .navigationTitle(L10n.t("i18n_275", registry.toolCount))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(L10n.t("i18n_956")) { presentationMode.wrappedValue.dismiss() }
                    }
                }
                .navigationViewStyle(.stack)
        } else {
            // v7.0.4: 导航 push——无内层 NavigationView（标题与外层"设置"导航栏同高），无"完成"按钮（返回按钮足够）
            toolList
                .navigationTitle(L10n.t("i18n_275", registry.toolCount))
                .navigationBarTitleDisplayMode(.inline)
        }
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
                    badge(L10n.t("i18n_313"), .orange)
                }
                if def.verified {
                    Text("✅")
                        .font(.system(size: 11))
                }
                if def.requiresTrollStore {
                    badge("TrollStore", .purple)
                }
                if def.requiresJailbreak {
                    badge(L10n.t("i18n_312"), .orange)
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
