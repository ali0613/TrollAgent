import SwiftUI

// MARK: - 远程访问总览（SSH 主动连接 + 远程终端被控制）
struct RemoteAccessView: View {
    @AppStorage("ssh.host") private var sshHost: String = ""
    @State private var terminalRunning = RemoteTerminalServer.shared.isRunning

    var body: some View {
        Form {
            Section(header: Text(L10n.t("i18n_604"))) {
                NavigationLink(destination: SSHSettingsView()) {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.up.forward.circle.fill")
                            .font(.title2)
                            .foregroundColor(.tmCyan)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.t("i18n_1175"))
                                .foregroundColor(.primary)
                            Text(sshHost.isEmpty ? L10n.t("i18n_1168") : sshHost)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section(header: Text(L10n.t("i18n_606"))) {
                NavigationLink(destination: RemoteTerminalView()) {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.down.left.circle.fill")
                            .font(.title2)
                            .foregroundColor(.green)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.t("i18n_607"))
                                .foregroundColor(.primary)
                            Text(terminalRunning ? L10n.t("i18n_608", RemoteTerminalServer.shared.port) : L10n.t("i18n_609"))
                                .font(.caption)
                                .foregroundColor(terminalRunning ? .green : .secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.t("i18n_610"))
        .onAppear {
            terminalRunning = RemoteTerminalServer.shared.isRunning
        }
    }
}
