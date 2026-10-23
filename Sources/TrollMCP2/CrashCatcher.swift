import Foundation
import SwiftUI
import Darwin

/// v2.9.145c：崩溃日志捕获——闪退自动落盘到工作区 crash/，设置页「崩溃日志」可查看。
/// 解决"闪退原因不可见"的排障盲区：此前用户报闪退只能靠猜，加上这个后每次闪退都有现场留痕。
enum CrashCatcher {
    static var crashDir: URL {
        Workspace.root.appendingPathComponent("crash", isDirectory: true)
    }

    // v2.9.150：signal-safe 预分配缓冲（install() 时在正常上下文分配，
    // handler 内只做指针写入，绝不触发 Swift 堆分配/字符串/ObjC）
    private static var sigPathBuf: UnsafeMutablePointer<CChar>?
    private static var sigMsgBuf: UnsafeMutablePointer<CChar>?
    private static let sigPathCap = 1024
    private static let sigMsgCap = 128
    // v2.9.172：crash 目录的 C 字符串路径在 install() 正常上下文一次性固化。
    // 旧版 handler 里 `crashDir.path` 每次访问都重新计算 URL（Swift/ObjC runtime），
    // 在信号上下文二次崩溃，导致 4 次 Segfault 全部只记录到 writeSignal 自身、
    // 真实崩溃点被掩盖（libsystem_platform.dylib 0x... + 480）。
    private static var crashDirC: UnsafeMutablePointer<CChar>?
    private static let crashDirCap = 1024

    static func install() {
        // 正常上下文：分配缓冲 + 固化目录 C 路径（handler 内不再碰任何 Swift 对象）
        let dir = crashDir.path
        let c = UnsafeMutablePointer<CChar>.allocate(capacity: crashDirCap)
        if let u = (dir as NSString).utf8String { strcpy(c, u) }
        crashDirC = c
        if sigPathBuf == nil { sigPathBuf = .allocate(capacity: sigPathCap) }
        if sigMsgBuf == nil { sigMsgBuf = .allocate(capacity: sigMsgCap) }

        // 1) ObjC 未捕获异常（Swift fatalError / 强解包 / 数组越界等走这里）
        NSSetUncaughtExceptionHandler { exception in
            let ts = time(nil)
            let dir = CrashCatcher.crashDir.path
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            var lines: [String] = [
                "=== Uncaught Exception @ \(ts) ===",
                "name: \(exception.name.rawValue)",
                "reason: \(exception.reason ?? "(nil)")",
                "userInfo: \(exception.userInfo ?? [:])",
                "--- callStackSymbols ---"
            ]
            lines += exception.callStackSymbols
            let path = "\(dir)/exc_\(ts).txt"
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }

        // 2) POSIX 信号（EXC_BAD_ACCESS 等内存错误走这里）——handler 只做 signal-safe 的最小写盘
        func arm(_ sig: Int32) {
            signal(sig) { s in
                CrashCatcher.writeSignal(s)
            }
        }
        arm(SIGABRT)
        arm(SIGSEGV)
        arm(SIGBUS)
        arm(SIGILL)
        arm(SIGTRAP)
        arm(SIGFPE)
    }

    /// v2.9.150b：纯 signal-safe 写盘——上一版用 Swift String 插值/Date/数组，
    /// 在信号上下文里二次崩溃，导致日志全部只记录到 writeSignal 自身、
    /// 真正崩溃点被掩盖。现在只用 C 函数与手写整数拼接：
    ///   time/mkdir/strcpy/strlen/strsignal/open/write/backtrace/backtrace_symbols_fd/close
    /// 全部 async-signal-safe（snprintf 是 C 变参函数，Swift 不可用，改手写拼接）。
    private static func writeSignal(_ s: Int32) {
        let ts = time(nil)
        // v2.9.172：直接用启动时固化的 C 路径，零 Swift runtime 访问
        guard let d = crashDirC, let pb = sigPathBuf, let mb = sigMsgBuf else { return }
        _ = mkdir(d, 0o755)
        // 路径: dir + "/sig_" + ts + ".txt"
        var p = pb
        strcpy(p, d)
        p += strlen(p)
        p[0] = 47  // '/'
        p += 1
        strcpy(p, "sig_")
        p += 4
        p = appendInt(p, ts)
        strcpy(p, ".txt")
        let fd = open(pb, O_CREAT | O_WRONLY | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        // 头部: "signal <name> @ <ts>\n"
        var m = mb
        strcpy(m, "signal ")
        m += 7
        if let name = strsignal(s) {
            strcpy(m, name)
            m += strlen(m)
        } else {
            m = appendInt(m, Int(s))
        }
        strcpy(m, " @ ")
        m += 3
        m = appendInt(m, ts)
        strcpy(m, "\n")
        _ = write(fd, mb, strlen(mb))
        // backtrace/backtrace_symbols_fd 均为 async-signal-safe
        let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)
        let n = backtrace(frames, 64)
        backtrace_symbols_fd(frames, n, fd)
        frames.deallocate()
        close(fd)
        // 恢复默认处理并重发，让系统也生成官方崩溃报告
        signal(s, SIG_DFL)
        raise(s)
    }

    /// 手写整数→ASCII 追加到 p 末尾（signal-safe：纯算术+指针，零 Swift 运行时）
    /// 返回结尾（'\0' 位置）的下一位置
    private static func appendInt(_ p: UnsafeMutablePointer<CChar>, _ v: Int) -> UnsafeMutablePointer<CChar> {
        if v == 0 {
            p[0] = 48
            p[1] = 0
            return p + 1
        }
        var n = v
        var neg = false
        if n < 0 { neg = true; n = -n }
        let start = p
        var q = p
        while n > 0 {
            q[0] = CChar(48 + (n % 10))
            q += 1
            n /= 10
        }
        if neg {
            q[0] = 45
            q += 1
        }
        var lo = start
        var hi = q - 1
        while lo < hi {
            let t = lo[0]
            lo[0] = hi[0]
            hi[0] = t
            lo += 1
            hi -= 1
        }
        q[0] = 0
        return q
    }

    /// v2.9.152：导出全部崩溃日志为一份文本（供分享/保存，用户反馈"不能分享保存"）
    static func exportAll() -> String {
        var out = "TrollAgent crash log export\nExported: \(Date())\n\n"
        for p in list() {
            out += "===== \(URL(fileURLWithPath: p).lastPathComponent) =====\n"
            out += content(p)
            out += "\n\n"
        }
        return out
    }

    // MARK: - 崩溃日志列表（设置页入口）

    static func list() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: crashDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        // 显式 sorted(by:) 避免 iOS16 SDK 的 SortComparator 重载歧义
        let urls: [URL] = entries.filter { $0.pathExtension == "txt" }
        let sortedUrls: [URL] = urls.sorted(by: { l, r in
            let lv = try? l.resourceValues(forKeys: [.contentModificationDateKey])
            let rv = try? r.resourceValues(forKeys: [.contentModificationDateKey])
            return (lv?.contentModificationDate ?? Date.distantPast) > (rv?.contentModificationDate ?? Date.distantPast)
        })
        return sortedUrls.map { $0.path }
    }

    static func content(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? "(read failed)"
    }

    /// v2.9.177：分段读取预览——列表页不再全量读全文（大文件多次全读会卡死/内存抖），
    /// 详情页也限制最大字符数，避免超大 sig_ 文本把 Text 渲染拖崩。
    static func preview(_ path: String, maxChars: Int) -> String {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return "(read failed)" }
        if s.count > maxChars {
            return String(s.prefix(maxChars)) + "\n…(truncated, full content in the file)"
        }
        return s
    }

    static func clear() {
        try? FileManager.default.removeItem(at: crashDir)
    }
}

/// 崩溃日志查看页
struct CrashLogView: View {
    @State private var paths: [String] = []
    @State private var showDetail = false
    @State private var detailContent = ""
    @State private var toast: String?
    @State private var newestFirst = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    newestFirst.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: newestFirst ? "clock.fill" : "clock.arrow.circlepath")
                        Text(newestFirst ? L10n.t("i18n_856") : L10n.t("i18n_857")).font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 4)
            }
            List {
                if paths.isEmpty {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.shield")
                                .foregroundColor(.green)
                            Text(L10n.t("i18n_858"))
                                .font(.footnote)
                        }
                        .padding(.vertical, 8)
                    }
                } else {
                    Section(header: Text(L10n.t("i18n_859", paths.count, newestFirst ? "最新在前" : "最早在前"))) {
                        let displayed = newestFirst ? paths : Array(paths.reversed())
                        ForEach(displayed, id: \.self) { p in
                        Button {
                            detailContent = CrashCatcher.preview(p, maxChars: 60000)
                            showDetail = true
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(URL(fileURLWithPath: p).lastPathComponent)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                Text(CrashCatcher.preview(p, maxChars: 800))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(6)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.t("i18n_860"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { paths = CrashCatcher.list() }
        .overlay(alignment: .bottom) {
            if let toast = toast {
                Text(toast)
                    .font(.footnote)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.75), in: Capsule())
                    .foregroundColor(.white)
                    .padding(.bottom, 40)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                            self.toast = nil
                        }
                    }
            }
        }
        .sheet(isPresented: $showDetail) {
            NavigationView {
                // v2.9.292：空内容/读取失败给占位提示，不再纯白屏
                Group {
                    if detailContent.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary)
                            Text(L10n.t("i18n_861"))
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if detailContent == "(read failed)" {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 36))
                                .foregroundColor(.orange)
                            Text(L10n.t("i18n_862"))
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            Text(detailContent)
                                .font(.system(.footnote, design: .monospaced))
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .navigationTitle(L10n.t("i18n_863"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // v2.9.179：崩溃日志页彻底不弹分享面板——sig_1789582263 实证
                    // ShareSheet 枚举图标时 MobileIcons/CoreImage 系统级 Segfault（侧载环境）。
                    // 分享=复制+提示，保证用户永远能拿到日志。
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            UIPasteboard.general.string = detailContent
                            toast = L10n.t("i18n_864")
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(L10n.t("i18n_1180")) { showDetail = false }
                    }
                }
            }
        }
        .toolbar {
            // v2.9.179：同样只复制不弹分享面板
            ToolbarItem(placement: .navigationBarLeading) {
                if !paths.isEmpty {
                    Button {
                        UIPasteboard.general.string = CrashCatcher.exportAll()
                        toast = L10n.t("i18n_865", paths.count)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(L10n.t("ui_107")) {
                    CrashCatcher.clear()
                    paths = []
                    toast = L10n.t("i18n_866")
                }
                .disabled(paths.isEmpty)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = toast {
                Text(toast)
                    .font(.footnote)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.75))
                    .foregroundColor(.white)
                    .cornerRadius(16)
                    .padding(.bottom, 24)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.toast = nil }
                    }
            }
        }
    }
    }
}

extension String: Identifiable {
    public var id: String { self }
}
