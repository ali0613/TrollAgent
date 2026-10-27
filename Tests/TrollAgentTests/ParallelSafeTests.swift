import XCTest
@testable import TrollAgent

/// v7.2.3-fix9：并行安全判定回归基线（audit3 + 合批规则）
/// 覆盖 isParallelSafeTool 白名单 / shell 只读 / 写风险 / 复合符。
final class ParallelSafeTests: XCTestCase {

    private func call(_ name: String, _ args: String) -> ToolCall {
        ToolCall(id: "t1", name: name, arguments: args)
    }

    // MARK: - 白名单工具

    func testWhiteListWebSearchBatchable() {
        XCTAssertTrue(ConversationStore.isParallelSafeTool([
            call("web_search", #"{"query":"a"}"#),
            call("web_search", #"{"query":"b"}"#)
        ]))
    }

    func testSystemOverviewBatchable() {
        XCTAssertTrue(ConversationStore.isParallelSafeTool(call("system_overview", "{}")))
    }

    func testShellReadOnlyBatchable() {
        XCTAssertTrue(ConversationStore.isParallelSafeTool([
            call("shell_exec", #"{"command":"ls -la"}"#),
            call("shell_exec", #"{"command":"cat /etc/hosts"}"#)
        ]))
    }

    // MARK: - sed 无 -i 放开（audit3）

    func testSedReadOnlyBatchable() {
        XCTAssertTrue(ConversationStore.isParallelSafeTool(
            call("shell_exec", #"{"command":"sed -n '1,400p' file.txt"}"#)
        ))
    }

    func testSedWithInplaceNotBatchable() {
        XCTAssertFalse(ConversationStore.isParallelSafeTool(
            call("shell_exec", #"{"command":"sed -i 's/a/b/' file.txt"}"#)
        ))
    }

    // MARK: - 写风险

    func testRmNotBatchable() {
        XCTAssertFalse(ConversationStore.isParallelSafeTool(
            call("shell_exec", #"{"command":"rm -rf /tmp/x"}"#)
        ))
    }

    func testCurlWriteFileNotBatchable() {
        // curl 写文件（-o）有副作用 → 不并行
        XCTAssertFalse(ConversationStore.isParallelSafeTool(
            call("shell_exec", #"{"command":"curl -o /tmp/x https://a.b"}"#)
        ))
    }

    func testCurlReadOnlyBatchable() {
        XCTAssertTrue(ConversationStore.isParallelSafeTool(
            call("shell_exec", #"{"command":"curl -s https://api.github.com"}"#)
        ))
    }

    // MARK: - 复合符

    func testCompoundOperatorsNotBatchable() {
        XCTAssertFalse(ConversationStore.isParallelSafeTool(
            call("shell_exec", #"{"command":"ls && cat /etc/hosts"}"#)
        ))
        XCTAssertFalse(ConversationStore.isParallelSafeTool(
            call("shell_exec", #"{"command":"grep x file.txt; echo done"}"#)
        ))
        XCTAssertFalse(ConversationStore.isParallelSafeTool(
            call("shell_exec", #"{"command":"cat a | grep b"}"#)
        ))
    }

    // MARK: - 写类工具

    func testWriteToolsNotBatchable() {
        XCTAssertFalse(ConversationStore.isParallelSafeTool(call("inject", "{}")))
        XCTAssertFalse(ConversationStore.isParallelSafeTool(call("app", #"{"action":"open"}"#)))
    }

    func testEmptyCallsNotBatchable() {
        XCTAssertFalse(ConversationStore.isParallelSafeTool([]))
    }
}
