import XCTest
@testable import TrollAgent

/// v7.2.3-fix19：tool_title 提取与 schema 注入回归基线（对齐 OpenMinis）
final class ToolTitleTests: XCTestCase {

    func testExtractTitleFromArguments() {
        let args = "{\"command\":\"curl -s hq.sinajs.cn\",\"tool_title\":\"测试网络连通性\"}"
        XCTAssertEqual(ToolCall.extractTitle(from: args), "测试网络连通性")
    }

    func testExtractTitleMissingReturnsNil() {
        let args = "{\"command\":\"ls -la\"}"
        XCTAssertNil(ToolCall.extractTitle(from: args))
    }

    func testExtractTitleEmptyReturnsNil() {
        let args = "{\"command\":\"ls\",\"tool_title\":\"   \"}"
        XCTAssertNil(ToolCall.extractTitle(from: args))
    }

    func testExtractTitleInvalidJSONReturnsNil() {
        XCTAssertNil(ToolCall.extractTitle(from: "not-json"))
        XCTAssertNil(ToolCall.extractTitle(from: ""))
    }

    func testToolCallDecodeWithoutToolTitle() throws {
        // 旧消息（fix19 前）无 toolTitle 字段 → decode 为 nil，UI fallback 工具名
        let json = "{\"id\":\"t1\",\"name\":\"shell.exec\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}"
        let call = try JSONDecoder().decode(ToolCall.self, from: Data(json.utf8))
        XCTAssertNil(call.toolTitle)
        XCTAssertEqual(call.name, "shell.exec")
    }

    func testToolCallDecodeWithToolTitle() throws {
        let json = "{\"id\":\"t2\",\"name\":\"web.search\",\"arguments\":\"{}\",\"toolTitle\":\"搜索白银价格\"}"
        let call = try JSONDecoder().decode(ToolCall.self, from: Data(json.utf8))
        XCTAssertEqual(call.toolTitle, "搜索白银价格")
    }

    func testSchemaInjectToolTitle() {
        // 每个启用工具的 OpenAI function schema 必须含 tool_title 属性
        // 测试进程无 App 启动注册，先显式注册内置工具
        ToolRegistry.shared.registerBuiltinTools()
        let schemas = ToolRegistry.shared.enabledOpenAIToolSchema()
        XCTAssertFalse(schemas.isEmpty)
        for schema in schemas {
            let fn = schema["function"] as? [String: Any] ?? [:]
            let params = fn["parameters"] as? [String: Any] ?? [:]
            let props = params["properties"] as? [String: Any] ?? [:]
            XCTAssertNotNil(props["tool_title"], "工具 \(fn["name"] ?? "?") 缺 tool_title schema")
        }
    }
}
