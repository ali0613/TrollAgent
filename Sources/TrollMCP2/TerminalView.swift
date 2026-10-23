import SwiftUI

/// v7.0.4：聊天框终端按钮 → 简易终端（统一环境 TrollRuntime shell.exec）
/// 无需内核启动（Asbestos 翻译器直接执行）——黑底等宽终端 UI，命令带 30s 超时。
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

    var body: some View {
        CompatNav {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(lines) { l in
                                Text(l.text)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(l.isCmd ? .green : (l.isError ? Color(red: 1.0, green: 0.3, blue: 0.3) : .white))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(10)
                    }
                    .background(Color.black)
                    .onChange(of: lines.count) { _ in
                        withAnimation { proxy.scrollTo(lines.last?.id, anchor: .bottom) }
                    }
                }
                HStack(spacing: 8) {
                    Text("$")
                        .foregroundColor(.green)
                        .font(.system(.body, design: .monospaced))
                    TextField(L10n.t("i18n_87"), text: $input)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.white)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focused)
                        .onSubmit { run() }
                    if busy {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(10)
                .background(Color(white: 0.13))
            }
            .navigationTitle(L10n.t("i18n_120"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L10n.t("ui_177")) { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.t("i18n_88")) { lines.removeAll() }
                }
            }
        }
        .onAppear {
            lines.append(TermLine(text: L10n.t("i18n_684"), isCmd: false, isError: false))
            lines.append(TermLine(text: L10n.t("i18n_89"), isCmd: false, isError: false))
            focused = true
        }
    }

    private func run() {
        let cmd = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, !busy else { return }
        lines.append(TermLine(text: "$ \(cmd)", isCmd: true, isError: false))
        history.append(cmd)
        input = ""
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = TrollRuntimeEngine.exec(cmd, timeout: 30)
            DispatchQueue.main.async {
                busy = false
                let out = r.output.isEmpty ? (r.exitCode == 0 ? "" : L10n.t("i18n_90")) : r.output
                if !out.isEmpty {
                    // 长输出截断到最后 3000 字符（终端显示）
                    let trimmed = out.count > 3000 ? String(out.suffix(3000)) + L10n.t("i18n_685") : out
                    lines.append(TermLine(text: trimmed, isCmd: false, isError: r.exitCode != 0))
                }
                if r.timedOut {
                    lines.append(TermLine(text: L10n.t("i18n_92"), isCmd: false, isError: true))
                }
                focused = true
            }
        }
    }
}
