import SwiftUI
import UIKit

/// v4.5.1：可爱助手角色选择页——显示小萝莉/兔娘/猫娘三个角色卡片（带形象图），点选即切换
/// 入口：设置 → 可爱助手 → 可爱助手角色
struct GirlCharacterPickerView: View {
    @ObservedObject private var companion = GirlCompanion.shared
    // v6.1.5-3：与 HUD 进程共享快捷菜单数据（App Group）——主 App 与 TrollAgentHUD 是独立进程，
    // standardUserDefaults 是各自沙盒域，之前 HUD 读不到 fanMenuApps → 自定义 app 不进菜单
    private static let prefs: UserDefaults = UserDefaults(suiteName: "group.com.ai.iosxcode") ?? .standard
    // v6.1.5-14n：菜单参数（透明度/散开角度/弧度）修改后自动重启 HUD 生效（正在运行才重启）
    fileprivate static func restartHUDIfNeeded() {
        if HUDManager.shared.isRunning {
            _ = HUDManager.shared.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                _ = HUDManager.shared.start()
            }
        }
    }
    // v6.1.5-14n：菜单参数统一保存——写 suite + 全局文件 /var/mobile/Documents/fanmenu_settings.json
    // （HUD 独立进程优先读全局文件，绕开 App Group 权限不确定性）
    // v6.1.5-14af：style 也并入全局文件（原只写 suite——HUD 读 suite 失败时 fanMenuStyle 恒为 0 → "切换纵向列表没用"）
    fileprivate static func saveFanMenuSettings() {
        let alpha = prefs.object(forKey: "fanMenuAlpha") as? Double ?? 1.0
        let span = prefs.object(forKey: "fanMenuSpan") as? Double ?? 90.0
        let arc = prefs.object(forKey: "fanMenuArc") as? Double ?? 1.0
        let style = prefs.integer(forKey: "fanMenuStyle")
        let size = prefs.object(forKey: "fanMenuSize") as? Double ?? 56.0   // v6.1.5-14aq：图标大小
        prefs.synchronize()
        let settingsFile = "/var/mobile/Documents/fanmenu_settings.json"
        do {
            let data = try JSONSerialization.data(withJSONObject: ["alpha": alpha, "span": span, "arc": arc, "style": style, "size": size])
            try data.write(to: URL(fileURLWithPath: settingsFile), options: .atomic)
        } catch {}
        restartHUDIfNeeded()
    }
    // v6.1.5-7：统一保存入口——双写(suite+standard) + 强制落盘 + 写后读回验证，诊断记入 fanMenuDiag
    // UserDefaults.set 默认异步落盘，添加后立刻切后台可能没写进 plist，HUD 直读文件时读不到 → 必须 synchronize
    // v6.1.5-14e：第三通道——写全局文件 /var/mobile/Documents/fanmenu.json（主 App no-sandbox 可写，
    // HUD 独立进程同样 no-sandbox 可读，绕开 App Group 在独立 HUD 上可能的权限不确定性）
    // v6.1.5-14ae：保存前补稳定 id——ForEach 用 id 做稳定标识（原索引 id 在 onDelete 时 diff 错乱 → "删一个加一个"）
    fileprivate static let fanMenuSharedFile = "/var/mobile/Documents/fanmenu.json"
    fileprivate static func ensureAppIDs(_ apps: [[String:String]]) -> [[String:String]] {
        return apps.map { a in
            var m = a
            if m["id"] == nil { m["id"] = "\(UInt32(arc4random()))_\(Date().timeIntervalSince1970)" }
            return m
        }
    }
    fileprivate static func saveFanMenu(_ apps: [[String:String]]) {
        let apps2 = ensureAppIDs(apps)
        prefs.set(apps2, forKey: "fanMenuApps")
        prefs.synchronize()
        UserDefaults.standard.set(apps2, forKey: "fanMenuApps")
        UserDefaults.standard.synchronize()
        // v6.1.5-14e：全局文件通道（主 App no-sandbox，直接写 /var/mobile/Documents）
        do {
            let data = try JSONSerialization.data(withJSONObject: apps2, options: [])
            try data.write(to: URL(fileURLWithPath: fanMenuSharedFile), options: .atomic)
        } catch {
            // 写失败不阻塞主流程，诊断里可见
            NSLog("[TrollAgent] fanmenu shared file write FAIL: \(error)")
        }
        // 写后立即读回验证（暴露 App Group 失效 / 落盘失败）
        let backSuite = (UserDefaults(suiteName: "group.com.ai.iosxcode")?.array(forKey: "fanMenuApps") as? [[String:String]])?.count ?? -1
        let backStd = UserDefaults.standard.array(forKey: "fanMenuApps") as? [[String:String]]
        let diag = "\(Date()): 写\(apps2.count)项 suite读回=\(backSuite) std读回=\(backStd?.count ?? -1)"
        var logs = UserDefaults.standard.stringArray(forKey: "fanMenuDiag") ?? []
        logs.append(diag)
        if logs.count > 30 { logs.removeFirst(logs.count - 30) }
        UserDefaults.standard.set(logs, forKey: "fanMenuDiag")
        UserDefaults.standard.synchronize()
    }
    // v6.1.5-14ae：按 bundleId 取真实图标（AppCatalog 定位路径 → AppIconLoader 读图标，带缓存毫秒级）
    private static func appIcon(forBundleId bid: String) -> UIImage? {
        if bid.isEmpty { return nil }
        if let path = AppCatalog.lookupBundlePath(bundleId: bid) {
            return AppIconLoader.shared.icon(forPath: path)
        }
        return nil
    }
    // v6.1.5-14r：菜单参数用 @State 驱动——Slider 拖动实时更新数值文本（UserDefaults 变化不触发 SwiftUI 刷新）
    @State private var fanAlpha: Double = (prefs.object(forKey: "fanMenuAlpha") as? Double) ?? 1.0
    @State private var fanSpan: Double = (prefs.object(forKey: "fanMenuSpan") as? Double) ?? 90.0
    @State private var fanArc: Double = (prefs.object(forKey: "fanMenuArc") as? Double) ?? 1.0
    @State private var fanSize: Double = (prefs.object(forKey: "fanMenuSize") as? Double) ?? 56.0   // v6.1.5-14aq：图标大小
    @State private var savedApps: [[String:String]] = {
        // v6.1.5-6：suite 优先，standard 兜底（HUD 进程 no-sandbox 直读主App容器偏好文件，双写保证两边都能拿到）
        let suite = Self.prefs.array(forKey: "fanMenuApps") as? [[String:String]]
        let std = UserDefaults.standard.array(forKey: "fanMenuApps") as? [[String:String]]
        let base = (suite ?? std) ?? [
            // v6.1.5-8：默认项带 bundleId——点击走 LSApplicationWorkspace openApplicationWithBundleID
            // （camera:// App-prefs:// 等 scheme 在 iOS 上不存在/被拒，之前默认项点击必"没反应"）
            ["name":L10n.t("i18n_765"), "url":"weixin://", "bundleId":"com.tencent.xin"],
            ["name":L10n.t("i18n_766"), "url":"snssdk1128://", "bundleId":"com.ss.iphone.ugc.Aweme"],
            ["name":L10n.t("i18n_767"), "url":"camera://", "bundleId":"com.apple.camera"],
            ["name":L10n.t("i18n_1151"), "url":"App-prefs://", "bundleId":"com.apple.Preferences"]
        ]
        return Self.ensureAppIDs(base)   // v6.1.5-14ae：初始数据补稳定 id（ForEach 依赖）
    }()

    var body: some View {
        Form {
            Section(header: Text(L10n.t("i18n_768"))) {
                // 三个角色并排：兔娘左、小萝莉中、猫娘右，名字都在图底部
                HStack(spacing: 12) {
                    // 兔娘（左）
                    Button {
                        companion.selectedCharacter = .rabit
                        // 桌宠开着就自动重启切换角色，关着不自动启动
                        if HUDManager.shared.isRunning {
                            _ = HUDManager.shared.stop()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                _ = HUDManager.shared.start()
                            }
                        }
                    } label: {
                        VStack(spacing: 8) {
                            // v6.1.5-2：预览图用跪姿形象（rabit_cross 已从 HUD/Resources 复制进主包）
                            if let img = UIImage(named: "rabit_cross") {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 110)
                            }
                            Text(L10n.t("i18n_808"))
                                .font(.headline)
                            if companion.selectedCharacter == .rabit {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.pink)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundColor(.secondary.opacity(0.4))
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(companion.selectedCharacter == .rabit ? Color.pink.opacity(0.15) : Color(.secondarySystemGroupedBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(companion.selectedCharacter == .rabit ? Color.pink : Color.clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    // 小萝莉（中间）
                    Button {
                        companion.selectedCharacter = .loli
                        // 桌宠开着就自动重启切换角色，关着不自动启动
                        if HUDManager.shared.isRunning {
                            _ = HUDManager.shared.stop()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                _ = HUDManager.shared.start()
                            }
                        }
                    } label: {
                        VStack(spacing: 8) {
                            // v6.1.5-2：预览图用跪姿形象（girl_kneel 已从 HUD/Resources 复制进主包）
                            if let img = UIImage(named: "girl_kneel") {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 110)
                            }
                            Text(L10n.t("i18n_807"))
                                .font(.headline)
                            if companion.selectedCharacter == .loli {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.pink)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundColor(.secondary.opacity(0.4))
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(companion.selectedCharacter == .loli ? Color.pink.opacity(0.15) : Color(.secondarySystemGroupedBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(companion.selectedCharacter == .loli ? Color.pink : Color.clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    // 猫娘（右）
                    Button {
                        companion.selectedCharacter = .cat
                        // 桌宠开着就自动重启切换角色，关着不自动启动
                        if HUDManager.shared.isRunning {
                            _ = HUDManager.shared.stop()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                _ = HUDManager.shared.start()
                            }
                        }
                    } label: {
                        VStack(spacing: 8) {
                            // v6.1.5-2：预览图用跪姿形象（cat_kneel 已从 HUD/Resources 复制进主包）
                            if let img = UIImage(named: "cat_kneel") {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 110)
                            }
                            Text(L10n.t("i18n_809"))
                                .font(.headline)
                            if companion.selectedCharacter == .cat {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.pink)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundColor(.secondary.opacity(0.4))
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(companion.selectedCharacter == .cat ? Color.pink.opacity(0.15) : Color(.secondarySystemGroupedBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(companion.selectedCharacter == .cat ? Color.pink : Color.clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            Section(header: Text(L10n.t("i18n_772"))) {
                VStack {
                    HStack {
                        Text(L10n.t("i18n_773"))
                        Slider(value: $companion.floatSize, in: 170...300, step: 5) { editing in
                            // v6.0.30修复：拖动结束才重启（拖动中不重启），桌宠开着立即生效，关着只存参数不弹出
                            if !editing && HUDManager.shared.isRunning {
                                _ = HUDManager.shared.stop()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    _ = HUDManager.shared.start()
                                }
                            }
                        }
                        Text(L10n.t("i18n_774"))
                    }
                    Text(L10n.t("i18n_775", Int(companion.floatSize)))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Section(header: Text(L10n.t("i18n_776"))) {
                Picker(L10n.t("i18n_777"), selection: $companion.bubbleStyle) {
                    Text(L10n.t("i18n_778")).tag(0)
                    Text(L10n.t("i18n_779")).tag(1)
                    Text(L10n.t("i18n_780")).tag(2)
                    Text(L10n.t("i18n_781")).tag(3)
                }
                .pickerStyle(.segmented)
                .onChange(of: companion.bubbleStyle) { _ in
                    // v6.0.30修复：桌宠开着改气泡样式立即重启生效，关着只存参数不自动弹出
                    if HUDManager.shared.isRunning {
                        _ = HUDManager.shared.stop()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            _ = HUDManager.shared.start()
                        }
                    }
                }
                // 实时预览气泡
                // v6.1.5：修复预览文字不显示——原 .overlay(不透明 fill) 会盖住文字，
                // 改为 .background（形状画在文字下层），描边留在形状内不影响文字
                VStack {
                    Text(L10n.t("i18n_782"))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            Group {
                                if companion.bubbleStyle == 0 {
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(Color(.secondarySystemGroupedBackground))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 16)
                                                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                                        )
                                } else if companion.bubbleStyle == 1 {
                                    Capsule()
                                        .fill(Color(.secondarySystemGroupedBackground))
                                } else if companion.bubbleStyle == 2 {
                                    Rectangle()
                                        .fill(Color(.secondarySystemGroupedBackground))
                                        .overlay(
                                            Rectangle()
                                                .stroke(Color.blue, lineWidth: 2)
                                        )
                                } else {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.yellow.opacity(0.95))
                                        .shadow(radius: 3)
                                }
                            }
                        )
                }
                .padding(.vertical, 12)
            }
            Section(header: HStack {
                Text(L10n.t("i18n_783"))
                Spacer()
                EditButton()
            }) {
                Picker(L10n.t("i18n_784"), selection: Binding<Int>(
                    get: { Self.prefs.integer(forKey: "fanMenuStyle") },
                    set: { 
                        Self.prefs.set($0, forKey: "fanMenuStyle")
                        Self.prefs.synchronize() // v6.1.5-7：强制落盘，HUD 重启后必然读到新样式
                        Self.saveFanMenuSettings() // v6.1.5-14af：样式一并写全局文件（HUD 读 suite 失败时也能生效）
                    }
                )) {
                    Text(L10n.t("i18n_785")).tag(0)
                    Text(L10n.t("i18n_786")).tag(1)
                }
                .pickerStyle(.segmented)
                // v6.1.5-14n/r：菜单图标整体透明度 / 散开角度 / 弧度——@State 实时显示，松手才写文件+重启
                HStack {
                    Text(L10n.t("i18n_787")).font(.subheadline)
                    Spacer()
                    Slider(value: Binding<Double>(
                        get: { fanAlpha },
                        set: {
                            fanAlpha = $0
                            Self.prefs.set($0, forKey: "fanMenuAlpha")
                            Self.prefs.synchronize()
                        }
                    ), in: 0.2...1.0,
                    onEditingChanged: { editing in
                        if !editing { Self.saveFanMenuSettings() }
                    })
                    .frame(width: 140)
                    Text(String(format: "%.0f%%", fanAlpha * 100))
                        .font(.caption).foregroundColor(.secondary).frame(width: 42)
                }
                HStack {
                    Text(L10n.t("i18n_788")).font(.subheadline)
                    Spacer()
                    Slider(value: Binding<Double>(
                        get: { fanSpan },
                        set: {
                            fanSpan = $0
                            Self.prefs.set($0, forKey: "fanMenuSpan")
                            Self.prefs.synchronize()
                        }
                    ), in: 40...160,
                    onEditingChanged: { editing in
                        if !editing { Self.saveFanMenuSettings() }
                    })
                    .frame(width: 140)
                    Text("\(Int(fanSpan))°")
                        .font(.caption).foregroundColor(.secondary).frame(width: 42)
                }
                HStack {
                    Text(L10n.t("i18n_789")).font(.subheadline)
                    Spacer()
                    Slider(value: Binding<Double>(
                        get: { fanArc },
                        set: {
                            fanArc = $0
                            Self.prefs.set($0, forKey: "fanMenuArc")
                            Self.prefs.synchronize()
                        }
                    ), in: 0.7...1.4,
                    onEditingChanged: { editing in
                        if !editing { Self.saveFanMenuSettings() }
                    })
                    .frame(width: 140)
                    Text(String(format: "%.1f×", fanArc))
                        .font(.caption).foregroundColor(.secondary).frame(width: 42)
                }
                // v6.1.5-14aq：图标大小（40-80pt，默认56）——扇钮/竖排圆钮直径 + 布局半径/间距联动
                HStack {
                    Text(L10n.t("i18n_790")).font(.subheadline)
                    Spacer()
                    Slider(value: Binding<Double>(
                        get: { fanSize },
                        set: {
                            fanSize = $0
                            Self.prefs.set($0, forKey: "fanMenuSize")
                            Self.prefs.synchronize()
                        }
                    ), in: 40...80,
                    onEditingChanged: { editing in
                        if !editing { Self.saveFanMenuSettings() }
                    })
                    .frame(width: 140)
                    Text("\(Int(fanSize))")
                        .font(.caption).foregroundColor(.secondary).frame(width: 42)
                }
                                // v6.1.5-14ae：ForEach 用稳定 id（app["id"]，ensureAppIDs 已保证唯一）——
                                // 原 0..<count 索引 id 在 onDelete 时 diff 错乱（删中间项后所有后续项 id 前移）→ "删一个又冒出一个"
                                let menuRows: [FanMenuRow] = savedApps.map { FanMenuRow(id: $0["id"] ?? "\($0["name"] ?? "")|\($0["url"] ?? "")", app: $0) }
                                ForEach(menuRows) { row in
                                    HStack(spacing: 12) {
                                        // v6.1.5-14ae：行美化——真实图标圆角 + 名称 + url 次要灰色
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color(.tertiarySystemFill))
                                                .frame(width: 34, height: 34)
                                            if let bid = row.app["bundleId"], let icon = Self.appIcon(forBundleId: bid) {
                                                Image(uiImage: icon)
                                                    .resizable()
                                                    .scaledToFit()
                                                    .frame(width: 26, height: 26)
                                            } else {
                                                Image(systemName: "app.fill")
                                                    .font(.system(size: 16))
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(row.app["name"] ?? "")
                                                .font(.body)
                                        }
                                        Spacer()
                                    }
                                    .padding(.vertical, 3)
                                }
                                .onDelete { indexSet in
                                    savedApps.remove(atOffsets: indexSet)
                                    Self.saveFanMenu(savedApps) // v6.1.5-7：双写+落盘+读回验证（v6.1.5-14ae：写入前补稳定 id）
                                }
                                // v6.1.5-14ae：返回/重进时强制从持久化重读（@State 初始值只在首次创建时读，
                                // 若视图被系统缓存则内存值可能过期 → "删除后返回又全部回来"）
                                .onAppear {
                                    let fresh = Self.prefs.array(forKey: "fanMenuApps") as? [[String:String]]
                                        ?? UserDefaults.standard.array(forKey: "fanMenuApps") as? [[String:String]]
                                    if let fresh { savedApps = fresh }
                                }
                                // 添加新应用
                                FanMenuAddView(savedApps: $savedApps)
            }
            Section(header: Text(L10n.t("i18n_793"))) {
                Toggle(L10n.t("i18n_794"), isOn: Binding<Bool>(
                    get: { 
                        // 默认打开
                        if UserDefaults.standard.object(forKey: "autoHideWithKeyboard") == nil {
                            return true
                        }
                        return UserDefaults.standard.bool(forKey: "autoHideWithKeyboard")
                    },
                    set: {
                        UserDefaults.standard.set($0, forKey: "autoHideWithKeyboard")
                        // v6.1.5-14n：全局文件通道——HUD 独立进程读不到主 App standard，写文件让 HUD 轮询读到
                        do {
                            try ($0 ? "1" : "0").write(to: URL(fileURLWithPath: "/var/mobile/Documents/auto_hide_keyboard.txt"),
                                                        atomically: true, encoding: .utf8)
                        } catch {}
                    }
                ))
                // v6.1.5-14ap：粒子特效开关——默认开；写全局文件让 HUD 轮询（与键盘开关同通道模式）
                Toggle(L10n.t("i18n_795"), isOn: Binding<Bool>(
                    get: {
                        if UserDefaults.standard.object(forKey: "particleEnabled") == nil {
                            return true
                        }
                        return UserDefaults.standard.bool(forKey: "particleEnabled")
                    },
                    set: {
                        UserDefaults.standard.set($0, forKey: "particleEnabled")
                        do {
                            try ($0 ? "1" : "0").write(to: URL(fileURLWithPath: "/var/mobile/Documents/particle_enabled.txt"),
                                                        atomically: true, encoding: .utf8)
                        } catch {}
                    }
                ))
            }
            Section {}
        }
        .navigationTitle(L10n.t("i18n_796"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// v6.1.5-14ae：快捷菜单行——稳定 id（ForEach 删除不再错乱）
private struct FanMenuRow: Identifiable {
    let id: String
    let app: [String:String]
}

struct FanMenuAddView: View {
    @Binding var savedApps: [[String:String]]
    @State private var showPicker = false
    var body: some View {
        Button {
            showPicker = true
        } label: {
            HStack {
                Image(systemName: "plus.circle.fill")
                Text(L10n.t("i18n_797"))
                Spacer()
            }
        }
        .sheet(isPresented: $showPicker) {
            AppPickerView { app in
                // v6.1.5-14ae：添加时补稳定 id（原无 id → ForEach id 撞车）
                savedApps.append(["name":app.name, "bundleId":app.bundleId,
                                  "id":"\(UInt32(arc4random()))_\(Date().timeIntervalSince1970)"])
                // v6.1.5-7：统一保存入口——双写(suite+standard)+强制落盘+写后读回验证
                GirlCharacterPickerView.saveFanMenu(savedApps)
                showPicker = false
            }
        }
    }
}
