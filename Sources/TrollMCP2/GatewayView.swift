import SwiftUI

struct GatewayView: View {
    @ObservedObject private var gateway = GatewayClient.shared
    @State private var urlInput = ""

    var body: some View {
        CompatNav {
            Form {
                Section(header: Text(L10n.t("ui_97"))) {
                    TextField("WebSocket URL", text: $urlInput)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                    HStack {
                        Button(gateway.isConnected ? L10n.t("i18n_238") : L10n.t("i18n_239")) {
                            if gateway.isConnected {
                                gateway.disconnect()
                            } else {
                                gateway.connect(url: urlInput)
                            }
                        }
                        .disabled(urlInput.isEmpty && !gateway.isConnected)
                    }
                }
                Section(header: Text(L10n.t("ui_110"))) {
                    LabeledRow(label: L10n.t("i18n_239"), value: gateway.isConnected ? L10n.t("i18n_240") : L10n.t("i18n_241"))
                    LabeledRow(label: "URL", value: gateway.serverURL.isEmpty ? L10n.t("i18n_242") : gateway.serverURL)
                    if let err = gateway.lastError {
                        LabeledRow(label: L10n.t("i18n_243"), value: err)
                    }
                }
                Section(header: Text(L10n.t("ui_132"))) {
                    Text(L10n.t("ui_6"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(L10n.t("i18n_244"))
            .onAppear { urlInput = gateway.serverURL }
        }
        .navigationViewStyle(.stack)
    }
}

struct AutomationView: View {
    var body: some View {
        CompatNav {
            List {
                Section(header: Text(L10n.t("ui_127"))) {
                    Text(L10n.t("ui_94"))
                        .foregroundColor(.secondary)
                }
                Section(header: Text(L10n.t("ui_132"))) {
                    Text(L10n.t("ui_126"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(L10n.t("home_quick_automation"))
        }
        .navigationViewStyle(.stack)
    }
}
