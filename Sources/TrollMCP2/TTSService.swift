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
    // v7.2.4：原版 edge-tts 算法【无偏移】——tick = epoch刻度 + WINDOWS_TICK；
    // 旧版多减 0.6e7 导致 Sec-MS-GEC 与微软校验不符 → 403 → 合成失败无声音（用户实测聊天界面播放无声根因）
    private static let gecOffset: Int64 = 0

    /// 待合成文本队列（有序，按句切分）
    private var pendingTexts: [String] = []
    /// 已合成好的 mp3 数据（有序，就绪即播）
    private var readyChunks: [Data] = []
    private var player: AVAudioPlayer?
    private var isSynthBusy = false
    /// v7.1.33：WS 长连接复用（根治逐句合成高频握手被微软限流/静默断）——同一连接串行收发，断线自动重连
    private var wsTask: URLSessionWebSocketTask?
    private var wsSession: URLSession?
    private var sentenceCompletion: ((Data?) -> Void)?
    private var currentAudio = Data()
    private var sentenceTimeout: DispatchWorkItem?

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
            let ok = p.play()
            ttsLog("play: data=\(data.count) play()=\(ok)")
        } catch {
            ttsLog("FAIL: play error=\(error.localizedDescription)")
            player = nil
            pump()   // 播放失败，跳过继续下一个
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        pump()   // 播完 → 播下一句（已预取）+ 继续预取再下一句
    }

    // MARK: - 合成（v7.2.0：直连微软 Edge TTS，照 edge-tts 原版）

    // MARK: - v2 Sec-MS-GEC（edge-tts 2.x DRM 完整移植，2026-10-25 用户电脑实证：v1 算法微软已拒 403，
    // v2 格式 cs64-sha256 + Sec-MS-GEC-Version + 长 voice 名 + SSML 直发 payload 才能出音频）

    private static let winEpochSec: Double = 11644473600.0
    private static let gecVersion = "2-143.0.3650.75"

    // ---- 魔改 SHA-256 常量（edge-tts drm.py 原值）----
    private static let sha256Initial: [UInt32] = [0x6A09E667,0xBB67AE85,0x3C6EF372,0xA54FF53A,0x510E527F,0x9B05688C,0x1F83D9AB,0x5BE0CD19]
    private static let sha256State: [UInt32] = [0xFD9FBEA2,0x91243CE7,0xBE499094,0xCD2E1E0A,0x6C006F49,0x04BD35AB,0xFEB0A7E4,0x03EFFBD2]
    private static let sha256Schedule: [UInt32] = [0xEB24BF9E,0x1558691F,0xA0C09EE2,0x0CFA32BA,0xA622EE8C,0xD1DD9491,0xC0DD25A0,0xF9E70AB6,0xF0C31573,0x7058CE4E,0x7188E606,0x00E5AB33,0xD258B060,0x72766564]
    private static let sha256RoundConstants: [UInt32] = [0x428A2F98,0x71374491,0xB5C0FBCF,0xE9B5DBA5,0x3956C25B,0x59F111F1,0x923F82A4,0xAB1C5ED5,0xD807AA98,0x12835B01,0x243185BE,0x550C7DC3,0x72BE5D74,0x80DEB1FE,0x9BDC06A7,0xC19BF174,0xE49B69C1,0xEFBE4786,0x0FC19DC6,0x240CA1CC,0x2DE92C6F,0x4A7484AA,0x5CB0A9DC,0x76F988DA,0x983E5152,0xA831C66D,0xB00327C8,0xBF597FC7,0xC6E00BF3,0xD5A79147,0x06CA6351,0x14292967,0x27B70A85,0x2E1B2138,0x4D2C6DFC,0x53380D13,0x650A7354,0x766A0ABB,0x81C2C92E,0x92722C85,0xA2BFE8A1,0xA81A664B,0xC24B8B70,0xC76C51A3,0xD192E819,0xD6990624,0xF40E3585,0x106AA070,0x19A4C116,0x1E376C08,0x2748774C,0x34B0BCB5,0x391C0CB3,0x4ED8AA4A,0x5B9CCA4F,0x682E6FF3,0x748F82EE,0x78A5636F,0x84C87814,0x8CC70208,0x90BEFFFA,0xA4506CEB,0xBEF9A3F7,0xC67178F2]
    private static let sha256Adjustment: UInt32 = 0xC9DC06A7
    private static let sha256BlockConstants: [UInt32] = Array(sha256RoundConstants[0..<14]) + [sha256Adjustment] + Array(sha256RoundConstants[15...])
    private static let sha256Sigma0Adjustment: UInt32 = 0x059C0B80
    private static let sha256Sigma1Adjustment: UInt32 = 0x000B92C0
    private static let cs64Coefficients: [(UInt32, UInt32)] = [
        (0xE82E91B1,0xB32700D0),(0x44DE24C6,0x88DFF51D),(0x3BEB65BC,0x29514038),(0xC89C5933,0xB328CBDF),
        (0x8D1EC211,0xD405B4D5),(0x314EF5D5,0x26E55F3C),(0xE92491B1,0x607801C6),(0xF0A5B9D5,0x82B2C1FB),
        (0x06064CF3,0xFA51A3DA),(0xDA79FA60,0x207CC464),(0xBED20560,0x3C3C74F3),(0x89F9C9F8,0xD2D14B61),
        (0x35FA38C6,0xBB04A2C1),(0xCB49E3C6,0xC5626167)]
    private static let cs64Factor: UInt32 = 0x82893933
    private static let cs64Adjustment0: UInt32 = 0xF2F90B1A
    private static let cs64Adjustment1: UInt32 = 0x0B1A0000
    private static let u32Mask: UInt32 = 0xFFFFFFFF

    private static func rol16(_ v: UInt32) -> UInt32 { ((v &<< 16) | (v &>> 16)) & u32Mask }
    private static func sigma0(_ v: UInt32) -> UInt32 { ((v &>> 7) ^ (v &<< 25) ^ (v &>> 18) ^ (v &<< 14) ^ (v &>> 3)) & u32Mask }
    private static func sigma1(_ v: UInt32) -> UInt32 { ((v &>> 17) ^ (v &<< 15) ^ (v &>> 19) ^ (v &<< 13) ^ (v &>> 10)) & u32Mask }

    private static func expandSchedule(_ words: inout [UInt32], from firstWord: Int) {
        for index in firstWord..<64 {
            let x = words[index - 2], y = words[index - 15]
            let s1 = ((x &>> 17) ^ (x &<< 15) ^ (x &>> 19) ^ (x &<< 13) ^ (x &>> 10)) & u32Mask
            let s0 = ((y &>> 7) ^ (y &<< 25) ^ (y &>> 18) ^ (y &<< 14) ^ (y &>> 3)) & u32Mask
            words.append((s1 &+ words[index - 7] &+ s0 &+ words[index - 16]) & u32Mask)
        }
    }

    private static func sha256Rounds(_ stateIn: [UInt32], _ words: [UInt32], firstRound: Int) -> [UInt32] {
        var (a,b,c,d,e,f,g,h) = (stateIn[0],stateIn[1],stateIn[2],stateIn[3],stateIn[4],stateIn[5],stateIn[6],stateIn[7])
        let constants = (firstRound == 14) ? sha256BlockConstants : sha256RoundConstants
        let aligned = min(64, ((firstRound + 7) / 8) * 8)
        for index in firstRound..<aligned {
            let rotE = UInt64(e) * 0x100000001
            let rotA = UInt64(a) * 0x100000001
            let sA = UInt64(h) &+ ((rotE &>> 6) ^ (rotE &>> 11) ^ (rotE &>> 25)) &+ UInt64(g ^ (e & (f ^ g))) &+ UInt64(constants[index]) &+ UInt64(words[index])
            let t1 = sA & 0xFFFFFFFF
            let sB = ((rotA &>> 2) ^ (rotA &>> 13) ^ (rotA &>> 22)) &+ UInt64((a & b) | (c & (a | b)))
            let t2 = sB & 0xFFFFFFFF
            let na = UInt32((t1 &+ t2) & 0xFFFFFFFF)
            let nd = UInt32((UInt64(d) &+ t1) & 0xFFFFFFFF)
            (a,b,c,d,e,f,g,h) = (na,a,b,c,nd,e,f,g)
        }
        var index = aligned
        while index < 64 {
            // 轮 1
            var rotE = UInt64(e) * 0x100000001
            var rotA = UInt64(a) * 0x100000001
            var t1 = (UInt64(h) &+ ((rotE &>> 6) ^ (rotE &>> 11) ^ (rotE &>> 25)) &+ UInt64(g ^ (e & (f ^ g))) &+ UInt64(constants[index]) &+ UInt64(words[index])) & 0xFFFFFFFF
            let d1 = UInt32((UInt64(d) &+ t1) & 0xFFFFFFFF)
            let h1Sum = t1 &+ ((rotA &>> 2) ^ (rotA &>> 13) ^ (rotA &>> 22)) &+ UInt64((a & b) | (c & (a | b)))
            let h1 = UInt32(h1Sum & 0xFFFFFFFF)
            // 轮 2
            rotE = UInt64(d1) * 0x100000001
            rotA = UInt64(h1) * 0x100000001
            t1 = (UInt64(g) &+ ((rotE &>> 6) ^ (rotE &>> 11) ^ (rotE &>> 25)) &+ UInt64(f ^ (d1 & (e ^ f))) &+ UInt64(constants[index + 1]) &+ UInt64(words[index + 1])) & 0xFFFFFFFF
            let c1 = UInt32((UInt64(c) &+ t1) & 0xFFFFFFFF)
            let g1Sum = t1 &+ ((rotA &>> 2) ^ (rotA &>> 13) ^ (rotA &>> 22)) &+ UInt64((h1 & a) | (b & (h1 | a)))
            let g1 = UInt32(g1Sum & 0xFFFFFFFF)
            // 轮 3
            rotE = UInt64(c1) * 0x100000001
            rotA = UInt64(g1) * 0x100000001
            t1 = (UInt64(f) &+ ((rotE &>> 6) ^ (rotE &>> 11) ^ (rotE &>> 25)) &+ UInt64(e ^ (c1 & (d1 ^ e))) &+ UInt64(constants[index + 2]) &+ UInt64(words[index + 2])) & 0xFFFFFFFF
            let b1 = UInt32((UInt64(b) &+ t1) & 0xFFFFFFFF)
            let f1Sum = t1 &+ ((rotA &>> 2) ^ (rotA &>> 13) ^ (rotA &>> 22)) &+ UInt64((g1 & h1) | (a & (g1 | h1)))
            let f1 = UInt32(f1Sum & 0xFFFFFFFF)
            // 轮 4
            rotE = UInt64(b1) * 0x100000001
            rotA = UInt64(f1) * 0x100000001
            t1 = (UInt64(e) &+ ((rotE &>> 6) ^ (rotE &>> 11) ^ (rotE &>> 25)) &+ UInt64(d1 ^ (b1 & (c1 ^ d1))) &+ UInt64(constants[index + 3]) &+ UInt64(words[index + 3])) & 0xFFFFFFFF
            let a1 = UInt32((UInt64(a) &+ t1) & 0xFFFFFFFF)
            let e1Sum = t1 &+ ((rotA &>> 2) ^ (rotA &>> 13) ^ (rotA &>> 22)) &+ UInt64((f1 & g1) | (h1 & (f1 | g1)))
            let e1 = UInt32(e1Sum & 0xFFFFFFFF)
            // 轮 5
            rotE = UInt64(a1) * 0x100000001
            rotA = UInt64(e1) * 0x100000001
            t1 = (UInt64(d1) &+ ((rotE &>> 6) ^ (rotE &>> 11) ^ (rotE &>> 25)) &+ UInt64(c1 ^ (a1 & (b1 ^ c1))) &+ UInt64(constants[index + 4]) &+ UInt64(words[index + 4])) & 0xFFFFFFFF
            let h2 = UInt32((UInt64(h1) &+ t1) & 0xFFFFFFFF)
            let d2Sum = t1 &+ ((rotA &>> 2) ^ (rotA &>> 13) ^ (rotA &>> 22)) &+ UInt64((e1 & f1) | (g1 & (e1 | f1)))
            let d2 = UInt32(d2Sum & 0xFFFFFFFF)
            // 轮 6
            rotE = UInt64(h2) * 0x100000001
            rotA = UInt64(d2) * 0x100000001
            t1 = (UInt64(c1) &+ ((rotE &>> 6) ^ (rotE &>> 11) ^ (rotE &>> 25)) &+ UInt64(b1 ^ (h2 & (a1 ^ b1))) &+ UInt64(constants[index + 5]) &+ UInt64(words[index + 5])) & 0xFFFFFFFF
            let g2 = UInt32((UInt64(g1) &+ t1) & 0xFFFFFFFF)
            let c2Sum = t1 &+ ((rotA &>> 2) ^ (rotA &>> 13) ^ (rotA &>> 22)) &+ UInt64((d2 & e1) | (f1 & (d2 | e1)))
            let c2 = UInt32(c2Sum & 0xFFFFFFFF)
            // 轮 7
            rotE = UInt64(g2) * 0x100000001
            rotA = UInt64(c2) * 0x100000001
            t1 = (UInt64(b1) &+ ((rotE &>> 6) ^ (rotE &>> 11) ^ (rotE &>> 25)) &+ UInt64(a1 ^ (g2 & (h2 ^ a1))) &+ UInt64(constants[index + 6]) &+ UInt64(words[index + 6])) & 0xFFFFFFFF
            let f2 = UInt32((UInt64(f1) &+ t1) & 0xFFFFFFFF)
            let b2Sum = t1 &+ ((rotA &>> 2) ^ (rotA &>> 13) ^ (rotA &>> 22)) &+ UInt64((c2 & d2) | (e1 & (c2 | d2)))
            let b2 = UInt32(b2Sum & 0xFFFFFFFF)
            // 轮 8
            rotE = UInt64(f2) * 0x100000001
            rotA = UInt64(b2) * 0x100000001
            t1 = (UInt64(a1) &+ ((rotE &>> 6) ^ (rotE &>> 11) ^ (rotE &>> 25)) &+ UInt64(h2 ^ (f2 & (g2 ^ h2))) &+ UInt64(constants[index + 7]) &+ UInt64(words[index + 7])) & 0xFFFFFFFF
            let e2 = UInt32((UInt64(e1) &+ t1) & 0xFFFFFFFF)
            let a2Sum = t1 &+ ((rotA &>> 2) ^ (rotA &>> 13) ^ (rotA &>> 22)) &+ UInt64((b2 & c2) | (d2 & (b2 | c2)))
            let a2 = UInt32(a2Sum & 0xFFFFFFFF)
            (a,b,c,d,e,f,g,h) = (a2,b2,c2,d2,e2,f2,g2,h2)
            index += 8
        }
        return [a,b,c,d,e,f,g,h]
    }

    private static func sha256Init(_ seed: Data) -> [UInt32] {
        var words = [UInt32](repeating: 0, count: 14)
        words.append((UInt32(seed[seed.startIndex]) &<< 16) | (UInt32(seed[seed.startIndex + 1]) &<< 8) | UInt32(seed[seed.startIndex + 2]))
        words.append((UInt32(seed[seed.startIndex + 3]) &<< 24) | (UInt32(seed[seed.startIndex + 4]) &<< 16) | (UInt32(seed[seed.startIndex + 5]) &<< 8) | UInt32(seed[seed.startIndex + 6]))
        for index in 16..<30 {
            var value = sha256Schedule[index - 16]
            if index - 2 >= 14 {
                value &+= (index == 16) ? (sigma1(words[index - 2]) ^ sha256Sigma1Adjustment) : sigma1(words[index - 2])
            }
            if index - 7 >= 14 { value &+= words[index - 7] }
            if index - 15 >= 14 {
                value &+= (index == 29) ? (sigma0(words[index - 15]) ^ sha256Sigma0Adjustment) : sigma0(words[index - 15])
            }
            words.append(value & u32Mask)
        }
        let last = (sigma1(words[28]) &+ words[23] &+ sigma0(words[15]) &+ words[14] &+ sha256Adjustment &- sha256RoundConstants[14]) & u32Mask
        words.append(last)
        expandSchedule(&words, from: 31)
        let working = sha256Rounds(sha256State, words, firstRound: 14)
        return (0..<8).map { (sha256Initial[$0] &+ working[$0]) & u32Mask }
    }

    private static func sha256Digest(_ data: Data) -> [UInt8] {
        let seed = data[data.startIndex..<data.startIndex + 7]
        let length = 57 + data.count
        var padded = Array(data.dropFirst(7))
        padded.append(0x80)
        var padCount = (55 - length) % 64
        if padCount < 0 { padCount += 64 }
        padded.append(contentsOf: [UInt8](repeating: 0, count: padCount))
        let lenBits = UInt64(length) * 8
        for i in stride(from: 56, through: 0, by: -8) { padded.append(UInt8((lenBits >> UInt64(i)) & 0xFF)) }
        var state = sha256Init(seed)
        var offset = 0
        while offset < padded.count {
            var words = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let o = offset + i * 4
                words[i] = (UInt32(padded[o]) &<< 24) | (UInt32(padded[o + 1]) &<< 16) | (UInt32(padded[o + 2]) &<< 8) | UInt32(padded[o + 3])
            }
            expandSchedule(&words, from: 16)
            let working = sha256Rounds(state, words, firstRound: 0)
            state = (0..<8).map { (state[$0] &+ working[$0]) & u32Mask }
            offset += 64
        }
        var out = [UInt8]()
        for w in state {
            out.append(UInt8((w >> 24) & 0xFF)); out.append(UInt8((w >> 16) & 0xFF)); out.append(UInt8((w >> 8) & 0xFF)); out.append(UInt8(w & 0xFF))
        }
        return out
    }

    private static func wordsLe4Even(_ data: Data) -> [UInt32] {
        var padded = Array(data)
        while padded.count % 4 != 0 { padded.append(0) }
        var words = [UInt32]()
        var i = 0
        while i < padded.count {
            words.append((UInt32(padded[i])) | (UInt32(padded[i + 1]) &<< 8) | (UInt32(padded[i + 2]) &<< 16) | (UInt32(padded[i + 3]) &<< 24))
            i += 4
        }
        if words.count % 2 == 1 { words.append(0) }
        return words
    }

    private static func cs64Digest(_ data: Data, _ digest: [UInt8]) -> (UInt32, UInt32) {
        let keyA = ((UInt32(digest[0])) | (UInt32(digest[1]) &<< 8) | (UInt32(digest[2]) &<< 16) | (UInt32(digest[3]) &<< 24)) | 1
        let keyB = ((UInt32(digest[4])) | (UInt32(digest[5]) &<< 8) | (UInt32(digest[6]) &<< 16) | (UInt32(digest[7]) &<< 24)) | 1
        var factors = [keyA &* cs64Factor & u32Mask, keyB &* cs64Factor & u32Mask]
        var terms = [UInt32](), offsets = [UInt32]()
        for (coef, off) in cs64Coefficients {
            terms.append((coef &* factors[terms.count % 2]) & u32Mask)
            offsets.append(off)
        }
        var data2 = Data([0x00]); data2.append(data)
        let words = wordsLe4Even(data2)
        for (i, word) in words.enumerated() {
            var term = (word &* (i % 2 == 0 ? keyA : keyB)) & u32Mask
            var off = (rol16(word) &* (i % 2 == 0 ? 0xEF0569FB : 0xC31713DB)) & u32Mask
            if i == 0 {
                term = (term &+ (cs64Adjustment0 &* factors[0])) & u32Mask
                off = (off &+ cs64Adjustment1) & u32Mask
            }
            terms.append(term)
            offsets.append(off)
        }
        var swapAcc: UInt32 = 0, swapLast: UInt32 = 0, state: UInt32 = 0, acc: UInt32 = 0
        var i = 0
        while i < terms.count {
            let x = terms[i], y = terms[i + 1]
            var t = rol16((offsets[i] &+ x) & u32Mask)
            var q = (t &* 0x76F50F34) & u32Mask
            swapAcc = (swapAcc &+ ((rol16(q) &* 0xC3EFEA97) &+ q)) & u32Mask
            t = rol16((offsets[i + 1] &+ y) & u32Mask)
            q = (t &* 0x1881CE3C) & u32Mask
            swapLast = ((rol16(q) &* 0x35BD1EC9) &+ q) & u32Mask
            swapAcc = (swapAcc &+ swapLast) & u32Mask
            state = (state &* keyA &+ x) & u32Mask
            state = (rol16(state) &* 0xCF98B111) & u32Mask
            state = (rol16(state) &* 0x87085B9F) & u32Mask
            state = (rol16(state) &* 0x12CEB96D) & u32Mask
            state = (rol16(state) &* 0x257E1D83) & u32Mask
            acc = (acc &+ state) & u32Mask
            var tt = (state &* keyB &+ y) & u32Mask
            tt = (rol16(tt) &* 0xA27416F5) & u32Mask
            tt = (rol16(tt) &* 0xD38396FF) & u32Mask
            state = (rol16((rol16(tt) &* 0x7C932B89) & u32Mask) &* 0xBFA49F69) & u32Mask
            acc = (acc &+ state) & u32Mask
            i += 2
        }
        return (swapLast ^ state, swapAcc ^ acc)
    }

    private static func tokenHash(_ data: Data) -> (cs64: String, sha256: String) {
        let digest = sha256Digest(data)
        let cs = cs64Digest(data, digest)
        var csData = [UInt8]()
        csData.append(UInt8(cs.0 & 0xFF)); csData.append(UInt8((cs.0 >> 8) & 0xFF)); csData.append(UInt8((cs.0 >> 16) & 0xFF)); csData.append(UInt8((cs.0 >> 24) & 0xFF))
        csData.append(UInt8(cs.1 & 0xFF)); csData.append(UInt8((cs.1 >> 8) & 0xFF)); csData.append(UInt8((cs.1 >> 16) & 0xFF)); csData.append(UInt8((cs.1 >> 24) & 0xFF))
        let csHex = csData.map { String(format: "%02X", $0) }.joined()
        let shaHex = digest.map { String(format: "%02X", $0) }.joined()
        return (csHex, shaHex)
    }

    /// 生成 v2 Sec-MS-GEC token（格式 "cs64-sha256"，5 分钟取整，无偏移）
    private func secMsGecV2(_ unixTs: Double = Date().timeIntervalSince1970) -> String {
        var ticks = unixTs + Self.winEpochSec
        ticks -= ticks.truncatingRemainder(dividingBy: 300)
        ticks *= 1e7
        let strToHash = "\(UInt64(ticks))\(Self.trustedClientToken)"
        let (cs64, sha256) = Self.tokenHash(Data(strToHash.utf8))
        return "\(cs64)-\(sha256)"
    }

    /// edge-tts 2.x JS 日期格式（SSML X-Timestamp 必需，微软 bug：必须带 Z）
    private func jsDateString(_ d: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = cal.dateComponents([.weekday, .month, .day, .year, .hour, .minute, .second], from: d)
        let weekdays = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"]
        let months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        return String(format: "%@ %@ %02d %04d %02d:%02d:%02d GMT+0000 (Coordinated Universal Time)",
                      weekdays[c.weekday! - 1], months[c.month! - 1], c.day!, c.year!, c.hour!, c.minute!, c.second!)
    }

    /// voice 长名（微软服务端 2.x 只认长名，短名 turn.start 后静默无音频）
    private var fullVoiceName: String {
        switch voicePreset.voice {
        case "zh-CN-XiaoyiNeural": return "Microsoft Server Speech Text to Speech Voice (zh-CN, XiaoyiNeural)"
        case "zh-CN-XiaoxiaoNeural": return "Microsoft Server Speech Text to Speech Voice (zh-CN, XiaoxiaoNeural)"
        default: return voicePreset.voice
        }
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


    // MARK: - v7.2.5 TTS 调试日志（写 /var/mobile/Documents/tts_debug.log，用户复现后发我定位）
    /// v7.1.33：内存环形缓冲（UI 长按顶部喇叭直接看最近日志，绕开沙箱读文件通道）
    @Published var recentTTSLogs: [String] = []
    private func ttsLog(_ s: String) {
        let line = "[TTS] \(Date()) \(s)\n"
        // 内存缓冲（UI 可见）
        DispatchQueue.main.async {
            self.recentTTSLogs.append(line)
            if self.recentTTSLogs.count > 40 { self.recentTTSLogs.removeFirst(self.recentTTSLogs.count - 40) }
        }
        // 文件落盘（保留原有通道）
        if let url = URL(string: "file:///var/mobile/Documents/tts_debug.log") {
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile()
                fh.write(line.data(using: .utf8) ?? Data())
                try? fh.close()
            } else {
                try? line.data(using: .utf8)?.write(to: url)
            }
        }
    }

    // MARK: - v7.1.33 WS 长连接（复用同一条 WebSocket 串行合成，根治逐句高频握手被微软限流；断线自动重连）

    private func closeWS() {
        sentenceTimeout?.cancel()
        sentenceTimeout = nil
        wsTask?.cancel()
        wsTask = nil
        wsSession?.invalidateAndCancel()
        wsSession = nil
    }

    private func ensureWS(_ cb: @escaping (URLSessionWebSocketTask?) -> Void) {
        if let w = wsTask, w.state == .running || w.state == .waitingForConnectivity { cb(w); return }
        closeWS()
        let gec = secMsGecV2()
        let connId = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        guard let url = URL(string: "\(Self.wsBaseURL)?TrustedClientToken=\(Self.trustedClientToken)&ConnectionId=\(connId)&Sec-MS-GEC=\(gec)&Sec-MS-GEC-Version=\(Self.gecVersion)") else {
            ttsLog("FAIL: bad WS URL")
            cb(nil); return
        }
        var req = URLRequest(url: url)
        // edge-tts 2.x WSS_HEADERS 全套（UA Chrome143 / Cookie muid / zstd）
        req.setValue("no-cache", forHTTPHeaderField: "Pragma")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        req.setValue("13", forHTTPHeaderField: "Sec-WebSocket-Version")
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0", forHTTPHeaderField: "User-Agent")
        req.setValue("gzip, deflate, br, zstd", forHTTPHeaderField: "Accept-Encoding")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        var muid = ""
        for _ in 0..<32 { muid += String(format: "%02X", Int.random(in: 0...255)) }
        req.setValue("muid=\(muid);", forHTTPHeaderField: "Cookie")
        let session = URLSession(configuration: .ephemeral)
        let ws = session.webSocketTask(with: req)
        ws.resume()
        wsSession = session
        wsTask = ws
        ttsLog("ws connected conn=\(connId.prefix(8)) gec=\(gec.prefix(16))...")
        cb(ws)
    }

    private func finishSentence(_ data: Data?) {
        let cb = sentenceCompletion
        sentenceCompletion = nil
        currentAudio = Data()
        sentenceTimeout?.cancel()
        sentenceTimeout = nil
        cb?(data)
    }

    private func startReceiveLoop() {
        guard let ws = wsTask else { finishSentence(nil); return }
        ws.receive { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                switch result {
                case .success(let message):
                    switch message {
                    case .data(let d):
                        // 音频 BINARY 帧：前 2 字节 header 长度 + header + 音频（edge-tts 同样剥离）
                        if d.count >= 2 {
                            let hl = (Int(d[d.startIndex]) << 8) | Int(d[d.startIndex + 1])
                            let start = d.startIndex + 2 + hl
                            if start <= d.endIndex {
                                self.currentAudio.append(d.subdata(in: start..<d.endIndex))
                            }
                        }
                        if self.currentAudio.count % 8192 < 4096 { self.ttsLog("recv audio bytes=\(self.currentAudio.count)") }
                        self.startReceiveLoop()
                    case .string(let s):
                        if s.contains("Path:turn.end") || s.contains("turn.end") {
                            self.ttsLog("turn.end bytes=\(self.currentAudio.count)")
                            self.finishSentence(self.currentAudio.count > 100 ? self.currentAudio : nil)
                        } else {
                            self.ttsLog("recv string: \(s.prefix(50))")
                            self.startReceiveLoop()
                        }
                    @unknown default:
                        self.startReceiveLoop()
                    }
                case .failure(let e):
                    self.ttsLog("FAIL: ws recv error=\(e.localizedDescription) bytes=\(self.currentAudio.count)")
                    self.closeWS()
                    self.finishSentence(self.currentAudio.count > 100 ? self.currentAudio : nil)
                }
            }
        }
    }

    private func synthesize(_ text: String, completion: @escaping (Data?) -> Void) {
        ttsLog("synthesize: voice=\(voicePreset.voice) pitch=\(voicePreset.pitch) rate=\(voicePreset.rate) text_len=\(text.count) ws=\(wsTask?.state.rawValue ?? -1)")
        let v = fullVoiceName, p = voicePreset.pitch, r = voicePreset.rate
        ensureWS { ws in
            DispatchQueue.main.async {
                guard let ws else {
                    self.ttsLog("FAIL: no ws")
                    completion(nil); return
                }
                self.sentenceCompletion = completion
                self.currentAudio = Data()
                let ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'><voice name='\(v)'><prosody pitch='\(p)' rate='\(r)' volume='+0%'>\(self.xmlEscape(text))</prosody></voice></speak>"
                let jsDate = self.jsDateString()
                // edge-tts 2.x：先 speech.config（设 outputFormat），再 SSML 直发（Path:ssml，X-Timestamp 带 Z）
                let configPayload = "X-Timestamp:\(jsDate)\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"true\",\"wordBoundaryEnabled\":\"false\"},\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}\r\n"
                let ssmlPayload = "X-RequestId:\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:\(jsDate)Z\r\nPath:ssml\r\n\r\n\(ssml)"
                // 句级超时 20s（复用连接卡死会堵队列，超时重置连接放行下一句）
                let tw = DispatchWorkItem { [weak self] in
                    self?.ttsLog("FAIL: sentence timeout 20s")
                    self?.closeWS()
                    self?.finishSentence(nil)
                }
                self.sentenceTimeout = tw
                DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: tw)
                ws.send(.string(configPayload)) { [weak self] err in
                    guard let self else { return }
                    DispatchQueue.main.async {
                        if let err = err {
                            self.ttsLog("FAIL: ws.send config error=\(err.localizedDescription)")
                            self.closeWS()
                            self.finishSentence(nil)
                        } else {
                            self.ttsLog("speech.config sent, sending ssml...")
                            ws.send(.string(ssmlPayload)) { [weak self] err2 in
                                guard let self else { return }
                                DispatchQueue.main.async {
                                    if let err2 = err2 {
                                        self.ttsLog("FAIL: ws.send ssml error=\(err2.localizedDescription)")
                                        self.closeWS()
                                        self.finishSentence(nil)
                                    } else {
                                        self.ttsLog("ssml sent (waiting audio)")
                                        self.startReceiveLoop()
                                    }
                                }
                            }
                        }
                    }
                }
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
