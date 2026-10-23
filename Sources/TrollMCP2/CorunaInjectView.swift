import SwiftUI
import UIKit
import WebKit

// MARK: - Coruna Web 注入视图
// v3.0.5: 网页端一键注入 dylib 到任意 App
struct CorunaInjectView: View {
    @ObservedObject private var injector = CorunaWebInjector.shared
    @State private var availableApps: [AppCatalog.AppEntry] = []
    @State private var selectedApp: AppCatalog.AppEntry?
    @State private var availableDylibs: [String] = []
    @State private var selectedDylib: String = ""
    @State private var showAppPicker = false
    @State private var showDylibPicker = false
    @State private var showWebView = false
    @State private var isDeviceCompatible = true
    @State private var showWarning = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !isDeviceCompatible {
                    compatibilityWarning
                }
                statusCard
                configurationSection
                chainInfoSection
                actionButtons
            }
            .padding()
        }
        .navigationTitle(L10n.t("i18n_1152"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            isDeviceCompatible = CorunaWebInjector.isCompatible
            loadApps()
            loadDylibs()
        }
        .sheet(isPresented: $showAppPicker) {
            AppPickerSheet(apps: availableApps, selectedApp: $selectedApp)
        }
        .sheet(isPresented: $showDylibPicker) {
            DylibPickerSheet(dylibs: availableDylibs, selectedDylib: $selectedDylib)
        }
        .sheet(isPresented: $showWebView) {
            CorunaExploitWebView(injector: injector)
        }
        .alert(L10n.t("i18n_745"), isPresented: $showWarning) {
            Button(L10n.t("i18n_746"), role: .destructive) { startInjection() }
            Button(L10n.t("ui_40"), role: .cancel) {}
        } message: {
            Text(L10n.t("i18n_747", selectedApp?.name ?? L10n.t("i18n_1144")))
        }
    }

    // MARK: - 兼容性警告
    private var compatibilityWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(L10n.t("i18n_748"))
                    .font(.headline)
                    .foregroundColor(.orange)
            }
            Text(L10n.t("i18n_1153", CorunaWebInjector.deviceInfo))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: - 状态卡片
    private var statusCard: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: statusIcon)
                    .font(.title)
                    .foregroundColor(statusColor)
                VStack(alignment: .leading) {
                    Text(injector.currentStage.rawValue).font(.headline)
                    Text(injector.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            ProgressView(value: injector.stageProgress)
                .progressViewStyle(LinearProgressViewStyle(tint: statusColor))
            HStack {
                statusBadge(label: L10n.t("i18n_749"), active: injector.kernelRWReady)
                statusBadge(label: "Dev Mode", active: injector.developerModeEnabled)
                statusBadge(label: "PAC", active: injector.stageProgress >= 0.6)
                Spacer()
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }

    private var statusIcon: String {
        switch injector.currentStage {
        case .success: return "checkmark.circle.fill"
        case .failed, .crashed: return "xmark.circle.fill"
        case .ready: return "checkmark.shield.fill"
        default: return "shield.lefthalf.filled"
        }
    }

    private var statusColor: Color {
        switch injector.currentStage {
        case .success: return .green
        case .failed, .crashed: return .red
        case .ready: return .blue
        default: return .orange
        }
    }

    private func statusBadge(label: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(active ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
                .foregroundColor(active ? .green : .secondary)
        }
    }

    // MARK: - 配置区域
    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("i18n_750")).font(.headline)

            Button(action: { showAppPicker = true }) {
                HStack {
                    Image(systemName: "app.dashed").foregroundColor(.blue)
                    VStack(alignment: .leading) {
                        Text(L10n.t("i18n_1144")).font(.subheadline)
                        Text(selectedApp?.name ?? L10n.t("i18n_751"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            }

            Button(action: { showDylibPicker = true }) {
                HStack {
                    Image(systemName: "square.stack.3d.down.right").foregroundColor(.purple)
                    VStack(alignment: .leading) {
                        Text(L10n.t("i18n_1154")).font(.subheadline)
                        Text(selectedDylib.isEmpty ? L10n.t("i18n_752") : (selectedDylib as NSString).lastPathComponent)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("i18n_753")).font(.subheadline)
                Picker(L10n.t("i18n_753"), selection: $injector.selectedPlatform) {
                    ForEach(CorunaWebInjector.PlatformPath.allCases, id: \.self) { path in
                        Text(path.rawValue).tag(path)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
            }
        }
    }

    // MARK: - 漏洞链信息
    private var chainInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("i18n_754")).font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                chainStep(number: 1, title: "WebKit RCE", desc: L10n.t("i18n_1155"), active: injector.stageProgress >= 0.3)
                chainStep(number: 2, title: L10n.t("i18n_1156"), desc: L10n.t("i18n_1157"), active: injector.stageProgress >= 0.4)
                chainStep(number: 3, title: L10n.t("i18n_1158"), desc: "arm64e GOT-swap", active: injector.stageProgress >= 0.6)
                chainStep(number: 4, title: L10n.t("i18n_755"), desc: "mach_vm_allocate RWX", active: injector.stageProgress >= 0.7)
                chainStep(number: 5, title: L10n.t("i18n_749"), desc: "CVE-2023-41974 IOSurface", active: injector.stageProgress >= 0.8)
                chainStep(number: 6, title: L10n.t("i18n_1159"), desc: L10n.t("i18n_1160"), active: injector.stageProgress >= 0.9)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }

    private func chainStep(number: Int, title: String, desc: String, active: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(active ? Color.blue : Color.gray.opacity(0.3))
                    .frame(width: 24, height: 24)
                Text("\(number)").font(.caption2.bold())
                    .foregroundColor(active ? .white : .secondary)
            }
            VStack(alignment: .leading) {
                Text(title).font(.subheadline.bold())
                    .foregroundColor(active ? .primary : .secondary)
                Text(desc).font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            if active {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption)
            }
        }
    }

    // MARK: - 操作按钮
    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button(action: { showWarning = true }) {
                HStack {
                    Image(systemName: "bolt.fill")
                    Text(L10n.t("i18n_756")).font(.headline)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(canStart ? Color.blue : Color.gray)
                .cornerRadius(14)
            }
            .disabled(!canStart)

            if injector.currentStage != .idle {
                Button(action: { injector.stop() }) {
                    HStack {
                        Image(systemName: "stop.fill")
                        Text(L10n.t("i18n_504")).font(.headline)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red)
                    .cornerRadius(14)
                }
            }

            if !injector.lastError.isEmpty {
                Text(L10n.t("i18n_757", injector.lastError)).font(.caption).foregroundColor(.red)
            }

            // 控制台日志
            if !injector.consoleLog.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("i18n_758")).font(.caption.bold())
                    let recent = Array(injector.consoleLog.suffix(20))
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
            }
        }
    }

    private var canStart: Bool {
        isDeviceCompatible && selectedApp != nil && !selectedDylib.isEmpty &&
        (injector.currentStage == .idle || injector.currentStage == .failed || injector.currentStage == .crashed)
    }

    // MARK: - 数据加载
    private func loadApps() {
        DispatchQueue.global().async {
            let apps = AppCatalog.list()
            DispatchQueue.main.async { self.availableApps = apps }
        }
    }

    private func loadDylibs() {
        let docsPath = NSHomeDirectory() + "/Documents/dylibs"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: docsPath) {
            availableDylibs = files.filter { $0.hasSuffix(".dylib") || $0.hasSuffix(".deb") }
                .map { docsPath + "/" + $0 }
        }
        // 也列出内置 ControlAgent.dylib
        let bundled = Bundle.main.bundleURL.appendingPathComponent("bin/ControlAgent.dylib").path
        if FileManager.default.fileExists(atPath: bundled) && !availableDylibs.contains(bundled) {
            availableDylibs.insert(bundled, at: 0)
        }
    }

    private func startInjection() {
        guard let app = selectedApp else { return }
        showWebView = true
    }
}

// MARK: - App 选择器
struct AppPickerSheet: View {
    let apps: [AppCatalog.AppEntry]
    @Binding var selectedApp: AppCatalog.AppEntry?
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            List(apps) { app in
                Button(action: {
                    selectedApp = app
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack {
                        Image(systemName: "app").foregroundColor(.blue)
                        VStack(alignment: .leading) {
                            Text(app.name).foregroundColor(.primary)
                            Text(app.bundleId).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if selectedApp?.bundleId == app.bundleId {
                            Image(systemName: "checkmark").foregroundColor(.blue)
                        }
                    }
                }
            }
            .navigationTitle(L10n.t("i18n_759"))
            .navigationBarItems(trailing: Button(L10n.t("ui_177")) {
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}

// MARK: - Dylib 选择器
struct DylibPickerSheet: View {
    let dylibs: [String]
    @Binding var selectedDylib: String
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            List(dylibs, id: \.self) { dylib in
                Button(action: {
                    selectedDylib = dylib
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack {
                        Image(systemName: "square.stack.3d").foregroundColor(.purple)
                        Text((dylib as NSString).lastPathComponent).foregroundColor(.primary)
                        Spacer()
                        if selectedDylib == dylib {
                            Image(systemName: "checkmark").foregroundColor(.blue)
                        }
                    }
                }
            }
            .navigationTitle(L10n.t("i18n_1161"))
            .navigationBarItems(trailing: Button(L10n.t("ui_177")) {
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}

// MARK: - Exploit WebView 容器（真正承载 WKWebView 的 UIViewRepresentable）
struct CorunaExploitWebView: UIViewControllerRepresentable {
    let injector: CorunaWebInjector

    func makeUIViewController(context: Context) -> CorunaWebViewController {
        let vc = CorunaWebViewController()
        vc.injector = injector
        return vc
    }

    func updateUIViewController(_ uiViewController: CorunaWebViewController, context: Context) {
        // startInjection 已设置 targetBundleID/selectedDylibPath
        uiViewController.startIfNeeded()
    }
}

class CorunaWebViewController: UIViewController, WKNavigationDelegate, WKScriptMessageHandler {
    var injector: CorunaWebInjector?
    var webView: WKWebView?
    private var didStart = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let ucc = WKUserContentController()
        ucc.add(self, name: "corunaCallback")
        config.userContentController = ucc

        let wv = WKWebView(frame: view.bounds, configuration: config)
        wv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        wv.navigationDelegate = self
        // Safari UA 伪装
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.3 Mobile/15E148 Safari/604.1"
        view.addSubview(wv)
        webView = wv

        // 关闭按钮
        let closeBtn = UIButton(type: .close)
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeBtn)
        NSLayoutConstraint.activate([
            closeBtn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8)
        ])
    }

    func startIfNeeded() {
        guard !didStart, let wv = webView, let inj = injector else { return }
        didStart = true
        inj.startExploit(in: wv, targetApp: inj.targetBundleID, dylibPath: inj.selectedDylibPath)
    }

    @objc private func closeTapped() {
        injector?.stop()
        dismiss(animated: true)
    }

    // WKScriptMessageHandler
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        injector?.userContentController(userContentController, didReceive: message)
    }

    // WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        injector?.appendLog(L10n.t("i18n_760"))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        injector?.appendLog(L10n.t("i18n_761", error.localizedDescription))
    }
}
