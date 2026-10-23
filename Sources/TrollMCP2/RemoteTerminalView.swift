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
            Section(header: Text(L10n.t("i18n_93")), footer: Text(running ? L10n.t("i18n_94", portText) : L10n.t("i18n_95", portText))) {
                Toggle(L10n.t("i18n_398"), isOn: $running)
                    .onChange(of: running) { on in
                        if on {
                            RemoteTerminalServer.shared.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
                            RemoteTerminalServer.shared.port = Int(portText) ?? 8790
                            RemoteTerminalServer.shared.allowDangerous = allowDangerous
                            let ok = RemoteTerminalServer.shared.start()
                            toast = ok ? L10n.t("i18n_97", RemoteTerminalServer.shared.port) : L10n.t("i18n_98")
                        } else {
                            RemoteTerminalServer.shared.stop()
                            toast = L10n.t("i18n_313")
                        }
                    }
                TextField(L10n.t("i18n_100"), text: $token)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField(L10n.t("i18n_101"), text: $portText)
                    .keyboardType(.numberPad)
            }

            Section(header: Text(L10n.t("i18n_102"))) {
                HStack {
                    Text(L10n.t("i18n_103"))
                    Spacer()
                    Text(lanIP.isEmpty ? L10n.t("i18n_104") : lanIP)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text(L10n.t("i18n_105"))
                    Spacer()
                    Text("http://\(lanIP):\(portText)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Button(L10n.t("i18n_106")) {
                    UIPasteboard.general.string = "http://\(lanIP):\(portText)"
                    toast = L10n.t("relay_card_copied")
                }
            }

            Section(header: Text(L10n.t("i18n_107"))) {   // v6.1.5-14ax：教程型灰色介绍已移除
                Label(L10n.t("i18n_108"), systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text(L10n.t("i18n_109")), footer: Text(L10n.t("i18n_110"))) {
                Toggle(L10n.t("i18n_111"), isOn: $allowDangerous)
                    .tint(.red)
                    .onChange(of: allowDangerous) { v in
                        RemoteTerminalServer.shared.allowDangerous = v
                    }
            }

            if let toast = toast {
                Section { Text(toast).font(.caption).foregroundColor(.secondary) }
            }
        }
        .navigationTitle(L10n.t("i18n_112"))
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
