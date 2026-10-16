import SwiftUI
import UIKit

/// v4.5.1：可爱助手角色选择页——显示小萝莉/兔娘/猫娘三个角色卡片（带形象图），点选即切换
/// 入口：设置 → 可爱助手 → 可爱助手角色
struct GirlCharacterPickerView: View {
    @ObservedObject private var companion = GirlCompanion.shared
    // v6.1.5-3：与 HUD 进程共享快捷菜单数据（App Group）——主 App 与 TrollAgentHUD 是独立进程，
    // standardUserDefaults 是各自沙盒域，之前 HUD 读不到 fanMenuApps → 自定义 app 不进菜单
    private static let prefs: UserDefaults = UserDefaults(suiteName: "group.com.ai.iosxcode") ?? .standard
    // v6.1.5-7：统一保存入口——双写(suite+standard) + 强制落盘 + 写后读回验证，诊断记入 fanMenuDiag
    // UserDefaults.set 默认异步落盘，添加后立刻切后台可能没写进 plist，HUD 直读文件时读不到 → 必须 synchronize
    private static func saveFanMenu(_ apps: [[String:String]]) {
        prefs.set(apps, forKey: "fanMenuApps")
        prefs.synchronize()
        UserDefaults.standard.set(apps, forKey: "fanMenuApps")
        UserDefaults.standard.synchronize()
        // 写后立即读回验证（暴露 App Group 失效 / 落盘失败）
        let backSuite = (UserDefaults(suiteName: "group.com.ai.iosxcode")?.array(forKey: "fanMenuApps") as? [[String:String]])?.count ?? -1
        let backStd = UserDefaults.standard.array(forKey: "fanMenuApps") as? [[String:String]]
        let diag = "\(Date()): 写\(apps.count)项 suite读回=\(backSuite) std读回=\(backStd?.count ?? -1)"
        var logs = UserDefaults.standard.stringArray(forKey: "fanMenuDiag") ?? []
        logs.append(diag)
        if logs.count > 30 { logs.removeFirst(logs.count - 30) }
        UserDefaults.standard.set(logs, forKey: "fanMenuDiag")
        UserDefaults.standard.synchronize()
    }
    @State private var savedApps: [[String:String]] = {
        // v6.1.5-6：suite 优先，standard 兜底（HUD 进程 no-sandbox 直读主App容器偏好文件，双写保证两边都能拿到）
        let suite = Self.prefs.array(forKey: "fanMenuApps") as? [[String:String]]
        let std = UserDefaults.standard.array(forKey: "fanMenuApps") as? [[String:String]]
        return (suite ?? std) ?? [
            ["name":"微信", "url":"weixin://"],
            ["name":"抖音", "url":"snssdk1128://"],
            ["name":"相机", "url":"camera://"],
            ["name":"设置", "url":"App-prefs://"]
        ]
    }()

    var body: some View {
        Form {
            Section(header: Text("选择可爱助手的角色")) {
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
                            Text("兔娘")
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
                            Text("小萝莉")
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
                            Text("猫娘")
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
            Section(header: Text("悬浮尺寸（改完自动重启悬浮生效）")) {
                VStack {
                    HStack {
                        Text("小")
                        Slider(value: $companion.floatSize, in: 170...300, step: 5) { editing in
                            // v6.0.30修复：拖动结束才重启（拖动中不重启），桌宠开着立即生效，关着只存参数不弹出
                            if !editing && HUDManager.shared.isRunning {
                                _ = HUDManager.shared.stop()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    _ = HUDManager.shared.start()
                                }
                            }
                        }
                        Text("大")
                    }
                    Text("当前尺寸：\(Int(companion.floatSize)) pt")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Section(header: Text("气泡样式（改完自动重启悬浮生效）")) {
                Picker("气泡样式", selection: $companion.bubbleStyle) {
                    Text("经典圆角").tag(0)
                    Text("椭圆气泡").tag(1)
                    Text("方形硬边").tag(2)
                    Text("爆炸吐槽").tag(3)
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
                    Text("预览：哈喽呀～")
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
                Text("快捷菜单")
                Spacer()
                EditButton()
            }, footer: VStack(alignment: .leading, spacing: 4) {
                Text("💡 提示：单击桌面上的桌宠就会弹出这个快捷菜单！点右上角编辑可删除应用，URL Scheme比如微信weixin://，抖音snssdk1128://")
                // v6.1.5-7：写入诊断（写后读回验证结果），排查"自定义 app 不进菜单"直接截图发我
                if let last = UserDefaults.standard.stringArray(forKey: "fanMenuDiag")?.last {
                    Text("🩺 \(last)").font(.caption2).foregroundColor(.secondary)
                }
            }) {
                Picker("弹出样式", selection: Binding<Int>(
                    get: { Self.prefs.integer(forKey: "fanMenuStyle") },
                    set: { 
                        Self.prefs.set($0, forKey: "fanMenuStyle")
                        Self.prefs.synchronize() // v6.1.5-7：强制落盘，HUD 重启后必然读到新样式
                        // 如果桌宠正在运行，自动重启读新参数；没运行绝对不启动
                        if HUDManager.shared.isRunning {
                            _ = HUDManager.shared.stop()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                _ = HUDManager.shared.start()
                            }
                        }
                    }
                )) {
                    Text("扇形展开").tag(0)
                    Text("纵向列表").tag(1)
                }
                .pickerStyle(.segmented)
                                ForEach(0..<savedApps.count, id:\.self) { i in
                    HStack {
                        Text(savedApps[i]["name"] ?? "")
                        Spacer()
                        Text(savedApps[i]["url"] ?? "").font(.caption).foregroundColor(.gray)
                    }
                }
                .onDelete { indexSet in
                    savedApps.remove(atOffsets: indexSet)
                    Self.saveFanMenu(savedApps) // v6.1.5-7：双写+落盘+读回验证
                }
                // 添加新应用
                FanMenuAddView(savedApps: $savedApps)
            }
            Section(header: Text("其他")) {
                Toggle("键盘弹出时自动隐藏桌宠", isOn: Binding<Bool>(
                    get: { 
                        // 默认打开
                        if UserDefaults.standard.object(forKey: "autoHideWithKeyboard") == nil {
                            return true
                        }
                        return UserDefaults.standard.bool(forKey: "autoHideWithKeyboard")
                    },
                    set: { UserDefaults.standard.set($0, forKey: "autoHideWithKeyboard") }
                ))
            }
            Section(footer: Text("切换角色、调整尺寸或气泡样式后自动重启桌面悬浮生效。")) {
                EmptyView()
            }
        }
        .navigationTitle("可爱助手角色")
        .navigationBarTitleDisplayMode(.inline)
    }
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
                Text("从已安装应用选择添加")
                Spacer()
            }
        }
        .sheet(isPresented: $showPicker) {
            AppPickerView { app in
                savedApps.append(["name":app.name, "bundleId":app.bundleId])
                // v6.1.5-7：统一保存入口——双写(suite+standard)+强制落盘+写后读回验证
                GirlCharacterPickerView.saveFanMenu(savedApps)
                showPicker = false
            }
        }
    }
}
