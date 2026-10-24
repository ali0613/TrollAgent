import Foundation
import AVFoundation
import Combine
import CommonCrypto

/// v4.4.19：Edge TTS 朗读服务（流水线预取版）。
/// v7.2.0：直连微软 Edge TTS（去掉 Cloudflare Worker 中转——tts.trollagent.cc.cd 被墙 SNI 阻断，
/// speech.platform.bing.com 国内合规可达；照 edge-tts 原版：Sec-MS-GEC token + WebSocket 分片拼接）
/// - 夹子音：zh-CN-XiaoyiNeural + pitch +30Hz（用户选定）
/// - mp3 直接内存播放（AVAudioPlayer(data:)，不写文件 → 播完即丢）
/// - **流水线预取**：边播放当前句、边在后台合成下一句，句间无缝（实测串行每句干等 2-3s 会卡，预取消除空洞）
/// - 手动朗读(speakForced)打断当前自动朗读，只播指定文本
/// v7.2.1：三档音色预设（萝莉 / 猫娘御姐 / 兔娘）——用户试听定稿：
/// 萝莉 = Xiaoyi +15Hz +10%（原配置）
/// 猫娘 = Xiaoxiao -8Hz +0% 磁性御姐 + 句尾「喵~」
/// 兔娘 = Xiaoyi +5Hz +8% 温软 + 句尾「呜~」
/// 注意：微软 Edge TTS 现仅开放 Xiaoxiao/Xiaoyi 两个中文女声，档位靠音高/语速/口癖区分。
enum VoicePreset: String, CaseIterable {
    case loli, cat, bunny

    var voice: String {
        switch self {
        case .loli, .bunny: return "zh-CN-XiaoyiNeural"
        case .cat: return "zh-CN-XiaoxiaoNeural"
        }
    }
    var pitch: String {
        switch self {
        case .loli: return "+15Hz"
        case .cat: return "-8Hz"
        case .bunny: return "+5Hz"
        }
    }
    var rate: String {
        switch self {
        case .loli: return "+10%"
        case .cat: return "+0%"
        case .bunny: return "+8%"
        }
    }
    /// 句尾口癖（整段只在末尾加一次，避免每句都加很吵）
    var tailCatchphrase: String {
        switch self {
        case .loli: return ""
        case .cat: return "喵~"
        case .bunny: return "呜~"
        }
    }
    var displayName: String {
        switch self {
        case .loli: return "萝莉音"
        case .cat: return "猫娘音·御姐"
        case .bunny: return "兔娘音"
        }
    }
}

final class TTSService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = TTSService()

    @Published var speakerEnabled: Bool {
        didSet {
            UserDefaults.standard.set(speakerEnabled, forKey: "trollmcp2.tts_enabled")
            // v6.0.28：关开关立刻停止所有朗读，清空队列，不要继续播上一段的
            if !speakerEnabled {
                stopInternal()
            }
        }
    }
    /// v7.2.1：当前音色档位（长按全局喇叭切换，持久化）
    @Published var voicePreset: VoicePreset {
        didSet {
            UserDefaults.standard.set(voicePreset.rawValue, forKey: "trollmcp2.tts_voice")
        }
    }
    @Published var isSpeaking = false {
        didSet { if !isSpeaking { speakingId = nil } }
    }
    /// 当前手动朗读的消息 id（气泡喇叭高亮用；流式自动朗读不设）
    @Published var speakingId: String?

    private static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let wsBaseURL = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
    private static let windowsTick: Int64 = 116444736000000000
    private static let gecOffset: Int64 = Int64(0.6 * 1e7)

    /// 待合成文本队列（有序，按句切分）
    private var pendingTexts: [String] = []
    /// 已合成好的 mp3 数据（有序，就绪即播）
    private var readyChunks: [Data] = []
    private var player: AVAudioPlayer?
    private var isSynthBusy = false

    private override init() {
        speakerEnabled = UserDefaults.standard.bool(forKey: "trollmcp2.tts_enabled")
        voicePreset = VoicePreset(rawValue: UserDefaults.standard.string(forKey: "trollmcp2.tts_voice") ?? "") ?? .loli
        super.init()
    }

    // MARK: - 对外

    /// v7.2.1：整段句尾加一次口癖（喵~/呜~）——自动朗读的句子流最后一句自然带上
    private func withCatchphrase(_ t: String) -> String {
        let p = voicePreset.tailCatchphrase
        guard !p.isEmpty else { return t }
        return t.trimmingCharacters(in: .whitespacesAndNewlines) + p
    }

    /// 自动朗读（受全局喇叭开关控制）：流式分句送进来，排队流水线播放
    func speak(_ text: String) {
        guard speakerEnabled else { return }
        enqueueSentences(cleanForSpeech(withCatchphrase(text)))
    }

    /// 手动朗读（无视开关，打断当前自动朗读，只播这段）——整段已完整，一次合成后连续播完（实测100字3s/500字约6s，比逐句更快）
    func speakForced(id: String?, _ text: String) {
        stopInternal()
        let t = cleanForSpeech(withCatchphrase(text)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        speakingId = id
        isSynthBusy = true
        synthesize(t) { [weak self] data in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSynthBusy = false
                guard let data, data.count > 100 else { return }
                self.readyChunks.append(data)
                self.pump()
            }
        }
    }

    func stop() { stopInternal() }

    // MARK: - 队列

    private func enqueueSentences(_ text: String) {
        for s in splitSentences(text) where !s.isEmpty { pendingTexts.append(s) }
        pump()
    }

    private func stopInternal() {
        pendingTexts.removeAll()
        readyChunks.removeAll()
        player?.stop()
        player = nil
        isSynthBusy = false
        isSpeaking = false
    }

    /// 主泵：确保①有就绪 mp3 就播放；②合成器空闲且有待合成文本就预取下一个（边播边合成，流水线）
    private func pump() {
        // ① 播放就绪的下一句（player 为 nil 表示上一句播完或尚未开播）
        if player == nil, !readyChunks.isEmpty {
            let data = readyChunks.removeFirst()
            startPlay(data)
        } else if player == nil {
            isSpeaking = false   // 没有就绪也没在播 → 整段播完（结束朗读）
        }
        // ② 合成器空闲则预取下一个（这句合成期间，当前句正在播放 → 句间无缝）
        if !isSynthBusy, !pendingTexts.isEmpty {
            let text = pendingTexts.removeFirst()
            isSynthBusy = true
            synthesize(text) { [weak self] data in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isSynthBusy = false
                    if let data, data.count > 100 { self.readyChunks.append(data) }
                    self.pump()   // 合成完再泵：播就绪的 + 继续预取
                }
            }
        }
    }

    private func startPlay(_ data: Data) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            player = p
            isSpeaking = true
            p.play()
        } catch {
            player = nil
            pump()   // 播放失败，跳过继续下一个
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        pump()   // 播完 → 播下一句（已预取）+ 继续预取再下一句
    }

    // MARK: - 合成（v7.2.0：直连微软 Edge TTS，照 edge-tts 原版）

    /// edge-tts 的 Sec-MS-GEC 算法：tick = WINDOWS_TICK + 当前时间(1e7) - 偏移 → SHA256(tick+token) 大写
    private func secMsGec() -> (gec: String, ts: String) {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1e7)
        let tick = Self.windowsTick + timestamp - Self.gecOffset
        let gec = sha256Hex("\(tick)\(Self.trustedClientToken)").uppercased()
        return (gec, "\(timestamp - Self.gecOffset)")
    }

    private func sha256Hex(_ s: String) -> String {
        let d = Data(s.utf8)
        var h = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        d.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(d.count), &h) }
        return h.map { String(format: "%02x", $0) }.joined()
    }

    /// SSML 文本转义（& < > " '）
    private func xmlEscape(_ s: String) -> String {
        var o = s.replacingOccurrences(of: "&", with: "&amp;")
        o = o.replacingOccurrences(of: "<", with: "&lt;")
        o = o.replacingOccurrences(of: ">", with: "&gt;")
        o = o.replacingOccurrences(of: "\"", with: "&quot;")
        o = o.replacingOccurrences(of: "'", with: "&apos;")
        return o
    }

    private func synthesize(_ text: String, completion: @escaping (Data?) -> Void) {
        let (gec, gecTs) = secMsGec()
        let connId = UUID().uuidString
        // v7.2.1：按当前音色档位取声线/音高/语速
        let v = voicePreset.voice, p = voicePreset.pitch, r = voicePreset.rate
        guard let url = URL(string: "\(Self.wsBaseURL)?TrustedClientToken=\(Self.trustedClientToken)&ConnectionId=\(connId)") else {
            completion(nil); return
        }
        var req = URLRequest(url: url)
        req.setValue(gec, forHTTPHeaderField: "Sec-MS-GEC")
        req.setValue(gecTs, forHTTPHeaderField: "Sec-MS-GEC-Timestamp")
        req.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/103.0.5060.66 Safari/537.36 Edg/103.0.1264.44", forHTTPHeaderField: "User-Agent")
        // v7.2.2：theos SDK 无 webSocketTask(with:subprotocols:)（iOS15+ 重载），改单参 + 子协议 header 透传
        req.setValue("speech-synthesis", forHTTPHeaderField: "Sec-WebSocket-Protocol")

        let session = URLSession(configuration: .ephemeral)
        let ws = session.webSocketTask(with: req)
        ws.resume()

        let ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'><voice name='\(v)'><prosody pitch='\(p)' rate='\(r)' volume='+0%'>\(xmlEscape(text))</prosody></voice></speak>"
        let msg: [String: Any] = [
            "context": [
                "synthesis": [
                    "audio": [
                        "metadataoptions": ["sentenceBoundaryEnabled": "false", "wordBoundaryEnabled": "true"],
                        "outputFormat": "audio-24khz-48kbitrate-mono-mp3"
                    ]
                ]
            ],
            "message": [
                "locale": "zh-CN", "market": "zh-CN",
                "voice": v, "service": "edge-tts",
                "text": text, "ssml": ssml
            ]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: msg),
              let json = String(data: body, encoding: .utf8) else { completion(nil); return }
        let payload = "X-Timestamp:\(Date().timeIntervalSince1970)\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.synthesize\r\n\r\n\(json)"

        var audio = Data()
        var finished = false
        let timeoutWork = DispatchWorkItem { [weak ws] in
            guard !finished else { return }
            finished = true
            ws?.cancel()
            completion(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 40, execute: timeoutWork)

        func receiveLoop() {
            ws.receive { result in
                switch result {
                case .success(let message):
                    switch message {
                    case .data(let d):
                        audio.append(d)
                        receiveLoop()
                    case .string(let s):
                        if s.contains("Path:turn.end") || s.contains("turn.end") {
                            guard !finished else { return }
                            finished = true
                            timeoutWork.cancel()
                            ws.cancel()
                            completion(audio.count > 100 ? audio : nil)
                        } else {
                            receiveLoop()
                        }
                    @unknown default:
                        receiveLoop()
                    }
                case .failure:
                    guard !finished else { return }
                    finished = true
                    timeoutWork.cancel()
                    completion(audio.count > 100 ? audio : nil)
                }
            }
        }
        ws.send(.string(payload)) { err in
            if err != nil {
                guard !finished else { return }
                finished = true
                timeoutWork.cancel()
                ws.cancel()
                completion(nil)
            } else {
                receiveLoop()
            }
        }
    }

    /// 按中文/英文句末标点与换行切分
    func splitSentences(_ t: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in t {
            current.append(ch)
            if "。！？!?\n…".contains(ch) {
                let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { result.append(s) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    /// 朗读前清洗：去掉 markdown 标记/链接/括号/星号/竖线等格式符号，只留文字（避免 Edge TTS 把 * - （） # 等读出来）
    private func cleanForSpeech(_ t: String) -> String {
        var s = t
        // 行内代码/反引号
        s = s.replacingOccurrences(of: "`", with: "")
        // 链接 [text](url) → text
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // 行首 markdown 标记（标题#/列表-*/引用>）
        s = s.replacingOccurrences(of: #"(?m)^[ \t]*[#>*+-][ \t]*"#, with: "", options: .regularExpression)
        // 表格分隔行 |---| 整行去掉
        s = s.replacingOccurrences(of: #"(?m)^[ \t]*\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$"#, with: "", options: .regularExpression)
        // 残留星号/下划线/井号
        s = s.replacingOccurrences(of: #"[*_]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "#", with: "")
        // 表格竖线（保留单元格内容）
        s = s.replacingOccurrences(of: "|", with: "")
        // 括号符号本身去掉（保留内部文字），中英括号都处理
        s = s.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        s = s.replacingOccurrences(of: "（", with: "").replacingOccurrences(of: "）", with: "")
        // 数学符号转读法
        s = s.replacingOccurrences(of: "×", with: "乘").replacingOccurrences(of: "÷", with: "除以")
        // 压缩连续空白与空行
        s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
