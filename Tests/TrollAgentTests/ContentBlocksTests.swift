import XCTest
@testable import TrollAgent

/// v7.2.3-fix18：正文 block 化回归基线——文本/工具强隔离解析
final class ContentBlocksTests: XCTestCase {

    func testPlainTextNoTags() {
        let blocks = ContentBlocks.split("普通正文，无任何标签")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .text)
        XCTAssertEqual(blocks[0].text, "普通正文，无任何标签")
    }

    func testDSMLInvokeExtracted() {
        let s = "先解说\n<|DSML| invoke name=\"shell.exec\">{\"command\":\"ls\"}\n</|DSML|>\n后总结"
        let blocks = ContentBlocks.split(s)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].kind, .text)
        XCTAssertEqual(blocks[0].text, "先解说\n")
        XCTAssertEqual(blocks[1].kind, .tool)
        XCTAssertEqual(blocks[1].toolName, "shell.exec")
        XCTAssertTrue(blocks[1].toolArgs?.contains("ls") ?? false)
        XCTAssertEqual(blocks[2].kind, .text)
        XCTAssertEqual(blocks[2].text, "\n后总结")
    }

    func testAntmlInvokeWithParameters() {
        let cp = "</" + "parameter>"
        let s = "<antml:invoke name=\"web.search\">\n<parameter name=\"queries">白银价格" + cp + "\n" + "</antml:invoke>"
        let blocks = ContentBlocks.split(s)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .tool)
        XCTAssertEqual(blocks[0].toolName, "web.search")
        XCTAssertTrue(blocks[0].toolArgs?.contains("queries") ?? false)
    }

    func testToolTitleExtracted() {
        let cp = "</" + "parameter>"
        let s = "<invoke name=\"shell.exec\">\n<parameter name=\"tool_title">测试网络连通性" + cp + "\n<parameter name=\"command">curl -s hq.sinajs.cn" + cp + "\n" + "</invoke>"
        let blocks = ContentBlocks.split(s)
        XCTAssertEqual(blocks[0].toolTitle, "tool_title">测试网络连通性")
    }

    func testMixedOrderPreserved() {
        let cp = "</" + "parameter>"
        let s = "前文\n<|DSML| invoke name=\"device.info\">{\"type\":\"sys\"}\n</|DSML|>\n中段\n<invoke name=\"web.fetch\">\n<parameter name=\"url">https://a.b" + cp + "\n" + "</invoke>\n尾段"
        let blocks = ContentBlocks.split(s)
        XCTAssertEqual(blocks.count, 5)
        XCTAssertEqual(blocks[0].text, "前文\n")
        XCTAssertEqual(blocks[1].toolName, "device.info")
        XCTAssertEqual(blocks[2].text, "\n中段\n")
        XCTAssertEqual(blocks[3].toolName, "web.fetch")
        XCTAssertEqual(blocks[4].text, "\n尾段")
    }

    func testUnclosedTagFallsBackToText() {
        let s = "前文\n<|DSML| invoke name=\"shell.exec\">{\"command\":\"ls\"}"
        let blocks = ContentBlocks.split(s)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .text)
    }
}
