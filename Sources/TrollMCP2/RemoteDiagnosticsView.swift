import SwiftUI

/// v2.9.180：远程诊断配置页
/// 配置服务器地址 + token + 开关；崩溃自动上报 + 云端指令测试统一走这里。
struct RemoteDiagnosticsView: View {
    @ObservedObject var agent = RemoteAgent.shared
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                Toggle(L10n.t("i18n_699"), isOn: $agent.enabled)
                    .onChange(of: agent.enabled) { _ in agent.save() }
                TextField(L10n.t("i18n_700"), text: $agent.serverURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: agent.serverURL) { _ in agent.save() }
                TextField(L10n.t("i18n_701"), text: $agent.token)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: agent.token) { _ in agent.save() }
            }

            Section(header: Text(L10n.t("i18n_702"))) {
                HStack {
                    Text(L10n.t("i18n_979"))
                    Spacer()
                    Text(agent.deviceID)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                Button(L10n.t("i18n_703")) {
                    UIPasteboard.general.string = agent.deviceID
                    testResult = L10n.t("i18n_1033")
                }
            }

            Section {
                Button(testing ? L10n.t("i18n_704") : L10n.t("i18n_705")) {
                    testConnection()
                }
                .disabled(testing || agent.serverURL.isEmpty || agent.token.isEmpty)
                if let testResult = testResult {
                    Text(testResult)
                        .font(.caption)
                        .foregroundColor(testResult.hasPrefix(L10n.t("i18n_706")) || testResult == L10n.t("i18n_1033") ? .green : .red)
                }
                HStack {
                    Text(L10n.t("i18n_707"))
                    Spacer()
                    Text("\(agent.executedCount)")
                        .foregroundColor(.secondary)
                }
            }

            Section(header: Text(L10n.t("i18n_708")), footer: Text(L10n.t("i18n_709"))) {
                Label(L10n.t("i18n_710"), systemImage: "checkmark.shield.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            }
        }
        .navigationTitle(L10n.t("i18n_711"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func testConnection() {
        testing = true
        testResult = nil
        agent.testConnection { ok, msg in
            DispatchQueue.main.async {
                testing = false
                testResult = msg
            }
        }
    }
}
