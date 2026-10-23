import SwiftUI
import UIKit
import Combine

// MARK: - 可爱助手 · 状态

/// v4.5.0：可爱助手全局开关 + 角色（设置里可选开/关、切换角色，UserDefaults 持久化）
/// 角色：小萝莉(girl_*) / 兔娘(rabit_*) / 猫娘(cat_*)
enum GirlCharacter: String, CaseIterable, Identifiable {
    case loli
    case rabit
    case cat
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .loli: return L10n.t("i18n_807")
        case .rabit: return L10n.t("i18n_808")
        case .cat: return L10n.t("i18n_809")
        }
    }
    var iconPrefix: String {
        switch self {
        case .loli: return "girl"
        case .rabit: return "rabit"
        case .cat: return "cat"
        }
    }
}

extension GirlCharacter {
    /// v6.0.12：从 UserDefaults 读回角色的统一入口（GirlCompanion.init 与 HUDManager 共用）。
    /// 枚举 rawValue 已由旧值"御姐兔女郎"更名为"兔娘"——老用户升级后本地仍存"御姐兔女郎"，
    /// 直接 GirlCharacter(rawValue:) 会拿到 nil 静默回退 .loli，这里做一次旧值→.rabit 兼容映射。
    static func stored(rawValue: String?) -> GirlCharacter {
        guard let raw = rawValue, !raw.isEmpty else { return .loli }
        if raw == L10n.t("i18n_810") { return .rabit }   // 旧 rawValue 迁移：御姐兔女郎 → 兔娘
        let legacy: [String: GirlCharacter] = ["小萝莉": .loli, "兔娘": .rabit, "猫娘": .cat, "御姐兔女郎": .rabit]
        if let c = legacy[raw] { return c }
        return GirlCharacter(rawValue: raw) ?? .loli
    }
}

final class GirlCompanion: ObservableObject {
    static let shared = GirlCompanion()
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "trollmcp2.girl_companion_enabled") }
    }
    @Published var selectedCharacter: GirlCharacter {
        didSet { UserDefaults.standard.set(selectedCharacter.rawValue, forKey: "trollmcp2.girl_character") }
    }
    // v6.0.28：悬浮尺寸可调
    @Published var floatSize: Double {
        didSet { UserDefaults.standard.set(floatSize, forKey: "trollmcp2.girl_float_size") }
    }
    // v6.0.28：气泡样式（0=经典圆角 1=椭圆 2=方形硬边 3=爆炸形）
    @Published var bubbleStyle: Int {
        didSet { UserDefaults.standard.set(bubbleStyle, forKey: "trollmcp2.bubble_style") }
    }
    private init() {
        enabled = UserDefaults.standard.bool(forKey: "trollmcp2.girl_companion_enabled")
        selectedCharacter = GirlCharacter.stored(rawValue: UserDefaults.standard.string(forKey: "trollmcp2.girl_character"))
        // 默认200，范围170-300
        let savedSize = UserDefaults.standard.double(forKey: "trollmcp2.girl_float_size")
        floatSize = (savedSize > 0) ? savedSize : 200
        bubbleStyle = UserDefaults.standard.integer(forKey: "trollmcp2.bubble_style")
    }
}

// MARK: - 表情帧（对应 Resources/girl_*.png 或 rabit_*.png，build-ipa.sh 打进 App 根，Bundle.main 读）

enum GirlExpression: String {
    case idle    // 正常/待机
    case happy   // 开心（点击）
    case think   // 思考
    case talk    // 说话口型（语音时）
    /// 按角色取帧图名：小萝莉 girl_*，兔娘 rabit_*
    func imageName(for character: GirlCharacter) -> String {
        return "\(character.iconPrefix)_\(rawValue)"
    }
}

// MARK: - 角色视图

struct GirlCompanionView: View {
    @ObservedObject private var companion = GirlCompanion.shared
    @ObservedObject private var tts = TTSService.shared
    @ObservedObject private var voice = GirlVoice.shared

    @State private var expression: GirlExpression = .idle
    @State private var breathing = false      // 呼吸（scale 缓动）
    @State private var floating = false       // 浮动（上下轻飘）
    @State private var tapFlash: Int = 0      // 点击触发随机表情的计时
    @State private var deniedHint = false     // 权限被拒提示

    private let frameHeight: CGFloat = 148    // 全身立绘显示高度（右下角悬浮，不宜过大）

    // v6.0.12：与 HUD 完全一致的角色放大系数（girl 1.0 / rabit 1.4 / cat 1.2）——
    // 兔娘/猫娘身高修长，同高 148 下比萝莉窄，按系数放大显示高度，保持右下角助手整体大小协调。
    private var charScale: CGFloat {
        switch companion.selectedCharacter {
        case .rabit: return 1.4
        case .cat: return 1.2
        case .loli: return 1.0
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            // 小女孩本体
            Group {
                if let img = UIImage(named: expression.imageName(for: companion.selectedCharacter)) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(height: frameHeight * charScale)
                        .scaleEffect(breathing ? 1.03 : 0.99)
                        .offset(y: floating ? -7 : 7)
                        .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: breathing)
                        .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
                        .onTapGesture { reactToTap() }
                } else {
                    Circle().fill(Color.pink.opacity(0.25)).frame(width: 60, height: 60)
                }
            }
            .onAppear {
                breathing = true
                floating = true
                voice.onFinalText = { [self] text in self.askAI(text) }
                voice.onPermissionDenied = { [self] in self.deniedHint = true }
            }

            // 说话按钮（麦克风）
            micButton
        }
        .onReceive(tts.$isSpeaking) { speaking in
            withAnimation(.easeInOut(duration: 0.25)) {
                expression = speaking ? .talk : (voice.isListening ? .talk : .idle)
            }
        }
        .onReceive(voice.$isListening) { listening in
            withAnimation(.easeInOut(duration: 0.25)) {
                if listening { expression = .talk }
            }
        }
        .onReceive(Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()) { _ in
            if tapFlash > 0 {
                tapFlash -= 1
                if tapFlash == 0 { expression = .idle }
            }
        }
        .alert(L10n.t("i18n_811"), isPresented: $deniedHint) {
            Button(L10n.t("ui_44"), role: .cancel) {}
        } message: {
            Text(L10n.t("i18n_812"))
        }
    }

    // MARK: - 麦克风说话按钮

    private var micButton: some View {
        Button(action: toggleMic) {
            HStack(spacing: 5) {
                if voice.isListening {
                    // 录音中：红点脉冲 + "听你说"
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                        .scaleEffect(voice.isListening ? 1.2 : 1.0)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: voice.isListening)
                    Text(L10n.t("i18n_813"))
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                    Text(L10n.t("i18n_814"))
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(voice.isListening ? Color.red.opacity(0.85) : Color.pink.opacity(0.75))
            )
            .shadow(color: Color.black.opacity(0.12), radius: 5, x: 0, y: 3)
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - 交互

    /// 点击切表情：随机 开心/思考，短暂后回待机
    private func reactToTap() {
        let r = Int.random(in: 0...1)
        withAnimation(.easeInOut(duration: 0.25)) {
            expression = r == 0 ? .happy : .think
        }
        tapFlash = 2   // 约 1.6s 后回待机
    }

    /// 麦克风：开始听 / 停止发送
    private func toggleMic() {
        if voice.isListening {
            voice.stop()
        } else {
            voice.start()
        }
    }

    /// 识别到文本 → 发 AI（复用聊天发送链路，回复自动流式显示 + 朗读 → 口型帧）
    private func askAI(_ text: String) {
        guard let cfg = ModelStore.shared.defaultConfig else { return }
        // 语音对话需要听到回复 → 若喇叭关着自动打开
        if !tts.speakerEnabled {
            tts.speakerEnabled = true
        }
        let store = ConversationStore.shared
        if store.selectedId == nil {
            store.newConversation()
        }
        store.send(text, using: cfg, reasoningLevel: 3, smartSearch: true)
    }
}
