import SwiftUI

/// v7.1.109-minis：AI 正文 Markdown 块渲染（对齐 OpenMinis SelectableMarkdownView 能力子集——
/// 用户要求"AI 能输出表格展示、命令行文本展示"）。
/// 覆盖：fenced 代码块（黑底等宽命令行样式，与工具结果同视觉）、Markdown 表格（LazyVGrid 栅格）、
/// 普通文本（沿用 ChatView 反引号橙色 + **加粗** 正则着色）。
/// 流式打字机路径不启用（打字机下表格/代码块会跳动），完成消息才块渲染。
enum MarkdownBlocks {

    enum Block: Equatable {
        case text(String)
        case codeBlock(String)
        case table(header: [String], rows: [[String]])
    }

    static func parse(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [Block] = []
        var i = 0
        var textBuf: [String] = []
        func flushText() {
            if !textBuf.isEmpty {
                blocks.append(.text(textBuf.joined(separator: "\n")))
                textBuf = []
            }
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // fenced 代码块：``` 开头（语言标记忽略）
            if trimmed.hasPrefix("```") {
                flushText()
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { i += 1; break }
                    code.append(l)
                    i += 1
                }
                blocks.append(.codeBlock(code.joined(separator: "\n")))
                continue
            }
            // 表格：当前行 | 开头结尾 && 下一行是分隔行（|---|---|）→ 表头 + 数据行
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|"),
               i + 1 < lines.count,
               isTableSeparator(lines[i + 1]) {
                flushText()
                let header = cells(of: line)
                i += 2
                var rows: [[String]] = []
                while i < lines.count {
                    let dl = lines[i].trimmingCharacters(in: .whitespaces)
                    if dl.hasPrefix("|") && dl.hasSuffix("|") {
                        rows.append(cells(of: lines[i]))
                        i += 1
                    } else { break }
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            textBuf.append(line)
            i += 1
        }
        flushText()
        return blocks
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|"), t.hasSuffix("|") else { return false }
        let inner = t.dropFirst().dropLast()
        guard inner.contains("-") else { return false }
        return inner.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " || $0 == "|" }
    }

    private static func cells(of line: String) -> [String] {
        let t = line.trimmingCharacters(in: .whitespaces)
        let body = t.hasPrefix("|") ? String(t.dropFirst()) : t
        let end = body.hasSuffix("|") ? String(body.dropLast()) : body
        return end.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }
}

/// 完成消息的块组合渲染视图
struct MarkdownBlocksView: View {
    let text: String
    /// ChatView 的正则着色闭包（反引号橙色 + **粗体**），普通文本块复用
    let coloredBody: (String) -> AttributedString

    var body: some View {
        let blocks = MarkdownBlocks.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .text(let t):
                    Text(coloredBody(t))
                        .font(.body)
                        .textSelection(.enabled)
                case .codeBlock(let code):
                    // 命令行文本展示：黑底等宽白字（与工具结果同一视觉语言）
                    Text(code)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color(.separator), lineWidth: 0.5)
                        )
                        .textSelection(.enabled)
                case .table(let header, let rows):
                    MarkdownTableView(header: header, rows: rows)
                }
            }
        }
    }
}

/// Markdown 表格渲染（LazyVGrid，iOS 14+ 兼容；部署目标 iOS 15 不能使用 Grid）
struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        let columns = max(1, header.count)
        let gridCols = (0..<columns).map { _ in GridItem(.flexible(minimum: 40), spacing: 8) }
        VStack(alignment: .leading, spacing: 0) {
            // 表头（蓝 + 半粗等宽）
            LazyVGrid(columns: gridCols, spacing: 6) {
                ForEach(0..<columns, id: \.self) { i in
                    Text(i < header.count ? header[i] : "")
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.bottom, 4)
            // 数据行
            ForEach(rows, id: \.self) { row in
                LazyVGrid(columns: gridCols, spacing: 6) {
                    ForEach(0..<columns, id: \.self) { i in
                        Text(i < row.count ? row[i] : "")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(8)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(.separator), lineWidth: 0.5)
        )
    }
}
