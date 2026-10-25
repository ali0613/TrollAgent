// MCPManagerView.swift — v7.1.75 MCP 服务器管理页
// 添加/启用/移除外部 MCP 服务器（Streamable HTTP）。添加即连接并注册工具进 ToolRegistry，
// AI 即可发现调用（工具名 user.mcp_<server>_<tool>）。

import SwiftUI

struct MCPManagerView: View {
    @ObservedObject private var mcp = MCPClientManager.shared
    @State private var showAdd = false
    @State private var newName = ""
    @State private var newURL = ""
    @State private var errorText: String?

    var body: some View {
        List {
            Section(header: Text(L10n.t("mcp_hint")).font(.caption)) {
                if mcp.servers.isEmpty {
                    Text(L10n.t("mcp_empty"))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(mcp.servers) { server in
                        serverRow(server)
                    }
                }
            }
            Section {
                Button {
                    showAdd = true
                } label: {
                    Label(L10n.t("mcp_add"), systemImage: "plus.circle.fill")
                }
            }
            if let err = mcp.lastError {
                Section {
                    Text(err)
                        .foregroundColor(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle(L10n.t("mcp_servers"))
        .alert("MCP", isPresented: $showAdd) {
            TextField(L10n.t("mcp_name"), text: $newName)
                .autocapitalization(.none)
            TextField(L10n.t("mcp_url"), text: $newURL)
                .keyboardType(.URL)
                .autocapitalization(.none)
            Button(L10n.t("mcp_confirm")) {
                let ok = mcp.addServer(name: newName, url: newURL)
                if !ok, let err = mcp.lastError {
                    errorText = err
                }
                newName = ""
                newURL = ""
            }
            Button(L10n.t("mcp_cancel"), role: .cancel) {}
        }
        .alert("MCP", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private func serverRow(_ server: MCPServerConfig) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(.body)
                Text("\(L10n.t("mcp_tools", server.toolCount)) · \(server.url)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { mcp.servers.first(where: { $0.id == server.id })?.enabled ?? false },
                set: { on in mcp.setEnabled(server, enabled: on) }
            ))
            .labelsHidden()
        }
        .swipeActions {
            Button(L10n.t("mcp_refresh")) { refresh(server) }
                .tint(.blue)
            Button(L10n.t("mcp_remove"), role: .destructive) {
                mcp.removeServer(server)
            }
            .tint(.red)
        }
    }

    private func refresh(_ server: MCPServerConfig) {
        if let idx = mcp.servers.firstIndex(where: { $0.id == server.id }) {
            var c = mcp.servers[idx]
            _ = mcp.refreshServer(&c)
            mcp.servers[idx] = c
        }
    }
}
