import Foundation

// MARK: - 子代理任务模型（v7.1.107：对齐 OpenMinis subagent_task 思想，自实现）
/// 子代理 = 隔离的隐藏会话跑自己的工具循环：主模型把自包含"脏活"委派出去，
/// 子代理独立上下文执行（不污染主线），完成后把结果 JSON 回传给主模型。
/// 主模型用 subagent.status 轮询、subagent.stop 停止。

final class SubAgentTask: Identifiable {
    let id: String
    let instruction: String
    private(set) var status: Status
    private(set) var createdAt: Date
    private(set) var rounds: Int
    private(set) var toolTrace: [String]
    private(set) var result: String
    private(set) var error: String
    private(set) var elapsed: Double

    enum Status: String { case running, done, failed, stopped }

    init(id: String, instruction: String) {
        self.id = id
        self.instruction = instruction
        self.status = .running
        self.createdAt = Date()
        self.rounds = 0
        self.toolTrace = []
        self.result = ""
        self.error = ""
        self.elapsed = 0
    }

    func markDone(result: String) {
        status = .done
        self.result = result
        elapsed = Date().timeIntervalSince(createdAt)
    }

    func markFailed(_ err: String) {
        status = .failed
        error = err
        elapsed = Date().timeIntervalSince(createdAt)
    }

    func markStopped() {
        status = .stopped
        elapsed = Date().timeIntervalSince(createdAt)
    }

    func addRound(tools: [String]) {
        rounds += 1
        toolTrace.append(contentsOf: tools)
    }

    /// 工具返回值 JSON（subagent.status / 完成回传用）
    func toDict() -> [String: Any] {
        var d: [String: Any] = [
            "task_id": id,
            "status": status.rawValue,
            "rounds": rounds,
            "elapsed_secs": Int(elapsed),
            "tool_trace": toolTrace,
        ]
        if !result.isEmpty { d["result"] = result }
        if !error.isEmpty { d["error"] = error }
        return d
    }
}

// MARK: - 子代理管理器（单例，一次最多 1 个运行中——防工具资源争抢/上下文混乱）

final class SubAgentManager {
    static let shared = SubAgentManager()

    private var tasks: [String: SubAgentTask] = [:]
    private var activeTaskID: String?
    private let lock = NSLock()

    /// 启动子代理。成功返回 task_id；已有任务在跑则返回失败（模型应轮询/停止旧任务）。
    func start(instruction: String, allowedTools: [String]?,
               maxRounds: Int, timeout: TimeInterval) -> Result<String, String> {
        lock.lock()
        if let active = activeTaskID {
            lock.unlock()
            return .failure("已有子代理 \(active) 在运行。先 subagent.status 等待它完成，或 subagent.stop 停止后再委派新任务。")
        }
        let id = String(UUID().uuidString.prefix(8))
        let task = SubAgentTask(id: id, instruction: instruction)
        tasks[id] = task
        activeTaskID = id
        lock.unlock()

        let runner = SubAgentRunner(task: task, allowedTools: allowedTools,
                                    maxRounds: maxRounds, timeout: timeout)
        DispatchQueue.global(qos: .userInitiated).async {
            runner.run()
            self.lock.lock()
            if self.activeTaskID == id { self.activeTaskID = nil }
            self.lock.unlock()
        }
        return .success(id)
    }

    func status(id: String) -> SubAgentTask? {
        lock.lock()
        defer { lock.unlock() }
        return tasks[id]
    }

    func stop(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let t = tasks[id], t.status == .running else { return false }
        t.markStopped()
        return true
    }
}

// MARK: - 子代理执行循环（隔离会话 + 工具循环，独立于主 runLoop，不碰主线状态）

final class SubAgentRunner {
    private let task: SubAgentTask
    private let allowedTools: [String]?
    private let maxRounds: Int
    private let deadline: Date
    private var messages: [ChatMessage] = []
    private var client: OpenAIClient?
    private var lastTool = ""
    private var sameToolRepeat = 0

    /// 子代理默认工具集——通用干活三件套 + 只读信息工具（全量 schema 太大，注入精简集）
    private let defaultTools: Set<String> = [
        "shell.exec", "artifact", "device", "web.search", "web.fetch", "skills.read"
    ]

    init(task: SubAgentTask, allowedTools: [String]?, maxRounds: Int, timeout: TimeInterval) {
        self.task = task
        self.allowedTools = allowedTools
        self.maxRounds = max(2, min(maxRounds, 30))
        self.deadline = Date().addingTimeInterval(max(30, min(timeout, 600)))
    }

    /// 子代理系统提示词——精简版执行纪律（不承诺收尾/结构化调用/自主决策）
    private func systemPrompt() -> String {
        var p = """
        You are a subagent of TrollAgent executing a delegated task in an isolated session.
        Your ONLY job is to complete the task below precisely, autonomously, using tools.
        RULES:
        1. The ONLY way to call a tool is an explicit structured function call. Never write calls as plain text.
        2. NEVER end your turn with a promise of future action ("I'll continue later"). Work until the task is
           actually done; if a step needs waiting, chain short polling calls (timeout≈5) and decide from each result.
        3. If a tool fails, diagnose from the error and try a different approach (up to 3 attempts), then move on.
        4. Do not ask the user questions — decide autonomously. Do not chat about the task; just do it.
        5. When finished, your final text must be a concise structured summary of what was done and the key result.
        """
        if let wl = allowedTools, !wl.isEmpty {
            p += "\nTOOL WHITELIST (use ONLY these): \(wl.joined(separator: ", "))"
        } else {
            p += "\nTools: \(defaultTools.sorted().joined(separator: ", ")) (use these; others may exist in schema — stay within your allowed set)"
        }
        return p
    }

    /// 过滤后的工具 schema：默认集 ∪ 白名单（apiName 前缀匹配大工具）
    private func subAgentTools() -> [[String: Any]]? {
        var allowed = Set(defaultTools)
        if let wl = allowedTools, !wl.isEmpty {
            for w in wl { allowed.insert(w) }
        }
        let all = ToolRegistry.shared.enabledOpenAIToolSchema()
        var picked: [[String: Any]] = []
        for schema in all {
            guard let fn = schema["function"] as? [String: Any],
                  let n = fn["name"] as? String else { continue }
            // 匹配：精确 apiName 或大工具名（如 "artifact" 匹配 "artifact.read"）
            let matched = allowed.contains(n) || allowed.contains { n.hasPrefix($0 + ".") }
            if matched { picked.append(schema) }
        }
        return picked.isEmpty ? nil : picked
    }

    func run() {
        messages.append(ChatMessage(role: "system", content: systemPrompt()))
        messages.append(ChatMessage(role: "user", content: task.instruction))
        loop()
    }

    private func loop() {
        // 停止检查
        if task.status == .stopped { return }
        // 超时 / 轮次上限
        if Date() > deadline {
            task.markFailed("timeout after \(Int(deadline.timeIntervalSince(task.createdAt)))s")
            return
        }
        if task.rounds >= maxRounds {
            task.markFailed("reached max rounds (\(maxRounds))")
            return
        }
        // 取当前模型配置（与主会话一致）
        let store = ModelStore.shared
        let config = store.lastUsedConfigId
            .flatMap { id in store.configs.first { $0.id.uuidString == id } }
            ?? store.configs.first
        guard let config else {
            task.markFailed("no model config available")
            return
        }
        let client = OpenAIClient(config)
        self.client = client
        let tools = subAgentTools()
        client.send(messages: messages, tools: tools) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let cr):
                switch cr {
                case .text(let text, _):
                    self.task.markDone(result: text)
                case .toolCalls(let calls, _, _):
                    self.execute(calls: calls)
                }
            case .failure(let err):
                let nsErr = err as NSError
                if nsErr.code == -999 {
                    self.task.markStopped()
                } else {
                    self.task.markFailed(String(err.localizedDescription.prefix(200)))
                }
            }
        }
    }

    /// 逐条执行工具（子代理内串行——简单安全，不做并行），结果回填后继续循环
    private func execute(calls: [ToolCall]) {
        var msgs = messages
        var executed: [String] = []
        for call in calls {
            // 同工具同参数重复 3 次熔断（防死循环，对齐 ToolLoopDetector 思想）
            if call.name == lastTool {
                sameToolRepeat += 1
                if sameToolRepeat >= 3 {
                    let body: [String: Any] = [
                        "ok": false,
                        "message": "🚫 LOOP BLOCKED: You've called \(call.name) \(sameToolRepeat) times with the same pattern and it keeps repeating. STOP. Try a completely different approach or conclude the task."
                    ]
                    var m = ChatMessage(role: "tool", content: Self.json(body), isError: true,
                                        toolCallId: call.id, toolName: call.name)
                    m.toolArgs = Self.summarizeArgs(call.arguments)
                    msgs.append(m)
                    continue
                }
            } else {
                lastTool = call.name
                sameToolRepeat = 1
            }
            // 执行工具
            let params = Self.parseArgs(call.arguments)
            do {
                let r = try ToolRegistry.shared.dispatch(name: call.name, params: params)
                var content = Self.json(r)
                if content.count > 8000 {
                    content = content.prefix(8000) + "\n... [tool result truncated, total \(content.count) chars]"
                }
                var m = ChatMessage(role: "tool", content: content, toolCallId: call.id, toolName: call.name)
                m.toolArgs = Self.summarizeArgs(call.arguments)
                msgs.append(m)
            } catch {
                var m = ChatMessage(role: "tool", content: Self.json(["ok": false, "message": String(describing: error)]),
                                    isError: true, toolCallId: call.id, toolName: call.name)
                m.toolArgs = Self.summarizeArgs(call.arguments)
                msgs.append(m)
            }
            executed.append(call.name)
        }
        task.addRound(tools: executed)
        messages = msgs
        loop()
    }

    // MARK: - 工具小工具
    private static func parseArgs(_ s: String) -> [String: Any] {
        guard let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    private static func json(_ dict: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    private static func summarizeArgs(_ s: String) -> String? {
        guard let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let entries = o.prefix(2).map { k, v -> String in
            let val = "\(v)"
            return "\(k): \(val.count > 50 ? String(val.prefix(50)) + "..." : val)"
        }
        return entries.isEmpty ? nil : entries.joined(separator: ", ")
    }
}

// MARK: - 子代理工具注册（subagent.run / subagent.status / subagent.stop）

final class SubAgentRunTool: MCPTool {
    let definition = ToolDefinition(
        name: "subagent.run",
        summary: "Delegate a self-contained task to an isolated subagent that runs its own tool loop in a separate context (won't pollute the main conversation). Use for: long multi-step dirty work — batch file analysis, multi-file audits, repetitive processing, web research chains. Don't use for: quick single calls (call the tool directly). Params: instruction(required), tools(optional comma-separated whitelist, default shell.exec/artifact/device/web.search/web.fetch/skills.read), max_rounds(optional default 12 max 30), timeout_secs(optional default 180 max 600). Returns task_id immediately (async); poll with subagent.status until status=done, stop with subagent.stop if it misbehaves.",
        parameters: [
            "instruction": "The complete task to execute (required). Be specific about the goal, inputs, and expected output format.",
            "tools": "Optional comma-separated tool whitelist, e.g. 'shell.exec,artifact'. Default: shell.exec/artifact/device/web.search/web.fetch/skills.read",
            "max_rounds": "Optional max tool rounds (default 12, max 30)",
            "timeout_secs": "Optional timeout seconds (default 180, max 600)",
        ],
        verified: true, category: "system")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let instruction = params["instruction"] as? String, !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError.invalidParams("instruction required")
        }
        let wl = (params["tools"] as? String)?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let rounds = (params["max_rounds"] as? Int) ?? 12
        let timeout = (params["timeout_secs"] as? Double) ?? 180
        switch SubAgentManager.shared.start(instruction: instruction, allowedTools: wl,
                                            maxRounds: rounds, timeout: timeout) {
        case .success(let id):
            return ["ok": true, "task_id": id,
                    "message": "subagent \(id) started. Poll with subagent.status task_id=\(id); stop with subagent.stop task_id=\(id)."]
        case .failure(let err):
            throw MCPError.failed(err)
        }
    }
}

final class SubAgentStatusTool: MCPTool {
    let definition = ToolDefinition(
        name: "subagent.status",
        summary: "Check the status of a running/finished subagent task. Use for: polling after subagent.run (loop: status → if still running, continue polling with short delay). Returns status (running/done/failed/stopped), rounds, tool_trace, and the final result when done.",
        parameters: [
            "task_id": "The subagent task id returned by subagent.run (required)",
        ],
        verified: true, category: "system")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let id = params["task_id"] as? String, !id.isEmpty else {
            throw MCPError.invalidParams("task_id required")
        }
        guard let task = SubAgentManager.shared.status(id: id) else {
            return ["ok": false, "message": "no subagent task with id \(id)"]
        }
        var d = task.toDict()
        d["ok"] = true
        return d
    }
}

final class SubAgentStopTool: MCPTool {
    let definition = ToolDefinition(
        name: "subagent.stop",
        summary: "Stop a running subagent task immediately (marks it stopped; in-flight tool call may finish but no further rounds run). Use for: subagent misbehaving, looping, or the task is no longer needed.",
        parameters: [
            "task_id": "The subagent task id returned by subagent.run (required)",
        ],
        verified: true, category: "system")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let id = params["task_id"] as? String, !id.isEmpty else {
            throw MCPError.invalidParams("task_id required")
        }
        if SubAgentManager.shared.stop(id: id) {
            return ["ok": true, "task_id": id, "status": "stopped"]
        }
        return ["ok": false, "message": "task \(id) not running (already finished/stopped or unknown id)"]
    }
}
