import Foundation
import JavaScriptCore

struct ModuleRunResult {
    var success: Bool
    var output: String
    var logs: [String]
}

/// JavaScriptCore 模块运行器（一期骨架）：
/// 加载 JS 文本 → 注入 lvguo 桥（log / httpGet 占位）→ 调约定入口 main() → 拿回 JSON 结果。
/// 二期在此之上补：真实网络层（httpGet 异步化）、模块安装/存储、PlaybackPlan 解析。
final class ModuleRunner {
    func run(source: String, entry: String = "main") -> ModuleRunResult {
        guard let context = JSContext() else {
            return ModuleRunResult(success: false, output: "JSContext 创建失败", logs: [])
        }
        var logs: [String] = []
        var failed = false
        context.exceptionHandler = { _, exception in
            failed = true
            logs.append("异常：\(exception?.toString() ?? "unknown")")
        }

        let logBlock: @convention(block) (String) -> Void = { message in
            logs.append(message)
        }
        context.setObject(logBlock, forKeyedSubscript: "__lvguo_log" as NSString)

        // 一期占位实现：返回固定示例 JSON，证明「模块 → 桥 → 原生 → JSON 回模块」链路通。
        // 只用公开示例数据，不涉及任何真实源站接口。
        let httpGetBlock: @convention(block) (String) -> String = { _ in
            #"{"title":"示例模块数据","items":[{"id":1},{"id":2},{"id":3}]}"#
        }
        context.setObject(httpGetBlock, forKeyedSubscript: "__lvguo_httpGet" as NSString)

        context.evaluateScript("""
        var lvguo = {
            log: function (m) { __lvguo_log(String(m)); },
            httpGet: function (u) { return __lvguo_httpGet(String(u)); }
        };
        """)
        context.evaluateScript(source)

        guard let entryFunction = context.objectForKeyedSubscript(entry),
              !entryFunction.isUndefined, !entryFunction.isNull else {
            return ModuleRunResult(success: false, output: "未找到入口函数 \(entry)()", logs: logs)
        }
        guard let value = entryFunction.call(withArguments: []) else {
            return ModuleRunResult(success: false, output: "入口调用失败", logs: logs)
        }
        let stringify = context.evaluateScript(
            "(function (v) { try { return JSON.stringify(v); } catch (e) { return String(v); } })"
        )
        let output = stringify?.call(withArguments: [value])?.toString() ?? "null"
        return ModuleRunResult(success: !failed, output: output, logs: logs)
    }

    /// 内置示例模块：验证链路用，只含公开示例数据
    static let sampleModule = """
    function main() {
        lvguo.log('示例模块启动');
        var raw = lvguo.httpGet('https://example.com/api/home');
        var data = JSON.parse(raw);
        lvguo.log('拿到条目 ' + data.items.length + ' 条');
        return { ok: true, title: data.title, count: data.items.length };
    }
    """
}
