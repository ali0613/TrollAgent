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
                // 上面小萝莉大卡片，横向跪姿
                Button {
                    companion.selectedCharacter = .loli
                    // 改设置只存参数，绝对不自动启动/重启桌宠
                } label: {
                    HStack(spacing: 16) {
                        if let img = UIImage(named: "girl_idle") {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 110)
                        }
                        Text("小萝莉")
                            .font(.title2)
                            .fontWeight(.bold)
                        Spacer()
                        if companion.selectedCharacter == .loli {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title)
                                .foregroundColor(.pink)
                        } else {
                            Image(systemName: "circle")
                                .font(.title)
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
                // 下面兔娘和猫娘并排小卡片
                HStack(spacing: 12) {
                    // 兔娘
                    Button {
                        companion.selectedCharacter = .rabit
                    } label: {
                        VStack(spacing: 8) {
                            if let img = UIImage(named: "rabit_idle") {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 100)
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
                    // 猫娘
                    Button {
                        companion.selectedCharacter = .cat
                    } label: {
                        VStack(spacing: 8) {
                            if let img = UIImage(named: "cat_idle") {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 100)
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
                    set: { UserDefaults.standard.set($0, forKey: "fanMenuStyle") }
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
    @State private var name = ""
    @State private var url = ""
    var body: some View {
        VStack {
            HStack {
                TextField("应用名称", text: $name)
                TextField("URL Scheme 比如 weixin://", text: $url)
                Button("添加") {
                    guard !name.isEmpty, !url.isEmpty else { return }
                    savedApps.append(["name":name, "url":url])
                    UserDefaults.standard.set(savedApps, forKey: "fanMenuApps")
                    name = ""
                    url = ""
                }
                .disabled(name.isEmpty || url.isEmpty)
            }
        }
    }
}
