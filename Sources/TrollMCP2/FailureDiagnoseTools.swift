import Foundation

// v2.9.132：failed边界一条龙——注入健康检查 + 启动failed判因
// 对齐之前规划的"每个工具failed时先自查原因再给结论"：
// 1. injection.verify：注入后健康检查 (Mach-O 标记 / 进程存活 / 崩溃日志 / 结论分级）
// 2. app.diagnose：启动failed自动判因 (加密/签名/注入残留/崩溃现场 → 明确原因 + 下一步）

final class InjectionVerifyTool: MCPTool {
    let definition = ToolDefinition(
        name: "injection.verify",
        summary: "Verify if injection actually worked (dylib loaded + app still running). Use for: after injection.enable, confirm it really loaded, check if app didn't crash. Don't use for: just check status (use injection.status, simpler), inject dylib (use injection.enable). Example: user says 'did injection succeed, did the app crash' → verify injection.",
        parameters: [
            "bundle_id": "Target App bundle ID (required)",
            "dylib": "Dylib name to verify (optional, auto-detect all)"
        ],
        verified: true, category: "injection")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let wantDylib = params["dylib"] as? String

        let apps = AppCatalog.list()
        guard let app = apps.first(where: { $0.bundleId == bundleId }) else {
            return ["ok": false, "bundle_id": bundleId, "verdict": "not_found",
                    "reason": "App not found", "next_step": "use injection.list to search bundle_id"]
        }

        // 1) Mach-O 加载命令 (主二进制 + 注入资产）
        var loadedDylibs: [String] = []
        let mainBinary = app.path + "/" + (((NSDictionary(contentsOfFile: app.path + "/Info.plist"))?["CFBundleExecutable"] as? String) ?? "App")
        if let mo = MachOAnalyzer.analyze(mainBinary) {
            loadedDylibs = mo.dylibs.filter { $0.contains("ControlAgent") || $0.contains("ProbeAgent") || $0.contains("MemoryTweak") || $0.contains(".dylib") }
        }
        // 注入资产 (Frameworks 内，TrollFools 策略）
        let assets = InjectionManager.shared.injectedAssets(in: app).map { ($0 as NSString).lastPathComponent }

        // 2) 进程存活
        let pid = findPid(by: bundleId)

        // 3) 崩溃检测：最近 90 秒 CrashReporter 里该 App 的崩溃文件
        var recentCrash: [String: Any]? = nil
        let crashDir = "/var/mobile/Library/Logs/CrashReporter"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: crashDir) {
            let now = Date().timeIntervalSince1970
            let relevant = files.filter { $0.lowercased().contains(bundleId.lowercased()) || $0.lowercased().contains(app.name.lowercased()) }
            var newest: (String, Date)?
            for f in relevant {
                let p = crashDir + "/" + f
                if let attrs = try? FileManager.default.attributesOfItem(atPath: p),
                   let mtime = attrs[.modificationDate] as? Date,
                   now - mtime.timeIntervalSince1970 < 90 {
                    if newest == nil || mtime > newest!.1 { newest = (p, mtime) }
                }
            }
            if let n = newest {
                recentCrash = ["path": n.0, "age_s": Int(now - n.1.timeIntervalSince1970),
                               "summary": extractCrashSummary(n.0)]
            }
        }

        // 4) 判定
        let hasMarker = !loadedDylibs.isEmpty || !assets.isEmpty
        var verdict: String
        var reason: String
        var nextStep: String

        if recentCrash != nil {
            verdict = "crashed"
            reason = "recent crash detected: \(recentCrash?["summary"] as? String ?? "")"
            nextStep = "First restore with injection.disable or injection.restore, then check dylib-target compatibility (arch/dependencies/constructor); or rescue.recover_all for emergency recovery"
        } else if hasMarker && pid > 0 {
            verdict = "healthy"
            reason = "dylib load command exists + target process alive + no recent crash"
            nextStep = "Can continue with network_capture / probe etc.; to confirm the hook actually fired, the injected dylib should log to workspace logs/ for log.collect"
        } else if hasMarker && pid == 0 {
            verdict = "injected_but_dead"
            reason = "dylib load command written, but the target process isn't running (possibly killed by anti-injection detection after launch, or from not running)"
            nextStep = "Launch with app.start then verify immediately; if still dead, check the crash cause with app.diagnose"
        } else {
            verdict = "not_injected"
            reason = "No injected dylib found in the main binary/injection assets"
            nextStep = "Inject first with injection.enable"
        }

        let result: [String: Any] = [
            "ok": verdict == "healthy",
            "bundle_id": bundleId,
            "verdict": verdict,
            "reason": reason,
            "next_step": nextStep,
            "checks": [
                "macho_dylibs": loadedDylibs,
                "injected_assets": assets,
                "process_alive": pid > 0,
                "pid": pid,
                "recent_crash": recentCrash ?? ([:] as [String: Any])
            ]
        ]
        AuditLog.shared.log("injection.verify", detail: "\(bundleId) → \(verdict)")
        return result
    }
}

final class AppDiagnoseTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.diagnose",
        summary: "Diagnose why an app won't open/crash. Use for: app won't launch, keeps crashing, find out why. Don't use for: read crash logs (use shell.exec), inject dylib (use injection.enable). Example: user says '小红书 will not open, why' → diagnose app failure.",
        parameters: ["bundle_id": "Target App bundle ID (required)"],
    verified: true, category: "app_control")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let apps = AppCatalog.list()
        guard let app = apps.first(where: { $0.bundleId == bundleId }) else {
            return ["ok": false, "bundle_id": bundleId,
                    "diagnosis": ["not_found": true, "reason": "App not installed on device"],
                    "next_step": "use injection.list to confirm bundle_id, or app.install to install"]
        }

        let binaryPath = app.path + "/" + (((NSDictionary(contentsOfFile: app.path + "/Info.plist"))?["CFBundleExecutable"] as? String) ?? "App")
        var checks: [String: Any] = ["app_name": app.name, "bundle_path": app.path]

        // 1) 注入残留
        let assets = InjectionManager.shared.injectedAssets(in: app)
        let injected = MachOAnalyzer.analyze(binaryPath)?.dylibs.contains(where: { $0.contains("ControlAgent") }) ?? false
        checks["injection"] = ["injected": injected, "assets": assets.map { ($0 as NSString).lastPathComponent }]

        // 2) 加密状态 (otool -l 查 LC_ENCRYPTION_INFO）
        var encrypted: Bool? = nil
        let otoolPath = Bundle.main.path(forResource: "otool", ofType: nil, inDirectory: "bin") ?? "/usr/bin/otool"
        if FileManager.default.fileExists(atPath: otoolPath) {
            let out = InjectionManager.shared.spawnRootDetailed(otoolPath, args: ["-l", binaryPath], timeout: 60).stdout
            encrypted = out.contains("LC_ENCRYPTION_INFO")
        }
        checks["encrypted"] = encrypted

        // 3) 签名状态
        var signed: Bool? = nil
        if let ldid = InjectionManager.shared.binaryPath("ldid") {
            let out = InjectionManager.shared.spawnRootDetailed(ldid, args: ["-e", binaryPath], timeout: 30).stdout
            signed = !out.isEmpty
        }
        checks["signed"] = signed

        // 4) 最近崩溃 (10 分钟内）
        var crashSummary: String? = nil
        let crashDir = "/var/mobile/Library/Logs/CrashReporter"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: crashDir) {
            let now = Date().timeIntervalSince1970
            let relevant = files.filter { $0.lowercased().contains(bundleId.lowercased()) || $0.lowercased().contains(app.name.lowercased()) }
            var newest: (String, Date)?
            for f in relevant {
                let p = crashDir + "/" + f
                if let attrs = try? FileManager.default.attributesOfItem(atPath: p),
                   let mtime = attrs[.modificationDate] as? Date,
                   now - mtime.timeIntervalSince1970 < 600 {
                    if newest == nil || mtime > newest!.1 { newest = (p, mtime) }
                }
            }
            if let n = newest { crashSummary = extractCrashSummary(n.0) }
        }
        checks["recent_crash"] = crashSummary

        // 5) 尝试启动
        let startTool = AppStartTool()
        let startResult = try? startTool.invoke(["bundle_id": bundleId, "wait_seconds": 3])
        checks["start_attempt"] = startResult ?? ["started": false]

        // 6) 综合判定
        var problems: [String] = []
        var nextSteps: [String] = []
        if injected {
            problems.append("Injection residue present, the app may be crashing due to injection")
            nextSteps.append("Restore first with injection.disable or injection.restore, then launch and test")
        }
        if encrypted == true {
            problems.append("Main binary encrypted (App Store original), can't inject/parse structure")
            nextSteps.append("Decrypt with app.decrypt, then reinstall the decrypted version")
        }
        if signed == false {
            problems.append("No signing info (not re-signed or ldid parse failed)")
            nextSteps.append("Re-sign with ldid or confirm the TrollStore install state")
        }
        if let cs = crashSummary {
            problems.append("Recent crash: \(cs)")
            nextSteps.append("Crash scene in CrashReporter; if injection-related, restore first, then re-inject")
        }
        if problems.isEmpty {
            nextSteps.append("If still not running, check dylib compatibility (arch arm64/arm64e, missing dependency libs, constructor crash)")
        }

        return ["ok": problems.isEmpty, "bundle_id": bundleId, "checks": checks,
                "problems": problems, "next_steps": nextSteps]
    }
}

// MARK: - 崩溃日志摘要提取 (.ips JSON 或 .crash 文本）

func extractCrashSummary(_ path: String) -> String {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
          let text = String(data: data, encoding: .utf8) else { return "unreadable" }
    var out: [String] = []
    for line in text.components(separatedBy: .newlines).prefix(60) {
        let l = line.trimmingCharacters(in: .whitespaces)
        if l.contains("\"exceptionType\"") || l.contains("exceptionType :") { out.append(l.prefix(160).description) }
        if l.contains("\"termination\"") || l.contains("Termination Reason") { out.append(l.prefix(160).description) }
        if l.contains("Faulty Thread") || l.contains("\"faultingThread\"") { out.append(l.prefix(160).description) }
        if out.count >= 4 { break }
    }
    return out.isEmpty ? String(text.prefix(300)) : out.joined(separator: " | ")
}
