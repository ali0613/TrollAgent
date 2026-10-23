import SwiftUI

// v2.9.142：宏管理页（录制/回放/删除/导出）
// 入口：聊天输入框「🎬 宏」芯片；录制中显示红点状态

struct MacroView: View {
    @ObservedObject private var ui = AppUIState.shared
    @State private var macros: [[String: Any]] = []
    @State private var showNewName = false
    @State private var newName = ""
    @State private var toast: String?
    @Environment(\.presentationMode) private var pm

    var body: some View {
        CompatNav {
            Group {
                if MacroRecorder.shared.isRecording {
                    recordingBanner
                }
                if macros.isEmpty && !MacroRecorder.shared.isRecording {
                    emptyState
                } else {
                    List {
                        ForEach(macros.indices, id: \.self) { i in
                            row(macros[i])
                        }
                    }
                    .listStyle(InsetGroupedListStyle())
                }
            }
            .navigationTitle(L10n.t("ui_183", L10n.t("ui_183")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L10n.t("ui_177", L10n.t("ui_177"))) {
                        pm.wrappedValue.dismiss()
                        ui.macroPresented = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { refresh() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .overlay(Group {
                if let t = toast {
                    Text(t)
                        .font(.footnote)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.75))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }, alignment: .top)
        }
        .onAppear { refresh() }
        .alert(L10n.t("ui_184", L10n.t("ui_184")), isPresented: $showNewName) {
            TextField(L10n.t("ui_185", L10n.t("ui_185")), text: $newName)
            Button(L10n.t("ui_48", L10n.t("i18n_687"))) {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { showToast(L10n.t("ui_186", L10n.t("ui_186"))); return }
                MacroRecorder.shared.start(name: name)
                newName = ""
                showToast("🎬 " + L10n.t("ui_187", L10n.t("ui_187")))
                refresh()
            }
            Button(L10n.t("ui_40", L10n.t("ui_40")), role: .cancel) { newName = "" }
        }
    }

    private var recordingBanner: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.red).frame(width: 10, height: 10)
            Text("🎬 \(L10n.t("ui_188", "Recording")): \(MacroRecorder.shared.currentName)")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button {
                let (ok, msg) = MacroRecorder.shared.stop()
                showToast(msg)
                refresh()
            } label: {
                Text(L10n.t("ui_189", L10n.t("ui_189")))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.15))
                    .foregroundColor(.red)
                    .cornerRadius(8)
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.08))
        .cornerRadius(12)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 44))
                .foregroundColor(.tmCyan.opacity(0.6))
            Text(L10n.t("ui_190", L10n.t("ui_190")))
                .font(.headline)
            Text(L10n.t("ui_191", L10n.t("ui_191")))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                showNewName = true
            } label: {
                Text("🎬 " + L10n.t("ui_192", L10n.t("ui_192")))
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ m: [String: Any]) -> some View {
        let name = m["name"] as? String ?? "?"
        let count = m["steps"] as? Int ?? 0
        let created = m["created"] as? Int ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "play.rectangle")
                    .foregroundColor(.tmCyan)
                Text(name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(count) " + L10n.t("ui_193", L10n.t("ui_193")))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(L10n.t("ui_194", L10n.t("ui_194")) + " " + Self.dateStr(created))
                .font(.caption2)
                .foregroundColor(.secondary)
            HStack(spacing: 10) {
                runButton(name, loop: 1, label: "▶ 1")
                runButton(name, loop: 5, label: "▶ 5")
                Button {
                    let ok = MacroStore.delete(name)
                    showToast(ok ? L10n.t("ui_195", L10n.t("ui_195")) + " ✓" : L10n.t("ui_195", L10n.t("ui_195")) + " ✗")
                    refresh()
                } label: {
                    Label(L10n.t("ui_195", L10n.t("ui_195")), systemImage: "trash")
                        .font(.caption)
                }
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    private func runButton(_ name: String, loop: Int, label: String) -> some View {
        Button {
            runMacro(name: name, loop: loop)
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.14))
                .foregroundColor(.blue)
                .cornerRadius(8)
        }
    }

    private func runMacro(name: String, loop: Int) {
        ui.macroPresented = false
        // 等宏页 cover 关闭动画完成再回放，避免与控制中心 cover 冲突
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            var out: [String: Any] = [:]
            let sem = DispatchSemaphore(value: 0)
            MacroRunner.run(name: name, loop: loop, stepDelayMs: 300) { ok, msg in
                out["ok"] = ok
                out["message"] = msg
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 600)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                ui.macroPresented = true
                refresh()
                showToast(out["message"] as? String ?? L10n.t("i18n_1180"))
            }
        }
    }

    private func refresh() {
        macros = MacroStore.list()
    }

    private func showToast(_ t: String) {
        withAnimation { toast = t }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { toast = nil }
    }

    private static func dateStr(_ ts: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}
