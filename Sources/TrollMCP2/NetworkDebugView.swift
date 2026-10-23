import SwiftUI

/// v2.8.4：网络兼容日志视图
/// 展示 OpenAIClient 自适应降级的过程记录，以及每个模型配置当前记忆的兼容级别。
/// 排查中转站 "Invalid request parameter" 类问题时，先看这里。
/// v2.9.77：界面美化——PageHeader + 卡片化
struct NetworkDebugView: View {
    @ObservedObject private var log = NetworkLog.shared
    @ObservedObject private var models = ModelStore.shared
    @State private var newestFirst = true

    private func levelName(_ level: Int) -> String {
        switch level {
        case 0: return L10n.t("i18n_688")
        case 1: return L10n.t("i18n_689")
        case 2: return L10n.t("i18n_1141")
        case 3: return L10n.t("i18n_690")
        case 4: return L10n.t("i18n_691")
        case 5: return L10n.t("i18n_1142")
        default: return L10n.t("i18n_692", level)
        }
    }

    var body: some View {
        PageContainer {
            PageHeader(
                icon: "network",
                title: L10n.t("page_netlog"),
                subtitle: L10n.t("page_netlog_sub"),
                colors: [.orange, .tmBrown]
            )

            // 兼容级别说明
            CardSectionHeader(icon: "list.number", title: L10n.t("i18n_693"), color: .orange)
            CardBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.t("ui_3"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach([0, 1, 2, 5, 3, 4], id: \.self) { lv in
                        HStack {
                            Text(L10n.t("ui_165", lv))
                                .font(.system(.caption, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(6)
                            Spacer()
                            Text(levelName(lv))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            // 各模型当前级别
            CardSectionHeader(icon: "memorychip", title: L10n.t("i18n_694"))
            CardBox {
                VStack(alignment: .leading, spacing: 10) {
                    if models.configs.isEmpty {
                        Text(L10n.t("home_empty_title"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    ForEach(models.configs) { c in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text("\(c.model)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("L\(c.compatLevel) · \(levelName(c.compatLevel))")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(c.compatLevel >= 3 && c.compatLevel != 5 ? .orange : .green)
                        }
                        .padding(.vertical, 2)
                    }
                    Divider()
                    Button(action: resetLevels) {
                        HStack {
                            Spacer()
                            Label(L10n.t("i18n_695"), systemImage: "arrow.counterclockwise")
                                .font(.caption)
                                .foregroundColor(.orange)
                            Spacer()
                        }
                    }
                }
            }

            // 最近请求日志
            HStack {
                CardSectionHeader(icon: "clock.arrow.circlepath", title: L10n.t("i18n_696"), color: .orange)
                Spacer()
                Button {
                    newestFirst.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: newestFirst ? "clock.fill" : "clock.arrow.circlepath")
                        Text(newestFirst ? L10n.t("i18n_856") : L10n.t("i18n_857")).font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(6)
                }
            }
            CardBox {
                VStack(alignment: .leading, spacing: 6) {
                    if log.entries.isEmpty {
                        Text(L10n.t("ui_93"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    let displayed = newestFirst ? log.entries : Array(log.entries.reversed())
                    ForEach(Array(displayed.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(line.contains(L10n.t("i18n_855")) ? .red : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .navigationTitle(L10n.t("page_netlog"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func resetLevels() {
        for i in models.configs.indices {
            models.configs[i].compatLevel = 0
        }
        models.save()
        NetworkLog.shared.log(L10n.t("i18n_698"))
    }
}
