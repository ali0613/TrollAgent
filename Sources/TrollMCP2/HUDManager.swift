import Foundation
import Darwin

/// 桌面悬浮 HUD 进程 pid 文件（HUDMainStart 写入）
private let PID_PATH = "/var/mobile/Library/Caches/trollagent.hud.pid"
/// start() 诊断日志（写到 /tmp，8790 终端 API 可直接 cat 读，确证 start 执行到哪步）
private let TMP_LOG = "/tmp/hud.start.log"

/// v6.0.4：桌面悬浮 HUD 提权 spawn 用 CLaunch（C 层 troll_launch_hud）——persona 99 提权在 C 里做
/// （posix_spawnattr_t 在 C 是 void*），Swift 只声明简单 C 签名（无类型混乱）。
@_silgen_name("troll_launch_hud")
func _troll_launch_hud(_ path: UnsafePointer<CChar>, _ argv: UnsafePointer<UnsafeMutablePointer<CChar>?>, _ persona: Int32) -> Int32

/// v6.0.8：Darwin notify 跨进程通知（libsystem_notify 的 notify_post）。Swift 默认作用域没有，
/// 用 @_silgen_name 直连 C 符号——主 App 用它通知 HUD 进程自己 _exit(0)（HUD 是 root，主 App 杀不动）。
@_silgen_name("notify_post")
func _notify_post(_ name: UnsafePointer<CChar>)

/// 桌面悬浮 HUD：单可执行双模式（TrollSpeed 正解）。
/// 主 App 可执行（TrollStore 有效签名）由 HUDManager 以 root persona 拉起，argv 带
/// -hud 进悬浮模式——复用主可执行的有效签名，AMFI 放行（独立二进制假签名被 106/109 拒的根因已消除）。
/// HUD 用无沙盒 + 系统 entitlements 创建全局系统窗口（放小女孩角色），
/// 由 HUD/sources/HUDApp.mm 管理 pid(/var/mobile/Library/Caches/trollagent.hud.pid)。
final class HUDManager {
    static let shared = HUDManager()
    private init() {}

    /// 最近一次启动失败原因（供设置页 subtitle 直接展示，避免盲猜）
    var lastStartError: String?

    /// posix_spawn 拉起且不等待/不超时——HUD 是常驻进程(runloop 不退出)，
    /// 用带 timeout 的 spawn 会在 15s 后 SIGKILL 把 HUD 杀掉(桌面悬浮窗刚建就消失)。
    /// detach：spawn 后立即返回，HUD 以独立进程常驻(父进程被 launchd 收养)。
    /// v6.0.4：改回 persona 99 提权(uid/gid 0)跑 HUD——TrollSpeed/TheBall 正解。
    /// 之前不提权 detach 让 HUD 以 mobile sandbox 身份跑，HUDMainStart 的
    /// UIApplicationInitialize/__completeAndRunAsPlugin 在 sandbox 下崩(step=enter 都没落盘)。
    /// 主 App 已有 platform-application + persona-mgmt entitlements，persona 99 不再报 106。
    private static let POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE: UInt32 = 1
    private func spawnDetached(_ path: String, args: [String]) -> Bool {
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path)] + args.map { strdup($0) }
        argv.append(nil)
        defer { for p in argv where p != nil { free(p) } }
        // persona 99 提权交给 CLaunch（C 层 troll_launch_hud）——主 App 有 platform-application+persona-mgmt。
        return argv.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return false }
            let rc = path.withCString { cs in
                _troll_launch_hud(cs, base, 1)
            }
            return rc == 0
        }
    }
    /// 最近一次启动日志写入 App 容器 Documents/hud.log + /var/mobile/Documents/hud.log
    /// （后者在 /var/mobile/Documents，8790 shell.exec 可直接 cat 读，便于 AI 连真机诊断）
    private let logURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: "/var/mobile")
        return docs.appendingPathComponent("hud.log")
    }()
    private let sysLogURL = URL(fileURLWithPath: "/var/mobile/Documents/hud.log")

    /// HUD 可执行路径：优先独立 HUD 二进制（v6.1.5-14e 回退——主可执行 -hud 实测起不来
    /// （早期即被 AMFI 拒），开关无法开启；独立 HUD 由 TrollStore 随主 App 重签可正常启动）。
    /// 数据/点击问题改由"全局文件数据通道 + 点击三保险"解决，不再依赖 HUD 的 App Group 权限。
    var hudBinaryPath: String? {
        let hudApp = Bundle.main.bundlePath + "/hud/TrollAgentHUD.app/TrollAgentHUD"
        if FileManager.default.fileExists(atPath: hudApp) { return hudApp }
        let p = Bundle.main.executablePath ?? ""
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// 主 App bundle 路径（供诊断显示）
    var bundlePath: String { Bundle.main.bundlePath }

    /// v6.1.5-5：HUD 版本同步——覆盖安装新包后 launchd KeepAlive 不会自动换新二进制，
    /// 旧 HUD 进程（内存里旧代码）继续跑，导致新功能（App Group 共享/菜单修复）不生效。
    /// 记录包内 HUD 二进制的 mtime，回前台/启动时若发现"运行中但二进制已更新"则强制重启。
    private let hudBinMtimeKey = "trollmcp2.hud_bin_mtime"
    func syncAfterUpdate() {
        guard isRunning else { return }
        guard let bin = hudBinaryPath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: bin),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return }
        let last = UserDefaults.standard.double(forKey: hudBinMtimeKey)
        if last > 0 && abs(mtime - last) > 1 {
            appendLog("HUD binary updated (mtime \(last) → \(mtime)); old process still running, force-restarting to swap")
            _ = forceStop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                if !self.isRunning { _ = self.start() }
            }
        }
        UserDefaults.standard.set(mtime, forKey: hudBinMtimeKey)
    }

    private func appendLog(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        let data = line.data(using: .utf8) ?? Data()
        // 主日志写 App Documents + /var/mobile/Documents
        for url in [logURL, sysLogURL] {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
        // 诊断副本写 /tmp（8790 终端 API 可直接 cat 读，确证 start 执行到哪步）
        let tmpURL = URL(fileURLWithPath: TMP_LOG)
        if let h = try? FileHandle(forWritingTo: tmpURL) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: tmpURL, options: .atomic)
        }
    }

    /// v4.5.9：launchctl 真实路径探测——iOS 各版本位置不一(/usr/bin 或 /usr/sbin /bin /sbin)。
    /// 逐路径探测，避免写死 /usr/bin 在部分 iOS 上 ENOENT。找不到返回 nil（subtitle 明确提示）。
    private var launchctlBinary: String? {
        for p in ["/usr/bin/launchctl", "/usr/sbin/launchctl", "/bin/launchctl", "/sbin/launchctl"] {
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    /// 是否在跑：直接读 pid 文件 + kill(pid,0) 检查进程存活。
    /// （不再用 spawnRoot(-check)：那是提权 persona 99，iOS16+TrollStore 下 errno 106，判断不可靠）
    var isRunning: Bool {
        guard let pidStr = try? String(contentsOfFile: PID_PATH, encoding: .utf8),
              let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// LaunchDaemon plist：TrollSpeed 主路径靠 launchctl load 拉起（launchd 以 root+App 类型 spawn，
    /// AMFI 放行）。posix_spawn persona 只是 plist 缺失时的兜底，直接走会 errno 106。
    /// 写到 App Documents 容器（100% 可写；launchctl load 支持任意路径，launchd 以 root 读）。
    private var daemonPlistPath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: "/var/mobile")
        return docs.appendingPathComponent("hudservices.plist").path
    }
    private let daemonLabel = "com.trollagent.hudservices"

    private func writeDaemonPlist(bin: String) -> Bool {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>EnablePressuredExit</key>
        \t<false/>
        \t<key>EnableTransactions</key>
        \t<false/>
        \t<key>EnvironmentVariables</key>
        \t<dict>
        \t\t<key>DISABLE_TWEAKS</key>
        \t\t<string>1</string>
        \t</dict>
        \t<key>GroupName</key>
        \t<string>wheel</string>
        \t<key>HighPriorityIO</key>
        \t<true/>
        \t<key>KeepAlive</key>
        \t<true/>
        \t<key>Label</key>
        \t<string>\(daemonLabel)</string>
        \t<key>POSIXSpawnType</key>
        \t<string>App</string>
        \t<key>ProcessType</key>
        \t<string>Interactive</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>\(bin)</string>
        \t\t<string>-hud</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>ThrottleInterval</key>
        \t<integer>5</integer>
        \t<key>UserName</key>
        \t<string>root</string>
        \t<key>_AdditionalProperties</key>
        \t<dict>
        \t\t<key>RunningBoard</key>
        \t\t<dict>
        \t\t\t<key>Managed</key>
        \t\t\t<false/>
        \t\t\t<key>Reported</key>
        \t\t\t<false/>
        \t\t</dict>
        \t</dict>
        </dict>
        </plist>
        """
        do {
            try xml.data(using: .utf8)?.write(to: URL(fileURLWithPath: daemonPlistPath), options: .atomic)
            appendLog("wrote daemon plist \(daemonPlistPath)")
            return true
        } catch {
            appendLog("write daemon plist FAIL: \(error)")
            return false
        }
    }

    @discardableResult
    func start() -> Bool {
        // v6.0.8 修复：先清掉旧进程，避免每次 start 叠加出多个悬浮角色。
        // （stop 可能因 kill root 权限/pid 文件陈旧而没杀干净，这里兜底强制清理）
        if isRunning { _ = forceStop() }
        guard let bin = hudBinaryPath else {
            lastStartError = "Main executable missing: \(bundlePath)"
            appendLog("start FAIL: main executable not found at \(bundlePath)")
            return false
        }
        appendLog("start: launching \(bin) -hud")

        // 主路径：写 LaunchDaemon plist + launchctl load（launchd 以 root+App 拉起，AMFI 放行）
        // v4.5.9：launchctl 路径探测——写死 /usr/bin 在部分 iOS 上 ENOENT 会误导诊断
        if let lctl = launchctlBinary {
            if writeDaemonPlist(bin: bin) {
                let (code, out) = InjectionManager.shared.spawnRoot(lctl, args: ["load", daemonPlistPath], timeout: 15)
                if code == 0 {
                    lastStartError = nil
                    appendLog("start OK via launchctl load (\(lctl))")
                    return true
                }
                appendLog("launchctl load errno=\(code) out=\(out) (\(lctl)) — falling back to posix_spawn")
            }
        } else {
            lastStartError = "launchctl binary not found (none in /usr/bin /usr/sbin /bin /sbin)"
            appendLog("start: launchctl not found in standard paths — using posix_spawn directly")
        }

        // 方案 B(TheBall)：不提权 posix_spawn detach 拉起 HUD（mobile 身份，常驻不 timeout）
        // ——避开 persona 99 的 errno 106；detach 不 waitpid 让 HUD 长期存活，不触发 15s SIGKILL。
        // HUD 显示全局窗口不靠 root，靠 accessibility-window-hosting entitlement（主可执行已带）。
        // v6.0.7：读设置里的悬浮尺寸（pt），-size N 传给 HUD 生效；读角色 -char 传 girl/rabit
        // v6.0.8 修复：GirlCharacter.rawValue 是中文（"小萝莉"/"兔娘"/"猫娘"），不能用 == "rabit" 判断——
        // 用 iconPrefix（loli→girl / rabit→rabit）得到正确的 HUD 图前缀
        // v6.0.12：走 GirlCharacter.stored(rawValue:) 兼容老用户旧值"御姐兔女郎"（映射 .rabit），避免升级后误拉 girl
        // v6.0.28：改成读可爱助手里的滑块值（170-300pt），去掉旧的设置页面悬浮尺寸
        let hudSize = UserDefaults.standard.double(forKey: "trollmcp2.girl_float_size")
        let sizeArg = (hudSize >= 170 && hudSize <= 300) ? Int(hudSize) : 200
        let charRaw = UserDefaults.standard.string(forKey: "trollmcp2.girl_character")
        let charArg = GirlCharacter.stored(rawValue: charRaw).iconPrefix
        if !spawnDetached(bin, args: ["-hud", "-char", charArg, "-size", "\(sizeArg)"]) {
            lastStartError = "Launch failed (posix_spawn detach)"
            appendLog("start FAIL: spawnDetached")
            return false
        }
        lastStartError = nil
        appendLog("start OK (posix_spawn detach, no privilege escalation, persistent, size=\(sizeArg), char=\(charArg))")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: bin),
           let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 {
            UserDefaults.standard.set(mtime, forKey: hudBinMtimeKey)
        }
        return true
    }

    @discardableResult
    func stop() -> Bool {
        // v6.0.8：先 notify_post 让 HUD 自己 _exit(0)——主 App(mobile) -exit 杀不掉 root HUD(EPERM)，
        // 设置开关关、切角色、调尺寸的 stop 都必须走 notify 自杀才关得掉。
        "com.trollagent.hud.exit".withCString { _notify_post($0) }
        usleep(300_000)
        // 主路径：launchctl unload
        if FileManager.default.fileExists(atPath: daemonPlistPath), let lctl = launchctlBinary {
            let (code, out) = InjectionManager.shared.spawnRoot(lctl, args: ["unload", daemonPlistPath], timeout: 15)
            appendLog("stop: launchctl unload code=\(code) out=\(out)")
            if code == 0 { return true }
        }
        guard let bin = hudBinaryPath else { return false }
        let (code, _) = InjectionManager.shared.spawn(bin, args: ["-exit"], timeout: 15)
        appendLog("stop: posix_spawn -exit code=\(code)")
        return code == 0
    }

    /// v6.0.8：强制停止——先 notify_post 让 HUD 自己 _exit(0)（主 App mobile 身份 kill 不掉 root 进程，
    /// 只能让 HUD 自己退；所有 HUD 进程都监听此通知，一次清掉全部避免叠加），再 -exit 兜底。
    /// 最后轮询确认进程没了，若还存活（pid 陈旧）读 pid 直接 SIGKILL。
    @discardableResult
    func forceStop() -> Bool {
        "com.trollagent.hud.exit".withCString { _notify_post($0) }
        usleep(300_000)
        _ = stop()
        // 轮询确认（最多 ~2s），若进程仍存活则强杀
        for _ in 0..<10 {
            if !isRunning { return true }
            usleep(200_000)
        }
        // 仍存活：读 pid 直接 SIGKILL（platform-application 有权杀 root）
        if let pidStr = try? String(contentsOfFile: PID_PATH, encoding: .utf8),
           let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGKILL)
            usleep(300_000)
        }
        let alive = isRunning
        appendLog("forceStop: alive=\(alive)")
        return !alive
    }
}
