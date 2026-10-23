import SwiftUI

// v2.9.128：Fuck 工具箱风格应用浏览器
// 分类标签（全部/用户/巨魔/系统/运行中）+ 搜索 + 类型胶囊 + 版本号 + 右侧 A-Z 索引
// 复用于：应用选择（AppPickerView）、注入与自动化（InjectionView）

enum AppCategory: String, CaseIterable {
    case all = L10n.t("i18n_808")
    case user = L10n.t("i18n_809")
    case troll = L10n.t("i18n_810")
    case running = L10n.t("i18n_811")
}

struct AppBrowserList: View {
    let apps: [AppCatalog.AppEntry]
    let runningIds: Set<String>
    var onTap: (AppCatalog.AppEntry) -> Void
    var defaultCategory: AppCategory = .all

    @State private var category: AppCategory = .all
    @State private var searchText = ""

    private var filtered: [AppCatalog.AppEntry] {
        var list = apps
        switch category {
        case .all: break
        case .user: list = apps.filter { $0.isUser && !$0.isTroll }
        case .troll: list = apps.filter { $0.isTroll }
        case .running: list = apps.filter { runningIds.contains(String($0.execName.prefix(16))) }
        }
        if !searchText.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.bundleId.localizedCaseInsensitiveContains(searchText)
            }
        }
        return list
    }

    /// 按首字母分组（A-Z/#），用于右侧索引滚动
    private var grouped: [(key: String, apps: [AppCatalog.AppEntry])] {
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        var map: [String: [AppCatalog.AppEntry]] = [:]
        for app in filtered {
            let first = app.name.first.map { String($0).uppercased() } ?? "#"
            let key = letters.contains(first) ? first : "#"
            map[key, default: []].append(app)
        }
        // # 排最后，其余按字母序
        return map.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }.map { ($0, map[$0]!) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            categoryBar

            GeometryReader { _ in
                ScrollViewReader { proxy in
                    HStack(spacing: 0) {
                        List {
                            ForEach(grouped, id: \.key) { group in
                                Section {
                                    ForEach(group.apps) { app in
                                        row(app)
                                    }
                                } header: {
                                    Text(group.key)
                                        .font(.caption).fontWeight(.semibold)
                                        .foregroundColor(.secondary)
                                }
                                .id(group.key)   // 供右侧索引 scrollTo 命中
                            }
                        }
                        .listStyle(.plain)
                        .overlay {
                            if filtered.isEmpty {
                                VStack(spacing: 10) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 34)).foregroundColor(.secondary)
                                    Text(category == .running ? L10n.t("i18n_812") : L10n.t("i18n_813"))
                                        .font(.footnote).foregroundColor(.secondary)
                                }
                            }
                        }

                        // 右侧 A-Z 索引（点击滚动到对应分组）
                        AlphabetIndexBar { letter in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(letter, anchor: .top)
                            }
                        }
                    }
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 14))
            TextField(L10n.t("i18n_814"), text: $searchText)
                .font(.subheadline)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal, 16)
        .padding(.top, 4).padding(.bottom, 6)
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(AppCategory.allCases, id: \.self) { cat in
                    let selected = category == cat
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { category = cat }
                    } label: {
                        Text(cat.rawValue)
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(selected ? Color.tmCyan : Color(.secondarySystemBackground))
                            .foregroundColor(selected ? .white : .primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 4)
    }

    private func row(_ app: AppCatalog.AppEntry) -> some View {
        Button(action: { onTap(app) }) {
            HStack(spacing: 12) {
                AppIconView(path: app.path, app: app)
                    .frame(width: 42, height: 42)
                    .cornerRadius(10)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(app.name)
                            .font(.body)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        typeBadge(app)
                    }
                    Text(app.bundleId)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if !app.version.isEmpty {
                    Text(app.version)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func typeBadge(_ app: AppCatalog.AppEntry) -> some View {
        let (text, color): (String, Color) = {
            if app.isTroll { return (L10n.t("i18n_810"), Color.tmCyan) }
            if app.isSystem { return (L10n.t("i18n_815"), .gray) }
            return (L10n.t("i18n_809"), .blue)
        }()
        return Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.14))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}

/// 右侧 A-Z + # 索引条（Fuck 工具箱风格）
struct AlphabetIndexBar: View {
    var onSelect: (String) -> Void

    private let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ#")

    var body: some View {
        VStack(spacing: 1.5) {
            ForEach(letters, id: \.self) { ch in
                Text(String(ch))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 20, height: 12)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(String(ch)) }
            }
        }
        .padding(.vertical, 6)
        .padding(.trailing, 2)
        .background(Color(.systemBackground).opacity(0.001))
    }
}

/// v2.9.128：应用浏览器专用容器——负责刷新 + 运行中检测 + 交给 AppBrowserList
struct AppBrowserContainer: View {
    let title: String
    let subtitle: String
    var icon: String = "app.badge.fill"
    var colors: [Color] = [.tmCyan, .blue]
    var defaultCategory: AppCategory = .all
    var onTap: (AppCatalog.AppEntry) -> Void

    @State private var apps: [AppCatalog.AppEntry] = []
    @State private var runningIds = Set<String>()
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(icon: icon, title: title, subtitle: subtitle, colors: colors)
                .padding(.vertical, 8)

            if !loaded {
                Spacer()
                ProgressView(L10n.t("i18n_816"))
                Spacer()
            } else {
                // v6.0.31：UIKit 原生渲染（TrollStore 同款 UITableView），替换 SwiftUI AppBrowserList
                AppBrowserTableUIKit(apps: apps, runningIds: runningIds, onTap: onTap)
            }
        }
        .background(Color(.systemGroupedBackground))
        .onAppear { if !loaded { refresh() } }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }

    private func refresh() {
        loaded = false
        DispatchQueue.global(qos: .userInitiated).async {
            let list = AppCatalog.list()
            let running = AppCatalog.runningExecNames()
            // v6.0.30：列表显示前预热图标缓存（系统方法串行 + 文件读取并行，上限3秒）——
            // 首屏一出来图标就在缓存里，零"占位→等待→补上"
            AppCatalog.warmIcons(for: list, until: Date().addingTimeInterval(3.0))
            DispatchQueue.main.async {
                apps = list
                runningIds = running
                loaded = true
                // 剩余兜底（读包内文件）后台继续跑，个别没预热到的由 cell 重试补上
                AppCatalog.preloadIcons(for: list)
            }
        }
    }
}
