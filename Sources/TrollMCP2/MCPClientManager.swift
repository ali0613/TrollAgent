// MCPClientManager.swift — v7.1.75 标准 MCP 客户端（Streamable HTTP 传输）
// 让 TrollAgent 的 AI 发现并调用外部 MCP 服务器工具（如 REA：`rea mcp --http`）。
// 架构：
//   addServer(name, url) → HTTP JSON-RPC 2.0 initialize → tools/list →
//   每个工具包装成 ExternalMCPTool（工具名 user.mcp_<server>_<tool>）注册进 ToolRegistry
//   → AI 自动发现/调用（走现有工具调用链路）→ tools/call 转发回服务器
// 权限模型：用户显式添加 = 用户信任该服务器（不套用 registerExternalTool 的 AI 自写工具检查）；
//   工具名带 user.mcp_ 前缀让 AI 与内置工具区分。移除服务器即注销其全部工具。

import Foundation
import Combine

struct MCPServerConfig: Codable, Identifiable {
    var id = UUID()
    var name: String
    var url: String
    var enabled = true
    var toolCount = 0
}

/// MCP 客户端管理器（全局单例，设置页驱动）
final class MCPClientManager: ObservableObject {
    static let shared = MCPClientManager()

    @Published var servers: [MCPServerConfig] = []
    @Published var lastError: String?
    /// tools/list 缓存：服务器名 → 工具数组（入口模式下不注册，调用时动态列出）
    private var toolCache: [String: [[String: Any]]] = [:]
    /// JSON-RPC id 自增
    private var rpcId = 1
    private let key = "trollmcp2.mcp_servers"

    init() { load() }

    // MARK: - 持久化

    func save() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([MCPServerConfig].self, from: data) {
            servers = decoded
        }
    }

    // MARK: - 服务器管理

    /// 添加服务器并立即连接发现工具。成功返回 true，失败置 lastError。
    @discardableResult
    func addServer(name: String, url: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty else {
            lastError = "服务器名和 URL 不能为空"
            return false
        }
        guard URL(string: trimmedURL) != nil else {
            lastError = "URL 格式无效"
            return false
        }
        if servers.contains(where: { $0.name == trimmedName }) {
            lastError = "已存在同名服务器：\(trimmedName)"
            return false
        }
        var cfg = MCPServerConfig(name: trimmedName, url: trimmedURL)
        servers.append(cfg)
        save()
        let ok = refreshServer(&cfg)
        if let idx = servers.firstIndex(where: { $0.id == cfg.id }) { servers[idx] = cfg }
        return ok
    }

    /// 重连服务器：initialize → tools/list → 缓存工具清单（不逐工具注册——
    /// REA 等服务器 100+ 工具全进 AI schema 会 token 爆炸，改为入口工具模式：
    /// 平时 AI 只看到 user.mcp_list / user.mcp_call 两个入口，调用时动态发现）。
    @discardableResult
    func refreshServer(_ cfg: inout MCPServerConfig) -> Bool {
        // 1. initialize
        guard let initResult = rpc(url: cfg.url, method: "initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": ["tools": [:] as [String: Any]],
            "clientInfo": ["name": "TrollAgent", "version": "7.1.75"]
        ]) else { return false }
        _ = initResult["result"]
        // 2. notifications/initialized（无响应，POST 即可）
        _ = rpc(url: cfg.url, method: "notifications/initialized", params: [:])
        // 3. tools/list → 缓存
        guard let listResult = rpc(url: cfg.url, method: "tools/list", params: [:]) as? [String: Any],
              let tools = listResult["result"] as? [String: Any],
              let toolArray = tools["tools"] as? [[String: Any]] else {
            lastError = "\(cfg.name): tools/list 无结果"
            return false
        }
        toolCache[cfg.name] = toolArray
        cfg.toolCount = toolArray.count
        lastError = nil
        print("[TA] ✅ MCP server '\(cfg.name)' cached \(toolArray.count) tools (entry-mode)")
        return true
    }

    /// 移除服务器：删缓存 + 删除配置
    func removeServer(_ cfg: MCPServerConfig) {
        toolCache.removeValue(forKey: cfg.name)
        servers.removeAll { $0.id == cfg.id }
        save()
    }

    /// 启停服务器（切换 enabled 时重连/清缓存）
    func setEnabled(_ cfg: MCPServerConfig, enabled: Bool) {
        if let idx = servers.firstIndex(where: { $0.id == cfg.id }) {
            servers[idx].enabled = enabled
            save()
            if enabled {
                var c = servers[idx]
                _ = refreshServer(&c)
                servers[idx] = c
            } else {
                toolCache.removeValue(forKey: cfg.name)
            }
        }
    }

    // MARK: - 入口工具（AI 调用时动态发现）

    /// 注册两个入口工具：user.mcp_list（列出可用 MCP 工具）+ user.mcp_call（调用）。
    /// 入口模式：MCP 服务器 100+ 工具不占 AI schema，只有这两个入口常驻（token 极小），
    /// AI 需要 MCP 能力时先 list 再 call。
    func registerEntryTools() {
        // 入口 1：列出工具
        let listDef = ToolDefinition(
            name: "user.mcp_list",
            summary: "List available tools from connected MCP servers (REA etc). Call this first to discover MCP tools, then call user.mcp_call to invoke one. Optional param 'server' filters to one server.",
            parameters: ["server": "server name (optional, omit to list all)"],
            returns: ["content": "tool list: server, tool name, description, params per tool"],
            verified: true, category: "mcp",
            uiSummary: "列出已连接 MCP 服务器的可用工具",
            minIOSMajor: nil, maxIOSMajor: nil,
            requiresJailbreak: false, requiresTrollStore: false
        )
        ToolRegistry.shared.register(ExternalMCPTool(definition: listDef) { [weak self] params in
            guard let self else { return [:] }
            let server = params["server"] as? String
            return self.listTools(server: server)
        })
        ToolRegistry.shared.setEnabled(name: "user.mcp_list", enabled: true)

        // 入口 2：调用工具
        let callDef = ToolDefinition(
            name: "user.mcp_call",
            summary: "Invoke a tool on a connected MCP server. Discover tools first with user.mcp_list. Params: server (server name), tool (exact tool name from list), arguments (JSON string of the tool's params).",
            parameters: [
                "server": "server name (required)",
                "tool": "tool name (required, from user.mcp_list)",
                "arguments": "tool arguments as JSON string (optional, default {})"
            ],
            returns: ["content": "MCP tool result text", "structuredContent": "structured result if any"],
            verified: true, category: "mcp",
            uiSummary: "调用 MCP 服务器工具",
            minIOSMajor: nil, maxIOSMajor: nil,
            requiresJailbreak: false, requiresTrollStore: false
        )
        ToolRegistry.shared.register(ExternalMCPTool(definition: callDef) { [weak self] params in
            guard let self else { return [:] }
            guard let server = params["server"] as? String, !server.isEmpty else {
                throw MCPError.invalidParams("server required")
            }
            guard let tool = params["tool"] as? String, !tool.isEmpty else {
                throw MCPError.invalidParams("tool required")
            }
            var args: [String: Any] = [:]
            if let argsStr = params["arguments"] as? String, !argsStr.isEmpty {
                if let parsed = try? JSONSerialization.jsonObject(with: Data(argsStr.utf8)) as? [String: Any] {
                    args = parsed
                } else {
                    throw MCPError.invalidParams("arguments must be valid JSON object")
                }
            }
            return try self.callTool(server: server, tool: tool, args: args)
        })
        ToolRegistry.shared.setEnabled(name: "user.mcp_call", enabled: true)

        // 入口 3（v7.1.86）：探测能力——AI 发现本机/局域网 MCP 服务器，提示用户批准
        let probeDef = ToolDefinition(
            name: "user.mcp_probe",
            summary: "Scan localhost (or given host) for discoverable MCP servers (REA etc) via initialize handshake on common ports. Use this to discover new AI capabilities, then ask the user for approval before adding via user.mcp_add.",
            parameters: ["host": "host to scan (optional, default 127.0.0.1; use LAN IP for a computer running REA)"],
            returns: ["content": "list of discovered MCP servers (name + url)"],
            verified: true, category: "mcp",
            uiSummary: "探测本机/局域网可用的 MCP 能力",
            minIOSMajor: nil, maxIOSMajor: nil,
            requiresJailbreak: false, requiresTrollStore: false
        )
        ToolRegistry.shared.register(ExternalMCPTool(definition: probeDef) { [weak self] params in
            guard let self else { return [:] }
            return self.probeServers(host: params["host"] as? String)
        })
        ToolRegistry.shared.setEnabled(name: "user.mcp_probe", enabled: true)

        // 入口 4（v7.1.86）：添加探测到的服务器——只能在用户明确同意后调用，且只能加 probe 结果里的
        let addDef = ToolDefinition(
            name: "user.mcp_add",
            summary: "Add an MCP server that was discovered by user.mcp_probe. ONLY call after the user explicitly approves adding it. Rejects URLs not in the latest probe results (prevents adding unknown servers).",
            parameters: ["url": "server url from user.mcp_probe results (required)"],
            returns: ["content": "add/enable result with tool count"],
            verified: true, category: "mcp",
            uiSummary: "添加已探测并获用户同意的 MCP 能力",
            minIOSMajor: nil, maxIOSMajor: nil,
            requiresJailbreak: false, requiresTrollStore: false
        )
        ToolRegistry.shared.register(ExternalMCPTool(definition: addDef) { [weak self] params in
            guard let self else { return [:] }
            guard let url = params["url"] as? String, !url.isEmpty else {
                throw MCPError.invalidParams("url required")
            }
            return self.addServerFromProbe(url: url)
        })
        ToolRegistry.shared.setEnabled(name: "user.mcp_add", enabled: true)
        print("[TA] ✅ MCP tools registered: user.mcp_list / user.mcp_call / user.mcp_probe / user.mcp_add")
    }

    // MARK: - v7.1.86：能力探测 + 一键批准（AI 发现 → 用户对话批准 → 添加）

    /// 候选 MCP 端口（常见本地服务默认端口）
    private static let probePorts = [3000, 4000, 5000, 5173, 7000, 8000, 8080, 8765, 8931, 9000]
    /// 最近一次探测发现（user.mcp_add 只能添加这里面的，防 AI 乱加未知地址）
    private var lastProbe: [[String: String]] = []

    /// 对单个候选 URL 做 initialize 握手（2s 快速超时），成功返回 serverInfo.name
    private func probeHandshake(url: String) -> String? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = 2
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "method": "initialize", "id": 1,
            "params": ["protocolVersion": "2025-06-18",
                       "capabilities": ["tools": [:] as [String: Any]],
                       "clientInfo": ["name": "TrollAgent", "version": "7.1.86"]]
        ])
        let sem = DispatchSemaphore(value: 0)
        var serverName: String?
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            guard err == nil, let data,
                  let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let info = result["serverInfo"] as? [String: Any],
                  let name = info["name"] as? String else { return }
            serverName = name
        }.resume()
        _ = sem.wait(timeout: .now() + 3)
        return serverName
    }

    /// user.mcp_probe：并发扫描候选端口，返回发现的 MCP 服务器（AI 据此提示用户批准）
    func probeServers(host: String?) -> [String: Any] {
        let h = (host ?? "127.0.0.1").trimmingCharacters(in: .whitespacesAndNewlines)
        var found: [[String: String]] = []
        let lock = NSLock()
        let group = DispatchGroup()
        for port in Self.probePorts {
            let url = "http://\(h):\(port)"
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                if let name = self.probeHandshake(url: url) {
                    lock.lock(); found.append(["name": name, "url": url]); lock.unlock()
                }
            }
        }
        _ = group.wait(timeout: .now() + 10)
        found.sort { ($0["url"] ?? "") < ($1["url"] ?? "") }
        lastProbe = found
        if found.isEmpty {
            return ["content": "未发现 MCP 服务器。可传 host 参数扫描局域网（如 host=192.168.1.100，电脑上跑 REA 时用）。"]
        }
        var lines = ["发现 \(found.count) 个 MCP 服务器："]
        for f in found {
            lines.append("- \(f["name"] ?? "unknown") @ \(f["url"] ?? "")")
        }
        lines.append("")
        lines.append("如需启用：先询问用户是否添加，用户明确同意后再调 user.mcp_add 传对应 url。")
        return ["content": lines.joined(separator: "\n")]
    }

    /// user.mcp_add：添加探测发现的服务器（防 AI 乱加未知地址——只能加 lastProbe 里的）
    func addServerFromProbe(url: String) -> [String: Any] {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = lastProbe.first(where: { $0["url"] == trimmed }) else {
            return ["content": "拒绝：\(trimmed) 不在最近探测结果中。先调 user.mcp_probe 探测，或手动在 设置→MCP Servers 添加。"]
        }
        let name = match["name"] ?? "mcp"
        // 已存在同名 → 直接启用（幂等）
        if let idx = servers.firstIndex(where: { $0.name == name }) {
            servers[idx].enabled = true
            save()
            var c = servers[idx]
            _ = refreshServer(&c)
            servers[idx] = c
            return ["content": "已启用现有服务器 \(name)（\(c.toolCount) 工具）。"]
        }
        var cfg = MCPServerConfig(name: name, url: trimmed)
        let ok = refreshServer(&cfg)
        if ok {
            servers.append(cfg)
            save()
            return ["content": "已添加并启用 \(name)（\(cfg.toolCount) 工具）。现在可用 user.mcp_list 查看、user.mcp_call 调用。"]
        }
        return ["content": "添加失败：\(lastError ?? "未知错误")"]
    }

    /// user.mcp_list handler：从缓存返回工具清单（格式化文本，AI 易读）
    private func listTools(server: String?) -> [String: Any] {
        var lines: [String] = []
        for cfg in servers where cfg.enabled {
            if let s = server, s != cfg.name { continue }
            let tools = toolCache[cfg.name] ?? []
            lines.append("## \(cfg.name) (\(tools.count) tools)")
            for t in tools {
                guard let name = t["name"] as? String else { continue }
                let desc = (t["description"] as? String) ?? ""
                var params: [String] = []
                if let schema = t["inputSchema"] as? [String: Any] {
                    params = schemaParamNames(schema)
                }
                lines.append("- \(name): \(desc)" + (params.isEmpty ? "" : " [params: \(params.joined(separator: ", "))]"))
            }
            lines.append("")
        }
        if lines.isEmpty {
            return ["content": "No connected MCP servers. Add one in Settings → MCP Servers."]
        }
        return ["content": lines.joined(separator: "\n")]
    }

    // MARK: - JSON-RPC 2.0 over Streamable HTTP

    /// 发一个 JSON-RPC 请求，返回完整响应体（字典）。失败置 lastError 返回 nil。
    private func rpc(url: String, method: String, params: [String: Any]?) -> [String: Any]? {
        guard let u = URL(string: url) else { lastError = "URL 无效"; return nil }
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let p = params { body["params"] = p }
        // 需要响应的请求才带 id（notifications 不带）
        if method != "notifications/initialized" {
            body["id"] = rpcId
            rpcId += 1
        }
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            lastError = "请求序列化失败"; return nil
        }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        req.httpBody = httpBody

        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        var errText: String?
        URLSession.shared.dataTask(with: req) { data, resp, error in
            defer { sem.signal() }
            if let error = error {
                errText = error.localizedDescription
                return
            }
            guard let data else { errText = "空响应"; return }
            // Streamable HTTP：application/json 直接解析；text/event-stream 取 data: 行
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result = json
                return
            }
            // SSE 兜底：取最后一个 data: 前缀的 JSON 行
            let text = String(data: data, encoding: .utf8) ?? ""
            var lastJSON: [String: Any]?
            for line in text.components(separatedBy: "\n") {
                let s = line.trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("data:") {
                    let payload = String(s.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if let j = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
                        lastJSON = j
                    }
                }
            }
            if let lastJSON { result = lastJSON }
            else { errText = "响应无法解析（非 JSON/SSE）" }
        }.resume()
        if sem.wait(timeout: .now() + 35) == .timedOut {
            lastError = "\(method) 超时（服务器无响应）"
            return nil
        }
        if let errText {
            lastError = "\(method) 网络错误：\(errText)"
            return nil
        }
        if let result, let rpcErr = result["error"] as? [String: Any] {
            let msg = (rpcErr["message"] as? String) ?? "未知错误"
            lastError = "\(method) 服务器返回错误：\(msg)"
            return nil
        }
        return result
    }

    /// AI 调用 MCP 工具 → tools/call 转发
    func callTool(server: String, tool: String, args: [String: Any]) throws -> [String: Any] {
        guard let cfg = servers.first(where: { $0.name == server && $0.enabled }) else {
            throw MCPError.failed("MCP 服务器 '\(server)' 未启用或不存在")
        }
        guard let result = rpc(url: cfg.url, method: "tools/call", params: [
            "name": tool,
            "arguments": args
        ]) else {
            throw MCPError.failed("调用 \(server).\(tool) 失败：\(lastError ?? "未知错误")")
        }
        guard let callResult = result["result"] as? [String: Any] else {
            throw MCPError.failed("\(server).\(tool) 无 result")
        }
        if let isErr = callResult["isError"] as? Bool, isErr {
            let content = formatContent(callResult)
            throw MCPError.failed("\(server).\(tool) 执行错误：\(content)")
        }
        var out: [String: Any] = [:]
        let content = formatContent(callResult)
        if !content.isEmpty { out["content"] = content }
        if let sc = callResult["structuredContent"] {
            out["structuredContent"] = sc
        }
        return out
    }

    private func formatContent(_ callResult: [String: Any]) -> String {
        guard let content = callResult["content"] as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for item in content {
            if let type = item["type"] as? String {
                if type == "text", let text = item["text"] as? String {
                    parts.append(text)
                } else if let data = item["data"] as? String {
                    // 二进制（base64）——MCP 客户端只提示存在，避免把大 base64 塞进上下文
                    parts.append("[binary data \(data.count) chars base64]")
                } else if type == "image" {
                    parts.append("[image]")
                }
            }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - 参数解析（入口工具调用时用）

    /// 从 JSON Schema 提取参数名（供 user.mcp_list 展示）
    private func schemaParamNames(_ schema: [String: Any]) -> [String] {
        guard let props = schema["properties"] as? [String: Any] else { return [] }
        return Array(props.keys)
    }
}
