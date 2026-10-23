import SwiftUI

/// v2.9.128：清理中心（对齐 Fuck 工具箱清理类能力 + AI 清理亮点）
/// v2.9.144：复用 AppBrowserContainer（分类标签+搜索+App图标+A-Z索引），
/// 默认只显示"用户"分类——系统 App 不再默认统计出来（可手动切"系统"tab 查看）。
struct CleanupCenterView: View {
    // v2.9.144：NavigationView(iOS16) 不支持 navigationDestination，改 sheet 弹出详情
    @State private var selected: AppCatalog.AppEntry?
    @State private var showCleanup = false

    var body: some View {
        AppBrowserContainer(
            title: L10n.t("i18n_219"),
            subtitle: L10n.t("i18n_672"),
            icon: "sparkles.rectangle.stack",
            defaultCategory: .user,
            onTap: { app in
                selected = app
                showCleanup = true
            }
        )
        .navigationTitle(L10n.t("i18n_219"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink(destination: SystemCleanupView()) {
                    Image(systemName: "externaldrive.badge.wifi")
                        .font(.subheadline)
                }
            }
        }
        .sheet(isPresented: $showCleanup) {
            if let app = selected {
                
                    AppCleanupView(bundleId: app.bundleId, name: app.name)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button(L10n.t("i18n_956")) { showCleanup = false }
                            }
                        }
            }
        }
    }
}

/// 单个 App 的清理页：扫描 → 勾选 → 执行
struct AppCleanupView: View {
    let bundleId: String
    let name: String
    @State private var items: [CleanupItem] = []
    @State private var selected = Set<String>()
    @State private var scanning = false
    @State private var running = false
    @State private var toast: String?
    @State private var scanFailed = false

    var body: some View {
        VStack(spacing: 0) {
            if items.isEmpty && !scanning {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 44))
                        .foregroundColor(.tmCyan)
                    Text(L10n.t("ui_160", name))
                        .font(.headline)
                    Text(L10n.t("ui_123"))
                        .font(.footnote).foregroundColor(.secondary)
                    Button {
                        scan()
                    } label: {
                        Label(L10n.t("i18n_673"), systemImage: "magnifyingglass")
                            .font(.headline)
                            .padding(.horizontal, 28).padding(.vertical, 10)
                            .background(Color.tmCyan)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                }
                Spacer()
            } else if scanning {
                Spacer()
                ProgressView(L10n.t("i18n_674")).font(.footnote)
                Spacer()
            } else if scanFailed {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    Text(L10n.t("ui_161", name)).font(.headline)
                    Text(L10n.t("ui_162"))
                        .font(.footnote).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button(L10n.t("i18n_503")) { scan() }
                        .font(.headline)
                        .padding(.horizontal, 24).padding(.vertical, 8)
                        .background(Color.tmCyan).foregroundColor(.white)
                        .clipShape(Capsule())
                }
                Spacer()
            } else {
                List {
                    Section(header: SettingSectionHeader(title: L10n.t("i18n_675"))) {
                        ForEach(items, id: \.id) { item in
                            HStack(spacing: 12) {
                                Image(systemName: iconName(item.risk))
                                    .font(.system(size: 18))
                                    .foregroundColor(colorFor(item.risk))
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(item.label).font(.subheadline)
                                        riskBadge(item.risk)
                                    }
                                    Text(item.detail)
                                        .font(.caption2).foregroundColor(.secondary)
                                        .lineLimit(2)
                                    Text(item.affected)
                                        .font(.caption2).foregroundColor(.orange)
                                        .lineLimit(2)
                                }
                                Spacer()
                                if item.id == "idfv" {
                                    Text(L10n.t("ui_41")).font(.caption2).foregroundColor(.secondary)
                                } else if selected.contains(item.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 22)).foregroundColor(.green)
                                } else {
                                    Image(systemName: "circle")
                                        .font(.system(size: 22)).foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                toggle(item)
                            }
                        }
                    }
                    Section {
                        Button {
                            if selected.isEmpty { toast = L10n.t("i18n_676") }
                            else { runCleanup() }
                        } label: {
                            HStack {
                                Spacer()
                                if running {
                                    ProgressView().tint(.white)
                                } else {
                                    Label(L10n.t("i18n_677", selected.count), systemImage: "trash.fill")
                                }
                                Spacer()
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.vertical, 8)
                        }
                        .listRowBackground(Color.red)
                        .disabled(running)
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { scan() }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !items.isEmpty {
                    Button(L10n.t("i18n_678")) { scan() }
                } else {
                    EmptyView()
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = toast {
                Text(toast)
                    .font(.caption)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color(.systemGray5).opacity(0.95))
                    .clipShape(Capsule())
                    .padding(.bottom, 16)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                            withAnimation { self.toast = nil }
                        }
                    }
            } else {
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
    }

    private func scan() {
        scanning = true
        scanFailed = false
        DispatchQueue.global().async {
            let result = CleanupScanner.scan(bundleId: bundleId)
            DispatchQueue.main.async {
                items = result
                scanning = false
                if result.isEmpty {
                    scanFailed = true
                    toast = L10n.t("i18n_679")
                } else {
                    selected = Set(result.filter { $0.risk == .safe && $0.id != "idfv" }.map { $0.id })
                    toast = L10n.t("i18n_680", result.count)
                }
            }
        }
    }

    private func toggle(_ item: CleanupItem) {
        guard item.id != "idfv" else {
            toast = L10n.t("i18n_681")
            return
        }
        if item.risk == .danger {
            if selected.contains(item.id) { selected.remove(item.id) }
            else {
                selected.insert(item.id)
                toast = L10n.t("i18n_682")
            }
            return
        }
        if selected.contains(item.id) { selected.remove(item.id) }
        else { selected.insert(item.id) }
    }

    private func runCleanup() {
        running = true
        let ids = Array(selected)
        DispatchQueue.global().async {
            let results = CleanupScanner.execute(bundleId: bundleId, itemIds: ids)
            DispatchQueue.main.async {
                running = false
                let failed = results.filter { ($0["ok"] as? Bool) != true }.count
                let okCount = results.count - failed
                toast = L10n.t("i18n_683", okCount, failed)
                // 刷新状态
                let fresh = CleanupScanner.scan(bundleId: bundleId)
                items = fresh
                selected = Set(fresh.filter { $0.risk == .safe && $0.id != "idfv" }.map { $0.id })
            }
        }
    }

    private func riskBadge(_ risk: CleanupItem.Risk) -> some View {
        Text(risk == .safe ? L10n.t("i18n_684") : (risk == .warn ? L10n.t("i18n_685") : L10n.t("i18n_686")))
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(colorFor(risk).opacity(0.15))
            .foregroundColor(colorFor(risk))
            .clipShape(Capsule())
    }

    private func colorFor(_ risk: CleanupItem.Risk) -> Color {
        switch risk {
        case .safe: return .green
        case .warn: return .orange
        case .danger: return .red
        case .error: return .gray
        }
    }

    private func iconName(_ risk: CleanupItem.Risk) -> String {
        switch risk {
        case .safe: return "checkmark.shield"
        case .warn: return "exclamationmark.triangle"
        case .danger: return "trash"
        case .error: return "xmark.octagon"
        }
    }
}
