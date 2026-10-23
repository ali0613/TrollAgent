import SwiftUI

struct InjectionView: View {
    @State private var apps: [AppCatalog.AppEntry] = []
    @State private var runningIds = Set<String>()
    @State private var selectedApp: AppCatalog.AppEntry?
    @State private var inspectResult: [String: Any]?
    // v2.9.92：紧急恢复区块
    @State private var showRescue = false
    @State private var rescueBusy = false
    @State private var rescueMessage: String?
    @State private var rescueAlert = false
    @State private var pendingRescue: String?
    // v2.9.94：扫描结果按 App 展示 + 单 App 恢复/清理
    @State private var scanFindings: [ScanFinding] = []
    @State private var pendingFinding: ScanFinding?

    /// v2.9.94：扫描结果条目（对齐 TrollFools 判定：备份/注入资产/真损坏）
    struct ScanFinding: Identifiable {
        let bundleId: String
        let name: String
        let hasBackup: Bool
        let assetCount: Int
        let modifiedCount: Int
        let damaged: Bool
        var id: String { bundleId }
    }

    var body: some View {
        VStack(spacing: 0) {
            // v2.9.77：美化头部（标题 + 副标题）
            PageHeader(
                icon: "syringe.fill",
                title: L10n.t("page_inject"),
                subtitle: L10n.t("inject_subtitle").replacingOccurrences(of: "{n}", with: "\(apps.count)"),
                colors: [.tmIndigo, .tmCyan]
            )
            .padding(.vertical, 8)

            // v2.9.92：🚑 紧急恢复（Residue 式）——注入把 App 搞坏后的第一选择
            rescueSection
                .padding(.bottom, 6)

            Group {
                if apps.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "syringe")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text(L10n.t("inject_refresh_hint"))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // v6.0.31：UIKit 原生渲染（TrollStore 同款 UITableView），替换 SwiftUI AppBrowserList
                    AppBrowserTableUIKit(apps: apps, runningIds: runningIds) { app in
                        selectedApp = app
                        inspectApp(app)
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                }
            }
            .sheet(item: $selectedApp) { app in
                AppDetailView(app: app, inspectResult: $inspectResult)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L10n.t("page_inject"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)   // v2.9.18：进入自动加载应用列表
    }

    // MARK: - v2.9.92 紧急恢复（Residue 式）
    private var rescueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showRescue.toggle() } }) {
                HStack(spacing: 8) {
                    Image(systemName: "cross.case.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.orange)
                    Text(L10n.t("ui_147"))
                        .font(.subheadline.bold())
                        .foregroundColor(.orange)
                    Spacer()
                    if rescueBusy {
                        ProgressView()
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(showRescue ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.25), lineWidth: 1))
                )
            }
            .buttonStyle(PlainButtonStyle())

            if showRescue {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        rescueButton(title: L10n.t("i18n_467"), icon: "magnifyingglass", color: .blue, action: { runRescue("scan") })
                        rescueButton(title: L10n.t("i18n_468"), icon: "arrow.uturn.backward.circle", color: .orange, action: { confirmRescue("recover_all") })
                        rescueButton(title: L10n.t("i18n_469"), icon: "sparkles", color: .red, action: { confirmRescue("cleanup") })
                    }
                    if let msg = rescueMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(msg.hasPrefix("✅") ? .green : (msg.hasPrefix("❌") ? .red : .secondary))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                    }
                    // v2.9.94：扫描结果 App 级列表——点击可单独恢复/清理（不再只能全机一锅端）
                    if !scanFindings.isEmpty {
                        VStack(spacing: 6) {
                            ForEach(scanFindings) { f in
                                Button(action: { pendingFinding = f }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: f.damaged ? "exclamationmark.triangle.fill" : (f.hasBackup ? "arrow.uturn.backward.circle.fill" : "syringe.fill"))
                                            .font(.system(size: 14))
                                            .foregroundColor(f.damaged ? .red : (f.hasBackup ? .orange : .blue))
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(f.name)
                                                .font(.caption.bold())
                                                .foregroundColor(.primary)
                                            Text(f.bundleId)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Text(badgeText(f))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Image(systemName: "ellipsis.circle")
                                            .font(.system(size: 13))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.vertical, 5)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemBackground)))
                    }
                    Text(L10n.t("ui_5"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemBackground)))
            }
        }
        .padding(.horizontal, 16)
        .alert(isPresented: $rescueAlert) {
            Alert(title: Text(L10n.t("ui_115")),
                  message: Text(pendingRescue == "recover_all"
                                ? L10n.t("i18n_470")
                                : L10n.t("i18n_471")),
                  primaryButton: .destructive(Text(L10n.t("ui_63"))) {
                      if let p = pendingRescue { runRescue(p) }
                  },
                  secondaryButton: .cancel(Text(L10n.t("ui_40"))))
        }
        // v2.9.94：单个 App 的恢复/清理操作
        .actionSheet(isPresented: .init(get: { pendingFinding != nil }, set: { if !$0 { pendingFinding = nil } })) {
            ActionSheet(
                title: Text(pendingFinding?.name ?? ""),
                message: Text(badgeText(pendingFinding)),
                buttons: [
                    .default(Text(L10n.t("ui_36"))) { if let f = pendingFinding { runSingle("restore", f) } },
                    .default(Text(L10n.t("ui_37"))) { if let f = pendingFinding { runSingle("cleanup", f) } },
                    .cancel(Text(L10n.t("ui_40")))
                ]
            )
        }
    }

    private func badgeText(_ f: ScanFinding?) -> String {
        guard let f = f else { return "" }
        var parts: [String] = []
        if f.damaged { parts.append(L10n.t("i18n_472")) }
        if f.hasBackup { parts.append(L10n.t("i18n_473")) }
        if f.assetCount > 0 { parts.append(L10n.t("i18n_474", f.assetCount)) }
        if f.modifiedCount > 0 { parts.append(L10n.t("i18n_475", f.modifiedCount)) }
        return parts.isEmpty ? f.bundleId : parts.joined(separator: " · ")
    }

    private func runSingle(_ kind: String, _ f: ScanFinding) {
        rescueBusy = true
        rescueMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let r = kind == "restore"
                    ? try InjectionRestoreTool().invoke(["bundle_id": f.bundleId])
                    : try RescueCleanupTool().invoke(["bundle_id": f.bundleId])
                DispatchQueue.main.async {
                    rescueBusy = false
                    let restored = kind == "restore"
                        && (((r["status"] as? String) == "reverted") || !((r["restored_from_backup"] as? [String]) ?? []).isEmpty)
                    if kind == "restore" {
                        rescueMessage = restored ? L10n.t("i18n_476", f.name) : "⚠️ \(f.name): \(r["hint"] ?? "restore unconfirmed")"
                    } else {
                        let cleaned = r["cleaned_count"] as? Int ?? 0
                        let errors = r["errors"] as? [String] ?? []
                        rescueMessage = errors.isEmpty ? L10n.t("i18n_477", f.name, cleaned) : L10n.t("i18n_478", f.name, cleaned, errors.count)
                    }
                    scanFindings.removeAll { $0.bundleId == f.bundleId }
                }
            } catch {
                DispatchQueue.main.async {
                    rescueBusy = false
                    rescueMessage = L10n.t("i18n_479", f.name, error.localizedDescription)
                }
            }
        }
    }

    private func rescueButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                Text(title)
                    .font(.caption.bold())
            }
            .foregroundColor(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.10)))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(rescueBusy)
    }

    private func confirmRescue(_ kind: String) {
        pendingRescue = kind
        rescueAlert = true
    }

    private func runRescue(_ kind: String) {
        rescueBusy = true
        rescueMessage = nil
        scanFindings.removeAll()
        DispatchQueue.global(qos: .userInitiated).async {
            let result: [String: Any]
            do {
                switch kind {
                case "scan": result = try RescueScanTool().invoke([:])
                case "recover_all": result = try RescueRecoverAllTool().invoke([:])
                default: result = try RescueCleanupTool().invoke([:])
                }
            } catch {
                DispatchQueue.main.async {
                    rescueMessage = L10n.t("i18n_480", error.localizedDescription)
                    rescueBusy = false
                }
                return
            }
            DispatchQueue.main.async {
                switch kind {
                case "scan":
                    let count = result["count"] as? Int ?? 0
                    // v2.9.94：解析 findings 为 App 级列表（只列硬证据条目）
                    var list: [ScanFinding] = []
                    if let findings = result["findings"] as? [[String: Any]] {
                        for item in findings {
                            guard let bid = item["bundle_id"] as? String else { continue }
                            list.append(ScanFinding(
                                bundleId: bid,
                                name: item["name"] as? String ?? bid,
                                hasBackup: (item["has_backup"] as? Bool) ?? false,
                                assetCount: (item["injected_assets"] as? [String])?.count ?? 0,
                                modifiedCount: (item["modified_machos"] as? [String])?.count ?? 0,
                                damaged: (item["damaged"] as? Bool) ?? false
                            ))
                        }
                    }
                    scanFindings = list
                    rescueMessage = L10n.t("i18n_481", count)
                case "recover_all":
                    let restored = result["restored_count"] as? Int ?? 0
                    let failed = result["failed_count"] as? Int ?? 0
                    rescueMessage = failed == 0 ? L10n.t("i18n_482", restored) : L10n.t("i18n_483", restored, failed, (result["failed"] as? String) ?? "")
                default:
                    let cleaned = result["cleaned_count"] as? Int ?? 0
                    let errors = result["errors"] as? [String] ?? []
                    rescueMessage = errors.isEmpty ? L10n.t("i18n_484", cleaned) : L10n.t("i18n_485", cleaned, errors.count, errors.joined(separator: "; "))
                }
                AuditLog.shared.log("rescue.ui", detail: "\(kind) \(rescueMessage ?? "")")
                rescueBusy = false
            }
        }
    }


    private func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = AppCatalog.list()
            let running = AppCatalog.runningExecNames()
            // v6.0.30：列表显示前预热图标缓存（系统方法串行 + 文件读取并行，与 AppBrowserContainer 一致）
            AppCatalog.warmIcons(for: list, until: Date().addingTimeInterval(3.0))
            DispatchQueue.main.async {
                apps = list
                runningIds = running
                // v6.0.30：预加载图标（刷新完成后触发；原 AppBrowserList 内 Color.clear
                // 贪婪撑高布局已移除，这里补上预加载调用）
                AppCatalog.preloadIcons(for: list)
                AuditLog.shared.log("injection.refresh", detail: "\(list.count) apps, \(running.count) running")
            }
        }
    }

    // v2.9.144：inspect 扫描 App 目录+读 Mach-O，主线程同步会卡死闪退
    private func inspectApp(_ app: AppCatalog.AppEntry) {
        inspectResult = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = InjectionManager.shared.inspect(app.bundleId)
            DispatchQueue.main.async {
                self.inspectResult = r
            }
        }
    }
}

struct AppDetailView: View {
    let app: AppCatalog.AppEntry
    @Binding var inspectResult: [String: Any]?
    @Environment(\.presentationMode) var presentationMode

    /// v2.9.21：手动注入操作反馈
    @State private var actionMessage: String?
    @State private var busy = false

    private struct DictEntry: Identifiable {
        let key: String
        let value: String
        var id: String { key }
    }

    private var entries: [DictEntry] {
        (inspectResult ?? [:]).sorted { $0.key < $1.key }
            .map { DictEntry(key: $0.key, value: "\($0.value)") }
    }

    private var injected: Bool {
        (inspectResult?["injected"] as? Bool) ?? false
    }

    var body: some View {
        
            List {
                Section(header: SettingSectionHeader(title: L10n.t("i18n_486"))) {
                    LabeledRow(label: L10n.t("i18n_919"), value: app.name)
                    LabeledRow(label: "Bundle ID", value: app.bundleId)
                    LabeledRow(label: L10n.t("i18n_948"), value: app.path)
                    if let container = AppCatalog.lookupContainer(bundleId: app.bundleId) {
                        LabeledRow(label: L10n.t("i18n_487"), value: container)
                    }
                }
                // v2.9.21：手动注入 / 移除操作区
                Section(header: SettingSectionHeader(title: L10n.t("i18n_488"))) {
                    HStack(spacing: 8) {
                        Image(systemName: injected ? "checkmark.circle.fill" : "circle.dashed")
                            .font(.system(size: 17))
                            .foregroundColor(injected ? .green : .secondary)
                        Text(injected ? L10n.t("i18n_489") : L10n.t("i18n_490"))
                            .font(.body)
                        Spacer()
                    }
                    if let msg = actionMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(msg.hasPrefix("✅") ? .green : .orange)
                    }
                    Button(action: { doInject() }) {
                        HStack(spacing: 8) {
                            if busy { ProgressView() }
                            Image(systemName: "syringe")
                            Text(L10n.t("ui_104"))
                        }
                    }
                    .disabled(busy || injected)
                    Button(action: { doRemove() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.uturn.backward")
                            Text(L10n.t("ui_118"))
                        }
                    }
                    .disabled(busy || !injected)
                    // v2.9.92：从 .troll-fools.bak 恢复备份（App 打不开时的强恢复）
                    Button(action: { doRestore() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "cross.case.fill")
                            Text(L10n.t("ui_61"))
                        }
                    }
                    .disabled(busy)
                }
                Section(header: SettingSectionHeader(title: L10n.t("i18n_491"))) {
                    ForEach(InjectionManager.shared.availableBinaries(), id: \.self) { bin in
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.green)
                                    .frame(width: 34, height: 34)
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            Text(bin)
                                .font(.body)
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                }
                if !entries.isEmpty {
                    Section(header: SettingSectionHeader(title: L10n.t("i18n_492"))) {
                        ForEach(entries) { e in
                            LabeledRow(label: e.key, value: e.value)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(app.name)
            .toolbar { Button(L10n.t("ui_177")) { presentationMode.wrappedValue.dismiss() } }
        
    }

    /// v2.9.21：手动注入
    private func doInject() {
        busy = true
        actionMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result: [String: Any]
            do {
                result = try InjectionManager.shared.enable(bundleId: app.bundleId)
            } catch {
                let msg = (error as? MCPError)?.description ?? error.localizedDescription
                DispatchQueue.main.async {
                    actionMessage = L10n.t("i18n_493", msg)
                    busy = false
                }
                return
            }
            DispatchQueue.main.async {
                let ok = (result["injected"] as? Bool) ?? false
                actionMessage = ok ? L10n.t("i18n_494") : L10n.t("i18n_495")
                inspectResult = InjectionManager.shared.inspect(app.bundleId)
                busy = false
            }
        }
    }

    /// v2.9.21：手动移除注入
    private func doRemove() {
        busy = true
        actionMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result: [String: Any]
            do {
                result = try InjectionManager.shared.remove(bundleId: app.bundleId)
            } catch {
                let msg = (error as? MCPError)?.description ?? error.localizedDescription
                DispatchQueue.main.async {
                    actionMessage = L10n.t("i18n_496", msg)
                    busy = false
                }
                return
            }
            DispatchQueue.main.async {
                let ok = ((result["injected"] as? Bool) ?? true) == false
                actionMessage = ok ? L10n.t("i18n_497") : L10n.t("i18n_498")
                inspectResult = InjectionManager.shared.inspect(app.bundleId)
                busy = false
            }
        }
    }

    /// v2.9.92：从 .troll-fools.bak 恢复备份（App 打不开时强恢复）
    private func doRestore() {
        busy = true
        actionMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result: [String: Any]
            do {
                result = try InjectionRestoreTool().invoke(["bundle_id": app.bundleId])
            } catch {
                let msg = (error as? MCPError)?.description ?? error.localizedDescription
                DispatchQueue.main.async {
                    actionMessage = L10n.t("i18n_499", msg)
                    busy = false
                }
                return
            }
            DispatchQueue.main.async {
                let restored = ((result["status"] as? String) == "reverted") || !((result["restored_from_backup"] as? [String]) ?? []).isEmpty
                actionMessage = restored ? L10n.t("i18n_500") : L10n.t("i18n_501")
                inspectResult = InjectionManager.shared.inspect(app.bundleId)
                busy = false
            }
        }
    }
}
