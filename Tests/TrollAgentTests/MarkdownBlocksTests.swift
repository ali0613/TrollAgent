import XCTest
@testable import TrollAgent

/// v7.2.3-fix9：Markdown 渲染解析回归基线（病灶⑥）
/// 覆盖本轮渲染增强：标题/列表嵌套/引用分段/DSML/表格/任务列表/链接提取。
final class MarkdownBlocksTests: XCTestCase {

    // MARK: - 标题（fix4）

    func testHeadingLevel1() {
        let blocks = MarkdownBlocks.parse("# 主标题\n正文")
        XCTAssertEqual(blocks.first, .heading(level: 1, text: "主标题"))
        XCTAssertEqual(blocks.count, 2)
    }

    func testHeadingLevel3() {
        let blocks = MarkdownBlocks.parse("### 三级标题")
        XCTAssertEqual(blocks.first, .heading(level: 3, text: "三级标题"))
    }

    func testHeadingNoSpace() {
        // 模型常写 "##标题"（无空格）也要解析
        let blocks = MarkdownBlocks.parse("##标题")
        XCTAssertEqual(blocks.first, .heading(level: 2, text: "标题"))
    }

    func testHeadingTooDeepNotParsed() {
        // 超过 6 级不解析（# 过多是分隔线误判防护）
        let blocks = MarkdownBlocks.parse("####### 不是标题")
        XCTAssertNotEqual(blocks.first, .heading(level: 7, text: "不是标题"))
    }

    func testHeadingDoesNotEatBold() {
        // 标题行内的行内样式保留（渲染层 coloredBody 处理）
        let blocks = MarkdownBlocks.parse("## 加粗**内容**")
        XCTAssertEqual(blocks.first, .heading(level: 2, text: "加粗**内容**"))
    }

    // MARK: - 列表嵌套（fix5）

    func testNestedListLevels() {
        let blocks = MarkdownBlocks.parse("- 父\n  - 子\n- 兄弟")
        guard case .list(let items) = blocks.first else {
            return XCTFail("expected list")
        }
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].level, 0)
        XCTAssertEqual(items[0].text, "父")
        XCTAssertEqual(items[1].level, 1)
        XCTAssertEqual(items[1].text, "子")
        XCTAssertEqual(items[2].level, 0)
        XCTAssertEqual(items[2].text, "兄弟")
    }

    func testTabIndentLevel() {
        let blocks = MarkdownBlocks.parse("- a\n\t- b")
        guard case .list(let items) = blocks.first else {
            return XCTFail("expected list")
        }
        XCTAssertEqual(items[1].level, 1)
    }

    func testOrderedListMarkerPreserved() {
        let blocks = MarkdownBlocks.parse("1. 第一\n2. 第二")
        guard case .list(let items) = blocks.first else {
            return XCTFail("expected list")
        }
        XCTAssertTrue(items[0].ordered)
        XCTAssertEqual(items[0].marker, "1.")
        XCTAssertEqual(items[0].text, "第一")
    }

    // MARK: - 引用分段（fix1）

    func testQuoteSegmentedByBlankLine() {
        // > a\n\n> b → 两个独立 quote 块（避免巨型块）
        let blocks = MarkdownBlocks.parse("> 第一段\n\n> 第二段")
        let quotes = blocks.compactMap { block -> String? in
            if case .quote(let q) = block { return q }
            return nil
        }
        XCTAssertEqual(quotes, ["第一段", "第二段"])
    }

    func testQuoteSingleBlock() {
        let blocks = MarkdownBlocks.parse("> 引用\n> 续行")
        guard case .quote(let q) = blocks.first else {
            return XCTFail("expected quote")
        }
        XCTAssertEqual(q, "引用\n续行")
    }

    func testQuoteStopsAtPlainText() {
        let blocks = MarkdownBlocks.parse("> 引用\n正文")
        XCTAssertEqual(blocks.count, 2)
        guard case .quote(let q) = blocks[0] else {
            return XCTFail("expected quote first")
        }
        XCTAssertEqual(q, "引用")
    }

    // MARK: - DSML 文本调用识别（audit4）

    func testDSMLBlockRenderedAsCode() {
        let blocks = MarkdownBlocks.parse("<|DSML| invoke name=\"shell.exec\">\nls\n</|DSML|>")
        // 至少解析为代码块（不落普通文本丢内容）
        XCTAssertTrue(blocks.contains { block in
            if case .codeBlock = block { return true }
            return false
        })
    }

    func testAntmlBlockRecognized() {
        let blocks = MarkdownBlocks.parse("<antml:invoke name=\"web_search\">\nquery\n</antml:invoke>")
        XCTAssertTrue(blocks.contains { block in
            if case .codeBlock = block { return true }
            return false
        })
    }

    // MARK: - 表格 / 任务列表 / 代码块 / hr

    func testTableParsed() {
        let md = "| 列1 | 列2 |\n| --- | --- |\n| a | b |"
        let blocks = MarkdownBlocks.parse(md)
        guard case .table(let header, let rows)? = blocks.first(where: {
            if case .table = $0 { return true }
            return false
        }) else {
            return XCTFail("expected table")
        }
        XCTAssertEqual(header, ["列1", "列2"])
        XCTAssertEqual(rows, [["a", "b"]])
    }

    func testTasksParsed() {
        let blocks = MarkdownBlocks.parse("- [ ] 未完成\n- [x] 已完成")
        guard case .tasks(let items)? = blocks.first(where: {
            if case .tasks = $0 { return true }
            return false
        }) else {
            return XCTFail("expected tasks")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertFalse(items[0].done)
        XCTAssertTrue(items[1].done)
    }

    func testFenceCodeBlock() {
        let blocks = MarkdownBlocks.parse("```swift\nlet x = 1\n```")
        guard case .codeBlock(let code, let lang) = blocks.first else {
            return XCTFail("expected code block")
        }
        XCTAssertEqual(lang, "swift")
        XCTAssertTrue(code.contains("let x = 1"))
    }

    func testHrParsed() {
        let blocks = MarkdownBlocks.parse("---")
        XCTAssertTrue(blocks.contains { block in
            if case .hr = block { return true }
            return false
        })
    }

    // MARK: - 链接提取（工具结果链接卡）

    func testLinkExtractor() {
        let links = MarkdownBlocks.extractLinks(from: "看这里 https://github.com/zrrt/TrollAgent 和 http://a.b/c?q=1")
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].absoluteString, "https://github.com/zrrt/TrollAgent")
    }
}

/// v7.2.3-fix9：引用提取（角标 + 来源行）
final class CitationExtractorTests: XCTestCase {

    func testMarkerCount() {
        let r = CitationExtractor.extract("正文有[1]和[2][2]引用")
        XCTAssertEqual(r.markerCount, 2)
    }

    func testSourcesParsed() {
        let r = CitationExtractor.extract("正文[1]\n\n[1]: https://example.com/a\n[2]: https://example.com/b")
        XCTAssertEqual(r.sources.count, 2)
        XCTAssertEqual(r.sources[0].index, 1)
        XCTAssertEqual(r.sources[0].url.absoluteString, "https://example.com/a")
    }

    func testStripSourceLines() {
        let out = CitationExtractor.stripSourceLines("正文[1]\n[1]: https://example.com/a")
        XCTAssertFalse(out.contains("example.com"))
        XCTAssertTrue(out.contains("正文[1]"))
    }
}
