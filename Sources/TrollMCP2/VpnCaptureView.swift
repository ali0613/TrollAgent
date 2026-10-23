// VpnCaptureView：MITM 抓包 VPN/代理 控制页（v3.3.0）
// v6.1.5-14az：界面重构——参考主流抓包工具布局：顶部盾牌主视觉+开始/停止大按钮，
// 下方功能模块卡片（流量抓取绿/CA证书绿/抓包记录蓝，配色分级），保留本地代理与使用步骤。

import SwiftUI
import NetworkExtension

struct VpnCaptureView: View {
    @State private var vpnStatusText = "unknown"
    @State private var localProxyOn = false
    @State private var caExists = false
    @State private var logFiles: [String] = []
    @State private var notice = ""
    @State private var showLogs = false

    var body: some View {
        List {
            // 顶部主视觉：盾牌 + 状态 + 开始/停止大按钮
            Section {
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(vpnColor.opacity(0.12))
                            .frame(width: 100, height: 100)
                        Image(systemName: vpnActive ? "shield.fill" : "shield.slash.fill")
                            .font(.system(size: 46, weight: .semibold))
                            .foregroundColor(vpnColor)
                    }
                    .padding(.top, 10)

                    Button(action: { vpnActive ? stopAll() : connectVpn() }) {
                        Text(vpnActive ? L10n.t("i18n_505") : L10n.t("i18n_506"))
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Capsule().fill(vpnColor))
                    }
                    .buttonStyle(.plain)

                    Text(statusHint())
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)

            // 功能模块（配色参考主流抓包工具：绿/蓝分级）
            Section {
                // 流量抓取 = 抓包总开关（连接/断开 VPN）
                moduleCard(
                    title: L10n.t("i18n_507"),
                    icon: "arrow.down.doc.fill",
                    color: .green,
                    desc: L10n.t("i18n_508"),
                    trailing: AnyView(
                        Toggle("", isOn: Binding(
                            get: { vpnActive },
                            set: { on in on ? connectVpn() : stopAll() }))
                            .labelsHidden()
                            .tint(.green)
                    )
                )
                // CA 证书：状态 + 点击生成
                moduleCard(
                    title: L10n.t("i18n_1119"),
                    icon: "checkmark.shield.fill",
                    color: .green,
                    desc: caExists ? L10n.t("i18n_509") : L10n.t("i18n_510"),
                    trailing: AnyView(
                        Button(action: shareCert) {
                            Text(caExists ? L10n.t("i18n_511") : L10n.t("i18n_1168"))
                                .font(.subheadline)
                                .foregroundColor(caExists ? .green : .secondary)
                        }
                    )
                )
                // 抓包记录：数量 + 点击展开
                moduleCard(
                    title: L10n.t("i18n_513"),
                    icon: "doc.text.fill",
                    color: .blue,
                    desc: L10n.t("i18n_1120"),
                    trailing: AnyView(
                        Button(action: { showLogs = true }) {
                            HStack(spacing: 4) {
                                Text(L10n.t("i18n_514", logFiles.count))
                                    .font(.subheadline)
                                    .foregroundColor(logFiles.isEmpty ? .secondary : .blue)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    )
                )
            }

            // 本地代理（WiFi 手动代理备选）
            Section {
                Button(action: toggleLocalProxy) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.orange.opacity(0.15))
                                .frame(width: 30, height: 30)
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.orange)
                        }
                        Text(localProxyOn ? L10n.t("i18n_515") : L10n.t("i18n_516"))
                            .foregroundColor(.primary)
                        Spacer()
                        Text(localProxyOn ? L10n.t("i18n_975") : L10n.t("i18n_518"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // 使用步骤（保留功能指引）
            Section(header: SettingSectionHeader(title: L10n.t("i18n_519"))) {
                stepRow(1, L10n.t("i18n_520"), L10n.t("i18n_521"))
                stepRow(2, L10n.t("i18n_522"), L10n.t("i18n_523"))
                stepRow(3, L10n.t("i18n_524"), L10n.t("i18n_525"))
                stepRow(4, L10n.t("i18n_438"), L10n.t("i18n_1121"))
                stepRow(5, L10n.t("i18n_526"), L10n.t("i18n_1122"))
            }

            if !notice.isEmpty {
                Section(header: SettingSectionHeader(title: L10n.t("i18n_527"))) {
                    Text(notice)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
        .navigationTitle(L10n.t("i18n_1163"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh() }
        .sheet(isPresented: $showLogs) {
            NavigationView {
                List {
                    if logFiles.isEmpty {
                        Text(L10n.t("i18n_528"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(logFiles.prefix(50), id: \.self) { f in
                            Text(f).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                .navigationTitle(L10n.t("i18n_529", logFiles.count))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.t("i18n_1180")) { showLogs = false }
                    }
                }
            }
        }
    }

    // MARK: - 组件

    /// 功能模块卡片：图标色块 + 标题 + 说明 + 右侧控件
    private func moduleCard(title: String, icon: String, color: Color, desc: String, trailing: AnyView) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(color.opacity(0.14))
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                Text(desc)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 4)
    }

    private func stepRow(_ n: Int, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.tmCyan))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Text(desc)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 状态与操作

    private var vpnColor: Color {
        switch vpnStatusText {
        case "connected": return .green
        case "connecting": return .orange
        default: return .gray
        }
    }

    /// v3.3.2：主开关状态
    private var vpnActive: Bool {
        vpnStatusText == "connected" || vpnStatusText == "connecting" || localProxyOn
    }

    private func statusHint() -> String {
        if vpnStatusText == "connected" { return L10n.t("i18n_530") }
        if vpnStatusText == "connecting" { return L10n.t("i18n_531") }
        if localProxyOn { return L10n.t("i18n_532") }
        return L10n.t("i18n_533")
    }

    private func stopAll() {
        VpnManager.shared.stopVpn()
        VpnManager.shared.stopLocalProxy()
        refresh()
    }

    private func refresh() {
        VpnManager.shared.loadPreferences { _ in
            let raw = VpnManager.shared.vpnStatus.rawValue
            switch raw {
            case 3: vpnStatusText = "connected"
            case 2: vpnStatusText = "connecting"
            default: vpnStatusText = "disconnected"
            }
        }
        localProxyOn = VpnManager.shared.localProxyRunning
        caExists = VpnManager.shared.caExists
        logFiles = ((try? FileManager.default.contentsOfDirectory(atPath: VpnManager.shared.mitmLogDir)) ?? []).sorted().reversed()
    }

    private func connectVpn() {
        // v3.5.16h：点按钮立刻给反馈，不再静默等——避免"点了没反应"的错觉
        notice = L10n.t("i18n_535")
        VpnManager.shared.startVpn { err in
            if let e = err {
                notice = L10n.t("i18n_536", e)
            } else {
                notice = L10n.t("i18n_537")
            }
            refresh()
        }
    }

    private func toggleLocalProxy() {
        if localProxyOn {
            VpnManager.shared.stopLocalProxy()
        } else {
            _ = VpnManager.shared.startLocalProxy()
            notice = L10n.t("i18n_538")
        }
        refresh()
    }

    private func shareCert() {
        guard let path = VpnManager.shared.generateMobileConfig() else {
            notice = L10n.t("i18n_539")
            return
        }
        refresh()
        // v3.3.1：用 Safari 打开本地 HTTP 下载 —— 触发系统标准"下载配置描述文件"确认框，
        // 比"存储到文件再打开"更稳（无沙箱环境下文件 App 打开 profile 不弹安装）。
        let dir = (path as NSString).deletingLastPathComponent
        _ = LocalHttpServer.shared.start(rootDir: dir)
        let url = URL(string: "http://127.0.0.1:18080/TrollAgentCA.mobileconfig")!
        UIApplication.shared.open(url, options: [:]) { ok in
            if !ok {
                notice = L10n.t("i18n_542", path)
            } else {
                notice = L10n.t("i18n_543")
            }
        }
    }
}
