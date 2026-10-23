import SwiftUI

/// v2.9.181：远程终端配置页
/// TrollAgent 自身开公网 HTTP API（监听 0.0.0.0:8790），
/// N1 公网端口转发到手机局域网 IP 后，云端 AI 可直接读取/调用/审计。
struct RemoteTerminalView: View {
    @State private var token: String = RemoteTerminalServer.shared.token
    @State private var portText: String = "\(RemoteTerminalServer.shared.port)"
    @State private var allowDangerous = RemoteTerminalServer.shared.allowDangerous
    @State private var running = RemoteTerminalServer.shared.isRunning
    @State private var toast: String?
    @State private var lanIP = Self.localIPAddress()

    var body: some View {
        Form {
            Section(header: Text(L10n.t("i18n_288")), footer: Text(running ? L10n.t("i18n_289", portText) : L10n.t("i18n_290", portText))) {
                Toggle(L10n.t("i18n_607"), isOn: $running)
                    .onChange(of: running) { on in
                        if on {
                            RemoteTerminalServer.shared.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
                            RemoteTerminalServer.shared.port = Int(portText) ?? 8790
                            RemoteTerminalServer.shared.allowDangerous = allowDangerous
                            let ok = RemoteTerminalServer.shared.start()
                            toast = ok ? L10n.t("i18n_292", RemoteTerminalServer.shared.port) : L10n.t("i18n_293")
                        } else {
                            RemoteTerminalServer.shared.stop()
                            toast = L10n.t("i18n_518")
                        }
                    }
                TextField(L10n.t("i18n_295"), text: $token)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField(L10n.t("i18n_296"), text: $portText)
                    .keyboardType(.numberPad)
            }

            Section(header: Text(L10n.t("i18n_297"))) {
                HStack {
                    Text(L10n.t("i18n_298"))
                    Spacer()
                    Text(lanIP.isEmpty ? L10n.t("i18n_299") : lanIP)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text(L10n.t("i18n_300"))
                    Spacer()
                    Text("http://\(lanIP):\(portText)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Button(L10n.t("i18n_301")) {
                    UIPasteboard.general.string = "http://\(lanIP):\(portText)"
                    toast = L10n.t("i18n_1197")
                }
            }

            Section(header: Text(L10n.t("i18n_302"))) {   // v6.1.5-14ax：教程型灰色介绍已移除
                Label(L10n.t("i18n_303"), systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text(L10n.t("i18n_304")), footer: Text(L10n.t("i18n_305"))) {
                Toggle(L10n.t("i18n_306"), isOn: $allowDangerous)
                    .tint(.red)
                    .onChange(of: allowDangerous) { v in
                        RemoteTerminalServer.shared.allowDangerous = v
                    }
            }

            if let toast = toast {
                Section { Text(toast).font(.caption).foregroundColor(.secondary) }
            }
        }
        .navigationTitle(L10n.t("i18n_307"))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            // 保存
            RemoteTerminalServer.shared.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
            RemoteTerminalServer.shared.port = Int(portText) ?? 8790
            RemoteTerminalServer.shared.allowDangerous = allowDangerous
        }
    }

    static func localIPAddress() -> String {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return "" }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee
            if (flags & IFF_UP) == 0 || (flags & IFF_LOOPBACK) != 0 { continue }
            if addr.sa_family != UInt8(AF_INET) { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            if name.hasPrefix("en") {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    address = String(cString: host)
                    break
                }
            }
        }
        freeifaddrs(ifaddr)
        return address ?? ""
    }
}
