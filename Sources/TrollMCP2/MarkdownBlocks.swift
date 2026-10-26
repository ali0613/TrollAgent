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

/// v7.1.109-minis：提取正文/工具结果里的可打开链接——
/// 1) minis://open?url=<目标>（AI 主动推送标记，对齐 Minis OSC minis-open 语义：
///    shell 输出/正文带此标记 → UI 渲染链接卡一键打开）
/// 2) 裸 http/https URL（点击开内置浏览器，对齐 Minis LinkPreviewView 能力）
enum LinkExtractor {

    /// 返回去重后的可打开链接
    static func extractLinks(from text: String) -> [URL] {
        var urls: [URL] = []
        var seen = Set<String>()
        // 1) minis://open?url= 标记（支持 URL 编码或裸 URL）
        var searchRange = text.startIndex..<text.endIndex
        while let r = text.range(of: "minis://open?url=", range: searchRange) {
            let rest = text[r.upperBound...]
            let end = rest.firstIndex { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == ")" || $0 == "]" || $0 == "，" || $0 == "。" } ?? rest.endIndex
            var u = String(rest[..<end])
            if u.contains("%") { u = u.removingPercentEncoding ?? u }
            if let url = URL(string: u), !seen.contains(u) {
                urls.append(url)
                seen.insert(u)
            }
            searchRange = end..<text.endIndex
        }
        // 2) 裸 http/https URL
        let pattern = #"https?://[^\s"'\(\)\]\}，。；：,;]+"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(text.startIndex..., in: text)
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match = match, let r = Range(match.range, in: text) else { return }
                var u = String(text[r])
                while let last = u.last, "。，；：,.;:)）]】".contains(last) { u.removeLast() }
                if seen.contains(u) { return }
                guard let url = URL(string: u) else { return }
                urls.append(url)
                seen.insert(u)
            }
        }
        return urls
    }
}

/// 链接卡：点击开内置浏览器（对齐 Minis LinkPreviewView 的"点击 → 应用内打开"）
struct LinkCardView: View {
    let url: URL

    var body: some View {
        Button {
            BrowserManager.shared.open(url.absoluteString)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 12))
                    .foregroundColor(.blue)
                Text(url.host ?? url.absoluteString)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.blue)
                    .lineLimit(1)
                Text(url.absoluteString)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.blue.opacity(0.08))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
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
                    // v7.1.109-minis：文本块下方附加链接卡（URL / minis:// 标记 → 一键开内置浏览器）
                    VStack(alignment: .leading, spacing: 4) {
                        Text(coloredBody(t))
                            .font(.body)
                            .textSelection(.enabled)
                        let links = LinkExtractor.extractLinks(from: t)
                        if !links.isEmpty {
                            ForEach(links, id: \.self) { LinkCardView(url: $0) }
                        }
                    }
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
