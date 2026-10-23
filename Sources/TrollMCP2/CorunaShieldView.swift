import SwiftUI

// MARK: - Coruna 安全盾视图（360 风格）
struct CorunaShieldView: View {
    @AppStorage("coruna_shield_enabled") private var shieldEnabled = true
    @AppStorage("coruna_blocked_count") private var blockedCount = 0
    @AppStorage("coruna_last_threat") private var lastThreat: String = ""
    
    // 模拟检测状态：true=安全，false=检测到威胁
    @State private var isSafe = true
    @State private var animateShield = false
    
    private var shieldGradient: LinearGradient {
        if !shieldEnabled {
            return LinearGradient(colors: [.gray, .gray.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        return isSafe 
            ? LinearGradient(colors: [Color(red: 0.3, green: 0.9, blue: 0.5), Color(red: 0.1, green: 0.7, blue: 0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [Color(red: 0.95, green: 0.4, blue: 0.4), Color(red: 0.8, green: 0.2, blue: 0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    
    var body: some View {
        ZStack {
            // 背景渐变（浅绿亮一点）
            (shieldEnabled 
                ? (isSafe ? LinearGradient(colors: [Color(red: 0.85, green: 0.98, blue: 0.9), Color(red: 0.7, green: 0.95, blue: 0.8)], startPoint: .top, endPoint: .bottom)
                          : LinearGradient(colors: [Color(red: 0.98, green: 0.85, blue: 0.85), Color(red: 0.95, green: 0.7, blue: 0.7)], startPoint: .top, endPoint: .bottom))
                : LinearGradient(colors: [Color(red: 0.95, green: 0.95, blue: 0.95), Color(red: 0.9, green: 0.9, blue: 0.9)], startPoint: .top, endPoint: .bottom))
                .edgesIgnoringSafeArea(.all)
            
            ScrollView {
                VStack(spacing: 24) {
                    // 顶部大盾牌
                    VStack(spacing: 16) {
                        ZStack {
                            // 外圈光环
                            Circle()
                                .stroke(shieldEnabled ? (isSafe ? Color(red: 0.2, green: 0.7, blue: 0.4) : .red) : .gray, lineWidth: 3)
                                .frame(width: 140, height: 140)
                                .scaleEffect(animateShield ? 1.1 : 1.0)
                                .opacity(animateShield ? 0.3 : 0.6)
                            
                            // 盾牌（用 iOS 16 肯定有的图标）
                            Image(systemName: isSafe ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                                .font(.system(size: 64))
                                .foregroundStyle(shieldGradient)
                                .shadow(color: shieldEnabled ? (isSafe ? .green : .red) : .gray, radius: 20)
                        }
                        .padding(.top, 40)
                        
                        VStack(spacing: 8) {
                            Text(shieldEnabled ? (isSafe ? L10n.t("i18n_718") : L10n.t("i18n_719")) : L10n.t("i18n_720"))
                                .font(.largeTitle)
                                .fontWeight(.bold)
                                .foregroundColor(isSafe ? Color(red: 0.1, green: 0.5, blue: 0.3) : .red)
                            
                            Text(shieldEnabled 
                                ? (isSafe ? L10n.t("i18n_721") : L10n.t("i18n_722"))
                                : L10n.t("i18n_723"))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // 统计卡片
                    HStack(spacing: 16) {
                        StatCard(title: L10n.t("i18n_724"), value: "\(blockedCount)", unit: L10n.t("i18n_725"), icon: "hand.raised.fill", color: .orange)
                        StatCard(title: L10n.t("i18n_726"), value: shieldEnabled ? "ON" : "OFF", unit: "", icon: "shield.fill", color: shieldEnabled ? .green : .gray)
                        StatCard(title: L10n.t("i18n_727"), value: "17.2", unit: L10n.t("i18n_728"), icon: "iphone", color: .blue)
                    }
                    .padding(.horizontal)
                    
                    // 开关按钮
                    Button(action: {
                        withAnimation(.spring()) {
                            shieldEnabled.toggle()
                        }
                    }) {
                        HStack {
                            Image(systemName: shieldEnabled ? "power.circle.fill" : "power.circle")
                                .font(.title2)
                            Text(shieldEnabled ? L10n.t("i18n_729") : L10n.t("i18n_730"))
                                .font(.headline)
                        }
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(shieldEnabled 
                            ? LinearGradient(colors: [.red.opacity(0.8), .red], startPoint: .leading, endPoint: .trailing)
                            : LinearGradient(colors: [.green.opacity(0.8), .green], startPoint: .leading, endPoint: .trailing))
                        .cornerRadius(16)
                    }
                    .padding(.horizontal)
                    
                    // 防御措施卡片
                    VStack(alignment: .leading, spacing: 16) {
                        Text(L10n.t("i18n_731"))
                            .font(.headline)
                            .foregroundColor(.primary)
                            .padding(.horizontal)
                        
                        VStack(spacing: 12) {
                            DefenseRow(icon: "globe", title: L10n.t("i18n_732"), desc: L10n.t("i18n_733"), enabled: shieldEnabled)
                            DefenseRow(icon: "safari", title: L10n.t("i18n_981"), desc: L10n.t("i18n_734"), enabled: shieldEnabled)
                            DefenseRow(icon: "doc.text.magnifyingglass", title: L10n.t("i18n_982"), desc: L10n.t("i18n_735"), enabled: shieldEnabled)
                            DefenseRow(icon: "lock.shield", title: L10n.t("i18n_736"), desc: L10n.t("i18n_983"), enabled: shieldEnabled)
                        }
                        .padding(.horizontal)
                    }
                    
                    // 漏洞说明
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.t("i18n_984"))
                            .font(.headline)
                            .foregroundColor(.primary)
                            .padding(.horizontal)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            InfoRow(label: L10n.t("i18n_737"), value: "iOS 13.0 - 17.2.1")
                            InfoRow(label: L10n.t("i18n_738"), value: L10n.t("i18n_739"))
                            InfoRow(label: L10n.t("i18n_740"), value: L10n.t("i18n_741"))
                            InfoRow(label: L10n.t("i18n_742"), value: L10n.t("i18n_985"))
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(12)
                        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
                        .padding(.horizontal)
                    }
                    
                    // Web 注入工具入口
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.t("i18n_743"))
                            .font(.headline)
                            .foregroundColor(.primary)
                            .padding(.horizontal)

                        NavigationLink(destination: CorunaInjectView()) {
                            HStack(spacing: 12) {
                                Image(systemName: "bolt.shield.fill")
                                    .font(.title2)
                                    .foregroundColor(.tmIndigo)
                                    .frame(width: 40)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L10n.t("i18n_744"))
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text(L10n.t("i18n_986"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .background(Color(.systemBackground))
                            .cornerRadius(12)
                            .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
                            .padding(.horizontal)
                        }
                    }

                    // 底部
                    Text(L10n.t("i18n_987"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 40)
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                animateShield = true
            }
        }
    }
}

// MARK: - 统计卡片
struct StatCard: View {
    let title: String
    let value: String
    let unit: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                    if !unit.isEmpty {
                        Text(unit)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
    }
}

// MARK: - 防御措施行
struct DefenseRow: View {
    let icon: String
    let title: String
    let desc: String
    let enabled: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(enabled ? .green : .gray)
                .frame(width: 40)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)
                Text(desc)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(enabled ? .green : .gray)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
    }
}

// MARK: - 信息行
struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .foregroundColor(.primary)
                .fontWeight(.medium)
        }
    }
}
