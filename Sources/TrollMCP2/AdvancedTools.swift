import Foundation

import UIKit
import Security
import AdSupport



// v2.9.72：符号浏览器 + 插件系统 + 兼容矩阵 + 崩溃复现 hook 模板生成



// MARK: - 二进制符号浏览器



final class BinarySymbolsTool: MCPTool {

    let definition = ToolDefinition(

        name: "binary.symbols",

        summary: "Extract symbols from a binary file (ObjC classes/methods, strings, imports). Use for: reverse engineer an app, analyze binary structure, find interesting classes/methods to hook. Don't use for: inject dylib (use injection.enable), check app deps (use app.deps). Example: user says 'what classes does 小红书 have' → extract ObjC symbols.",

        parameters: [

            "path": "Path to binary file (get main binary path via ipa.inspect)",

            "type": "What to extract: objc (classes/methods) / strings / imports / all (default)",

            "search": "Search keyword filter (optional)",

            "limit": "Max results (default 100)"

        ],

    verified: true, category: "analysis")



    func invoke(_ params: [String: Any]) throws -> [String: Any] {

        guard let path = params["path"] as? String, !path.isEmpty else {

            throw MCPError.invalidParams("path required")

        }

        let type = (params["type"] as? String) ?? "all"

        let search = (params["search"] as? String) ?? ""

        let limit = (params["limit"] as? Int) ?? 100
        let direction = (params["direction"] as? String) ?? ""



        guard FileManager.default.fileExists(atPath: path) else {

            return ["error": "file not found: \(path)"]

        }

        // v4.3.9: 定向分析模式——按方向(内购/VIP/广告)提取精简骨架, 大文件不全量喂 AI, AI 全读再分析原理
        if !direction.isEmpty {
            return directionalAnalyze(path: path, direction: direction)
        }



        var result: [String: Any] = ["path": path, "type": type]



        // 用 nm 提取符号 (如果有 nm）

        let nmPath = Bundle.main.path(forResource: "nm", ofType: nil, inDirectory: "bin") ?? "/usr/bin/nm"

        if FileManager.default.fileExists(atPath: nmPath) {

            let nmResult = InjectionManager.shared.spawnRootDetailed(nmPath, args: ["-g", "-U", path], timeout: 60)

            var symbols: [String] = []

            for line in nmResult.stdout.components(separatedBy: .newlines) {

                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if !trimmed.isEmpty && (search.isEmpty || trimmed.localizedCaseInsensitiveContains(search)) {

                    symbols.append(trimmed)

                }

            }

            result["symbols"] = Array(symbols.prefix(limit))

            result["total"] = symbols.count

        }



        // 用 strings 提取字符串

        if type == "strings" || type == "all" {

            let stringsPath = Bundle.main.path(forResource: "strings", ofType: nil, inDirectory: "bin") ?? "/usr/bin/strings"

            if FileManager.default.fileExists(atPath: stringsPath) {

                let strResult = InjectionManager.shared.spawnRootDetailed(stringsPath, args: [path], timeout: 60)

                var strings: [String] = []

                for line in strResult.stdout.components(separatedBy: .newlines) {

                    let trimmed = line.trimmingCharacters(in: .whitespaces)

                    if trimmed.count >= 4 && (search.isEmpty || trimmed.localizedCaseInsensitiveContains(search)) {

                        strings.append(trimmed)

                    }

                }

                result["strings"] = Array(strings.prefix(limit))

                result["strings_total"] = strings.count

            } else {

                // v4.3.3: bin/strings 未打包时, 用 Swift 原生分块扫描(不依赖外部工具)。
                // 原生 iOS 读大文件(如 22MB 砸壳二进制)内存充足, 不触发 Alpine OOM。
                let native = extractStringsNative(path: path, search: search)

                result["strings"] = Array(native.prefix(limit))

                result["strings_total"] = native.count

                result["strings_native"] = true

            }

        }



        // Objective-C class name (从字符串中提取）

        if type == "objc" || type == "all" {

            if let strings = result["strings"] as? [String] {

                let classes = strings.filter { $0.hasPrefix("_OBJC_CLASS_$_") || $0.hasPrefix("OBJC_CLASS_$_") }

                    .map { $0.replacingOccurrences(of: "_OBJC_CLASS_$_", with: "").replacingOccurrences(of: "OBJC_CLASS_$_", with: "") }

                let selectors = strings.filter { $0.contains(":") && $0.count < 60 && !$0.contains(" ") }

                result["objc_classes"] = Array(classes.prefix(limit))

                result["objc_selectors_sample"] = Array(selectors.prefix(50))

            }

        }



        if result["symbols"] == nil && result["strings"] == nil {

            result["hint"] = "nm/strings not bundled; use otool -ov to view ObjC sections, or ldid -e to view signature"

        }



        return result

    }



    /// v4.3.3: 原生 strings 扫描（bin/strings 未打包时的 fallback）。
    /// 用 FileManager/Data 分块读取并扫描可读 ASCII 串, 不依赖外部二进制, 大文件(22MB)原生读不 OOM。
    private func extractStringsNative(path: String, search: String) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let chunkSize = 4 * 1024 * 1024
        var strings: [String] = []
        var tail = Data()
        var total = 0
        while true {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            total += chunk.count
            if total > 256 * 1024 * 1024 { break } // 防御: 超 256MB 截断, 防耗时
            var buf = tail; buf.append(chunk)
            // 拆可读 ASCII 串
            var cur = Data()
            for byte in buf {
                if byte >= 0x20 && byte <= 0x7e {
                    cur.append(byte)
                } else {
                    if cur.count >= 4, let s = String(data: cur, encoding: .utf8),
                       (search.isEmpty || keywordsMatch(s, search)) {
                        strings.append(s)
                    }
                    cur = Data()
                }
            }
            // 保留末尾未闭合串到下一块(避免跨块切断)
            tail = cur
        }
        if tail.count >= 4, let s = String(data: tail, encoding: .utf8),
           (search.isEmpty || keywordsMatch(s, search)) {
            strings.append(s)
        }
        return strings
    }

    // v4.3.9: 多关键词匹配——search 支持 "|" 分隔(如 "StoreKit|SKPayment|VIP"), 命中任一即算。
    private func keywordsMatch(_ s: String, _ pattern: String) -> Bool {
        if pattern.isEmpty { return true }
        return pattern.split(separator: "|").contains { s.localizedCaseInsensitiveContains($0) }
    }

    // v4.3.9: 定向分析模式——按方向(内购/VIP/广告)提取精简骨架, 大文件不全量喂 AI。
    // 方法: 1) nm 符号表筛相关类/方法(符号表小, 不随文件大小长) 2) 分块扫 strings 按方向关键词筛命中
    //      3) 输出骨架(相关类+方法+关键字符串), AI 可全量读取再分析原理。
    func directionalAnalyze(path: String, direction: String) -> [String: Any] {
        let kws = directionalKeywords(direction)
        var related: [String] = []
        // 1) nm 符号表筛相关类/方法
        let nmPath = Bundle.main.path(forResource: "nm", ofType: nil, inDirectory: "bin") ?? "/usr/bin/nm"
        if FileManager.default.fileExists(atPath: nmPath) {
            let nmResult = InjectionManager.shared.spawnRootDetailed(nmPath, args: ["-g", "-U", path], timeout: 120)
            for line in nmResult.stdout.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty, kws.contains(where: { t.localizedCaseInsensitiveContains($0) }) {
                    related.append(t)
                }
            }
        }
        // 2) 分块扫 strings 按方向关键词筛命中(定向, 不全量返回)
        let hits = extractStringsNative(path: path, search: kws.joined(separator: "|"))
        // 3) 骨架输出(精简, AI 全读)
        return [
            "status": "analyzed_direction",
            "direction": direction,
            "keywords": kws,
            "related_symbols": Array(related.prefix(200)),
            "related_symbols_total": related.count,
            "key_strings": Array(hits.prefix(150)),
            "key_strings_total": hits.count,
            "note": "定向骨架已精简(相关类/方法+关键字符串), AI 可全量读取并推导内购/校验原理"
        ]
    }

    // v4.3.9: 方向 → 关键词组
    private func directionalKeywords(_ d: String) -> [String] {
        let lc = d.lowercased()
        if lc.contains("内购") || lc.contains("iap") || lc.contains("purchase") || lc.contains("vip") || lc.contains("pay") {
            return ["StoreKit", "SKProduct", "SKPayment", "Transaction", "AppTransaction", "StoreKitManager",
                    "Payment", "Purchase", "Receipt", "Entitlement", "VIP", "RealPaidVIP", "lifetimeProduct",
                    "productID", "price", "iap", "subscription", "IAP"]
        }
        if lc.contains("广告") || lc.contains("ad") || lc.contains("banner") {
            return ["Advert", "Banner", "Reward", "Interstitial", "AdSDK", "AdManager", "SDKAd", "ADManager"]
        }
        return [d]
    }

}



// MARK: - 插件系统 (简化版）



final class PluginManager {

    static let shared = PluginManager()

    private(set) var plugins: [PluginInfo] = []



    struct PluginInfo: Identifiable {

        let id = UUID()

        let name: String

        let path: String

        let type: PluginType

        let version: String

        var enabled: Bool



        enum PluginType: String {

            case dylib = "dylib"

            case tool = "tool"

            case skill = "skill"

        }

    }



    func scan() {

        let pluginDir = NSHomeDirectory().appending("/Documents/Workspace/plugins")

        try? FileManager.default.createDirectory(atPath: pluginDir, withIntermediateDirectories: true)



        plugins = []

        // 扫描内置 tweaks

        if let builtinDir = Bundle.main.path(forResource: "tweaks", ofType: nil) {

            if let files = try? FileManager.default.contentsOfDirectory(atPath: builtinDir) {

                for file in files where file.hasSuffix(".dylib") {

                    plugins.append(PluginInfo(

                        name: file.replacingOccurrences(of: ".dylib", with: ""),

                        path: builtinDir.appending("/\(file)"),

                        type: .dylib,

                        version: "builtin",

                        enabled: true

                    ))

                }

            }

        }

        // 扫描用户插件目录

        if let files = try? FileManager.default.contentsOfDirectory(atPath: pluginDir) {

            for file in files {

                let fullPath = pluginDir.appending("/\(file)")

                if file.hasSuffix(".dylib") {

                    plugins.append(PluginInfo(name: file, path: fullPath, type: .dylib, version: "user", enabled: true))

                }

            }

        }

    }



    func list() -> [[String: Any]] {

        scan()

        return plugins.map { [

            "name": $0.name,

            "path": $0.path,

            "type": $0.type.rawValue,

            "version": $0.version,

            "enabled": $0.enabled

        ] }

    }

}



final class PluginTool: MCPTool {

    let definition = ToolDefinition(

        name: "plugin.list",

        summary: "List installed dylib plugins (built-in + user). Use for: see what plugins are available, check plugin status. Don't use for: inject plugin into app (use injection.enable), list injected apps (use injection.status). Example: user says 'what plugins are available' → list plugins.",

        parameters: [

            "action": "list (show all) / enable / disable",

            "name": "Plugin name (required for enable/disable action)"

        ],

    verified: true, category: "analysis")



    func invoke(_ params: [String: Any]) throws -> [String: Any] {

        let action = (params["action"] as? String) ?? "list"

        if action == "list" {

            return ["plugins": PluginManager.shared.list(), "count": PluginManager.shared.plugins.count]

        }

        return ["error": "unsupported action: \(action)"]

    }

}



// MARK: - 崩溃复现 hook 模板生成



final class CrashReproTool: MCPTool {

    let definition = ToolDefinition(

        name: "crash.repro_template",

        summary: "Generate a Logos hook template from a crash report. Use for: debug why app crashes, create hook to reproduce/fix crash. Don't use for: collect crash logs (use log.collect), analyze crash (use diagnose.crash). Example: user says '小红书 keeps crashing, generate a hook for me' → generate repro template.",

        parameters: [

            "crash_log": "Crash log text (get from diagnose.crash first)",

            "bundle_id": "Target App bundle ID (for context)"

        ],

    verified: true, category: "diagnose")



    func invoke(_ params: [String: Any]) throws -> [String: Any] {

        guard let crashLog = params["crash_log"] as? String, !crashLog.isEmpty else {

            throw MCPError.invalidParams("crash_log required")

        }

        let bundleId = params["bundle_id"] as? String ?? "com.example.app"



        // 从崩溃日志中提取关键信息

        var exceptionType = ""

        var crashedThread = "0"



        for line in crashLog.components(separatedBy: .newlines) {

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("Exception Type:") {

                exceptionType = trimmed.replacingOccurrences(of: "Exception Type: ", with: "")

            } else if trimmed.hasPrefix("Triggered by Thread:") {

                crashedThread = trimmed.replacingOccurrences(of: "Triggered by Thread: ", with: "")

            } else if trimmed.contains("Thread \(crashedThread) Crashed:") {

                // 下一帧是崩溃位置

            }

        }



        // 提取崩溃线程第一帧

        let lines = crashLog.components(separatedBy: .newlines)

        var inCrashedThread = false

        var firstFrame = ""

        for line in lines {

            if line.contains("Thread \(crashedThread) Crashed:") {

                inCrashedThread = true

                continue

            }

            if inCrashedThread && !line.isEmpty {

                firstFrame = line.trimmingCharacters(in: .whitespaces)

                break

            }

        }



        // 生成 hook 模板

        let template = """

        // 自动生成的崩溃复现 hook 模板

        // 崩溃类型: \(exceptionType)

        // 崩溃线程: \(crashedThread)

        // 崩溃帧: \(firstFrame)

        // 目标: \(bundleId)



        #import <Foundation/Foundation.h>

        #import <UIKit/UIKit.h>



        static NSString *kCrashLog = @"/var/mobile/Documents/Workspace/crash_repro_\(bundleId).log";



        static void logRepro(NSString *msg) {

            NSString *ts = [NSDateFormatter localizedStringFromDate:[NSDate date] dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle];

            NSString *line = [NSString stringWithFormat:@"[%@] %@\\n", ts, msg];

            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kCrashLog];

            if (!fh) { [[NSData data] writeToFile:kCrashLog atomically:YES]; fh = [NSFileHandle fileHandleForWritingAtPath:kCrashLog]; }

            [fh seekToEndOfFile];

            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];

            [fh closeFile];

        }



        // TODO: 根据崩溃帧替换下面的 hook 目标

        // 用 binary.symbols 搜索崩溃帧中的class name和方法名

        %hook UIApplication



        - (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

            logRepro(@"[REPRO] application didFinishLaunching");

            logRepro([NSString stringWithFormat:@"[REPRO] launchOptions: %@", launchOptions]);

            return %orig;

        }



        %end
    }