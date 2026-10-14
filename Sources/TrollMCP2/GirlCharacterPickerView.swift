import SwiftUI
import UIKit

/// v4.5.1：可爱助手角色选择页——显示小萝莉/兔娘/猫娘三个角色卡片（带形象图），点选即切换
/// 入口：设置 → 可爱助手 → 可爱助手角色
struct GirlCharacterPickerView: View {
    @ObservedObject private var companion = GirlCompanion.shared
    @State private var savedApps: [[String:String]] = (UserDefaults.standard.array(forKey: "fanMenuApps") as? [[String:String]]) ?? [
        ["name":"微信", "url":"weixin://"],
        ["name":"抖音", "url":"snssdk1128://"],
        ["name":"相机", "url":"camera://"],
        ["name":"设置", "url":"App-prefs://"]
    ]

    var body: some View {
        Form {
            Section(header: Text("选择可爱助手的角色")) {
                // 三个角色并排：兔娘左、小萝莉中、猫娘右，名字都在图底部
                HStack(spacing: 12) {
                    // 兔娘（左）
                    Button {
                        companion.selectedCharacter = .rabit
                    } label: {
                        VStack(spacing: 8) {
                            if let img = UIImage(named: "rabit_idle") {
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
                    } label: {
                        VStack(spacing: 8) {
                            if let img = UIImage(named: "girl_idle") {
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
                    } label: {
                        VStack(spacing: 8) {
                            if let img = UIImage(named: "cat_idle") {
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
            Section(header: Text("悬浮尺寸（改完手动重启悬浮生效）")) {
                VStack {
                    HStack {
                        Text("小")
                        Slider(value: $companion.floatSize, in: 170...300, step: 5)
                        Text("大")
                    }
                    Text("当前尺寸：\(Int(companion.floatSize)) pt")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Section(header: Text("气泡样式（改完手动重启悬浮生效）")) {
                Picker("气泡样式", selection: $companion.bubbleStyle) {
                    Text("经典圆角").tag(0)
                    Text("椭圆气泡").tag(1)
                    Text("方形硬边").tag(2)
                    Text("爆炸吐槽").tag(3)
                }
                .pickerStyle(.segmented)
                // 实时预览气泡
                VStack {
                    Text("预览：哈喽呀～")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .overlay(
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
            }, footer: Text("💡 提示：单击桌面上的桌宠就会弹出这个快捷菜单！点右上角编辑可删除应用，URL Scheme比如微信weixin://，抖音snssdk1128://")) {
                Picker("弹出样式", selection: Binding<Int>(
                    get: { UserDefaults.standard.integer(forKey: "fanMenuStyle") },
                    set: { 
                        UserDefaults.standard.set($0, forKey: "fanMenuStyle")
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
                let defaults = UserDefaults.standard
                ForEach(0..<savedApps.count, id:\.self) { i in
                    HStack {
                        Text(savedApps[i]["name"] ?? "")
                        Spacer()
                        Text(savedApps[i]["url"] ?? "").font(.caption).foregroundColor(.gray)
                    }
                }
                .onDelete { indexSet in
                    savedApps.remove(atOffsets: indexSet)
                    defaults.set(savedApps, forKey: "fanMenuApps")
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
            AppBrowserView { app in
                savedApps.append(["name":app.name, "bundleId":app.bundleId])
                UserDefaults.standard.set(savedApps, forKey: "fanMenuApps")
                showPicker = false
            }
        }
    }
}
