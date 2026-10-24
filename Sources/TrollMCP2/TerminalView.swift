import SwiftUI

/// v7.0.4：聊天框终端按钮 → 简易终端（统一环境 TrollRuntime shell.exec）
/// 无需内核启动（Asbestos 翻译器直接执行）——黑底等宽终端 UI，命令带 30s 超时。
/// v7.1.7：视觉重构——macOS 终端质感：圆角卡片 + 头栏三圆点 + 深蓝黑渐变底 +
/// 输入胶囊 + 命令/输出/错误三色层级 + 上下键历史导航。
struct TerminalView: View {
    @Environment(\.presentationMode) private var presentationMode
    @State private var input = ""
    @State private var lines: [TermLine] = []
    @State private var history: [String] = []
    @State private var busy = false
    @FocusState private var focused: Bool

    struct TermLine: Identifiable {
        let id = UUID()
        let text: String
        let isCmd: Bool
        let isError: Bool
    }

    // 配色常量（暗黑终端经典）
    private let bgTop = Color(red: 0.055, green: 0.065, blue: 0.085)      // 深蓝黑顶
    private let bgBottom = Color(red: 0.035, green: 0.045, blue: 0.065)   // 深蓝黑底
    private let promptGreen = Color(red: 0.45, green: 0.92, blue: 0.62)   // 提示符绿
    private let cmdGreen = Color(red: 0.62, green: 1.0, blue: 0.74)       // 命令亮绿
    private let errorRed = Color(red: 1.0, green: 0.32, blue: 0.33)       // 错误红
    private let outputWhite = Color(white: 0.92)                          // 输出暖白

    var body: some View {
        CompatNav {
            VStack(spacing: 0) {
                // ── 头栏：三圆点 + 状态 ──
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 1.0, green: 0.36, blue: 0.32)).frame(width: 9, height: 9)
                    Circle().fill(Color(red: 0.95, green: 0.77, blue: 0.25)).frame(width: 9, height: 9)
                    Circle().fill(Color(red: 0.32, green: 0.87, blue: 0.42)).frame(width: 9, height: 9)
                    Spacer()
                    if busy {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text(L10n.t("i18n_1245"))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(promptGreen)
                        }
                    } else {
                        Circle().fill(promptGreen).frame(width: 7, height: 7)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(Color(white: 0.045))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color(white: 0.1)).frame(height: 0.5)
                }

                // ── 输出区 ──
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(lines) { l in
                                HStack(alignment: .top, spacing: 6) {
                                    if l.isCmd {
                                        Text("❯")
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundColor(promptGreen)
                                            .frame(width: 18, alignment: .trailing)
                                    } else if l.isError {
                                        Text("✗")
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundColor(errorRed)
                                            .frame(width: 18, alignment: .trailing)
                                    } else {
                                        // 输出行：无符号，缩进对齐
                                        Color.clear.frame(width: 18)
                                    }
                                    Text(l.text)
                                        .font(.system(size: 13.5, design: .monospaced))
                                        .foregroundColor(l.isCmd ? cmdGreen : (l.isError ? errorRed : outputWhite))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, l.isCmd ? 1 : 0)
                                }
                                .padding(.horizontal, 12)
                                .background(l.isCmd ? Color.white.opacity(0.035) : Color.clear)
                                .cornerRadius(4)
                            }
                        }
                        .padding(.vertical, 8)
                        .id("bottom")
                    }
                    .background(
                        LinearGradient(colors: [bgTop, bgBottom],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .onChange(of: lines.count) { _ in
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }

                // ── 输入栏：胶囊 ──
                HStack(spacing: 10) {
                    Text("$")
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundColor(promptGreen)
                    TextField(L10n.t("i18n_282"), text: $input)
                        .font(.system(size: 14.5, design: .monospaced))
                        .foregroundColor(outputWhite)
                        .tint(promptGreen)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focused)
                        .submitLabel(.run)
                        .onSubmit { run() }
                    if !input.isEmpty {
                        Button {
                            input = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(Color(white: 0.4))
                        }
                    }
                    Button {
                        run()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(busy ? Color(white: 0.3) : promptGreen)
                    }
                    .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 12)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(white: 0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                        )
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(white: 0.03))
                .overlay(alignment: .top) {
                    Rectangle().fill(Color(white: 0.1)).frame(height: 0.5)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(white: 0.75))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        withAnimation { lines.removeAll() }
                        lines.append(TermLine(text: L10n.t("i18n_1195"), isCmd: false, isError: false))
                        lines.append(TermLine(text: L10n.t("i18n_284"), isCmd: false, isError: false))
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color(white: 0.75))
                    }
                }
            }
        }
        .onAppear {
            lines.append(TermLine(text: L10n.t("i18n_1195"), isCmd: false, isError: false))
            lines.append(TermLine(text: L10n.t("i18n_284"), isCmd: false, isError: false))
            focused = true
        }
    }

    private func run() {
        let cmd = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, !busy else { return }
        lines.append(TermLine(text: cmd, isCmd: true, isError: false))
        history.append(cmd)
        input = ""
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = TrollRuntimeEngine.exec(cmd, timeout: 30)
            DispatchQueue.main.async {
                busy = false
                let out = r.output.isEmpty ? (r.exitCode == 0 ? "" : L10n.t("i18n_285")) : r.output
                if !out.isEmpty {
                    // 长输出截断到最后 3000 字符（终端显示）
                    let trimmed = out.count > 3000 ? String(out.suffix(3000)) + L10n.t("i18n_1196") : out
                    lines.append(TermLine(text: trimmed, isCmd: false, isError: r.exitCode != 0))
                }
                if r.timedOut {
                    lines.append(TermLine(text: L10n.t("i18n_287"), isCmd: false, isError: true))
                }
                focused = true
            }
        }
    }
}
