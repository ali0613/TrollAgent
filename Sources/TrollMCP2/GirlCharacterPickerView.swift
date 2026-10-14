import SwiftUI
import UIKit

/// v4.5.1：可爱助手角色选择页——显示小萝莉/兔娘/猫娘三个角色卡片（带形象图），点选即切换
/// 入口：设置 → 可爱助手 → 可爱助手角色
struct GirlCharacterPickerView: View {
    @ObservedObject private var companion = GirlCompanion.shared

    var body: some View {
        Form {
            Section(header: Text("选择可爱助手的角色")) {
                ForEach(GirlCharacter.allCases) { c in
                    Button {
                        companion.selectedCharacter = c
                        // v6.0.7：桌面悬浮 HUD 读当前角色，切换后重启悬浮让新角色生效
                        _ = HUDManager.shared.stop()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            _ = HUDManager.shared.start()
                        }
                    } label: {
                        HStack(spacing: 14) {
                            // 角色形象（idle 帧）
                            if let img = UIImage(named: "\(c.iconPrefix)_idle") {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 46, height: 69)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            } else {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.pink.opacity(0.15))
                                    .frame(width: 46, height: 69)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(c.rawValue)
                                    .font(.headline)
                                Text(c == .loli ? "粉粉洛丽塔小萝莉" : (c == .rabit ? "黑丝高马尾兔娘" : "白色性感御姐猫娘"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if companion.selectedCharacter == c {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.pink)
                            } else {
                                Image(systemName: "circle")
                                    .font(.title2)
                                    .foregroundColor(.secondary.opacity(0.4))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            Section(header: Text("悬浮尺寸")) {
                VStack {
                    HStack {
                        Text("小")
                        Slider(value: $companion.floatSize, in: 170...300, step: 5, onEditingChanged: { editing in
                            if !editing {
                                // 拖动结束松手后才重启HUD生效
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    _ = HUDManager.shared.stop()
                                    _ = HUDManager.shared.start()
                                }
                            }
                        })
                        Text("大")
                    }
                    Text("当前尺寸：\(Int(companion.floatSize)) pt")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Section(header: Text("气泡样式")) {
                Picker("气泡样式", selection: $companion.bubbleStyle) {
                    Text("经典圆角").tag(0)
                    Text("椭圆气泡").tag(1)
                    Text("方形硬边").tag(2)
                    Text("爆炸吐槽").tag(3)
                }
                .pickerStyle(.segmented)
                .onChange(of: companion.bubbleStyle) { _ in
                    // 气泡样式变化后自动重启HUD生效
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        _ = HUDManager.shared.stop()
                        _ = HUDManager.shared.start()
                    }
                }
            }
            Section(header: Text("快捷菜单"), footer: Text("单击桌宠弹出的菜单样式和应用，可添加/删除，重启后生效。URL Scheme比如微信weixin://，抖音snssdk1128://")) {
                Picker("弹出样式", selection: Binding<Int>(
                    get: { UserDefaults.standard.integer(forKey: "fanMenuStyle") },
                    set: { UserDefaults.standard.set($0, forKey: "fanMenuStyle") }
                )) {
                    Text("扇形展开").tag(0)
                    Text("纵向列表").tag(1)
                }
                .pickerStyle(.segmented)
                let defaults = UserDefaults.standard
                let savedApps = defaults.array(forKey: "fanMenuApps") as? [[String:String]] ?? [
                    ["name":"微信", "url":"weixin://"],
                    ["name":"抖音", "url":"snssdk1128://"],
                    ["name":"相机", "url":"camera://"],
                    ["name":"设置", "url":"App-prefs://"]
                ]
                ForEach(0..<savedApps.count, id:\.self) { i in
                    HStack {
                        Text(savedApps[i]["name"] ?? "")
                        Spacer()
                        Text(savedApps[i]["url"] ?? "").font(.caption).foregroundColor(.gray)
                    }
                }
                .onDelete { indexSet in
                    var apps = savedApps
                    apps.remove(atOffsets: indexSet)
                    defaults.set(apps, forKey: "fanMenuApps")
                }
                // 添加新应用
                FanMenuAddView()
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
    @State private var name = ""
    @State private var url = ""
    var body: some View {
        VStack {
            HStack {
                TextField("应用名称", text: $name)
                TextField("URL Scheme 比如 weixin://", text: $url)
                Button("添加") {
                    guard !name.isEmpty, !url.isEmpty else { return }
                    let defaults = UserDefaults.standard
                    var apps = defaults.array(forKey: "fanMenuApps") as? [[String:String]] ?? []
                    apps.append(["name":name, "url":url])
                    defaults.set(apps, forKey: "fanMenuApps")
                    name = ""
                    url = ""
                }
                .disabled(name.isEmpty || url.isEmpty)
            }
        }
    }
}
