import Foundation

/// `QrcPayloadWrapper` 的断言程序（纯 Foundation，CI 跑；见 `.github/workflows/tests.yml`）。
///
/// 为什么必须钉这一份：QQ 的 QRC 正文裹在 `<Lyric_1 … LyricContent="…"/>` 这个**属性**里，
/// 而正文里会出现**裸引号**（`Xだけの"人マニア"`，实测 `人マニア` 有 16 个）。
/// 旧的取法是正则 `LyricContent="([^"]*)"` —— 它在第一个裸引号处收尾，把后半首歌整个切掉：
/// 36 行只解析出 20 行，连带罗马字（同一份外壳、同样被截断）与译文一起缺。
/// 本机（Windows）没有 Swift 工具链，这个测试只有 CI 会跑，所以样本必须是**真实形状**。

var failures = 0

func require(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)")
    }
}

/// 真实回包的**尾部**形状（`人マニア` 实测：正文与 `"/>` 之间有空行）。
let tail = "\n\n\"/>\n\n</LyricInfo>\n\n</QrcInfos>"
let head = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n\n<QrcInfos>\n\n"
    + "<QrcHeadInfo SaveTime=\"127\" Version=\"100\"/>\n\n<LyricInfo LyricCount=\"1\">\n\n"
    + "<Lyric_1 LyricType=\"1\" LyricContent=\""

// MARK: - 裸引号：正文里那一行不能被当收尾

let withQuote = head
    + "[ti:t]\n[0,100]a(0,100)\n[200,100]Xだけの\"人マニア\"(200,100)\n[400,100]b(400,100)"
    + tail

let quoteBody = QrcPayloadWrapper.body(from: withQuote)
require(quoteBody.contains("[400,100]b(400,100)"),
        "a bare quote inside the attribute does not truncate the body")
require(quoteBody.contains("Xだけの\"人マニア\""),
        "the bare quotes themselves survive verbatim")
require(!quoteBody.contains("</LyricInfo>"), "the closing tags are not part of the body")
require(quoteBody.hasPrefix("[ti:t]"), "the body starts at the attribute value")

// 行数也要对得上 —— 这正是用户看到"歌词少了一半"的那一层。
let rows = quoteBody.components(separatedBy: "\n").filter { $0.hasPrefix("[0") || $0.hasPrefix("[2") || $0.hasPrefix("[4") }
require(rows.count == 3, "every timed row survives (\(rows.count) of 3)")

// MARK: - 正文本身以引号结尾（`…の"` + `"/>`）

let endsWithQuote = head + "[0,100]a(0,100)\"" + tail
require(QrcPayloadWrapper.body(from: endsWithQuote) == "[0,100]a(0,100)\"",
        "a body that ends with a quote keeps that quote")

// MARK: - 实体写法：`&quot;` 要还原

let entityBody = head + "[0,100]a&quot;b(0,100)" + "\"/>"
require(QrcPayloadWrapper.body(from: entityBody) == "[0,100]a\"b(0,100)",
        "&quot; in the attribute is unescaped")

// MARK: - 没有外壳：原样返回

let bare = "[ti:t]\n[0,100]a(0,100)\n"
require(QrcPayloadWrapper.body(from: bare) == bare, "a payload without the wrapper is returned as-is")

// MARK: - 有外壳、正文里没有引号

let plain = head + "[0,100]a(0,100)" + "\"/>"
require(QrcPayloadWrapper.body(from: plain) == "[0,100]a(0,100)",
        "a wrapper without quotes in the body is unwrapped")

// 收尾写成 `>` + 闭合标签（另一种自闭合变体）同样要剥干净。
let closingTag = "<Lyric_1 LyricContent=\"[0,100]a(0,100)\"></Lyric_1>"
require(QrcPayloadWrapper.body(from: closingTag) == "[0,100]a(0,100)",
        "a wrapper closed with `>` + a closing tag is unwrapped too")

// MARK: - 形状不认识：宁可整段当正文，也不按引号切

// 收尾不是 `/>`（这里故意换成 `</Lyric_1>`）：切一刀就会少字，所以整段返回。
let unknown = "<Lyric_1 LyricContent=\"abc\" def</Lyric_1>"
require(QrcPayloadWrapper.body(from: unknown) == "abc\" def</Lyric_1>",
        "an unknown closing shape is not cut at a quote")

// 只有开始引号、没有收尾：整段返回，不猜。
let unterminated = "<Lyric_1 LyricContent=\"abc"
require(QrcPayloadWrapper.body(from: unterminated) == "abc",
        "an unterminated attribute returns the remainder")

// MARK: - 结果

if failures == 0 {
    print("QrcPayloadWrapper: all assertions passed")
} else {
    print("QrcPayloadWrapper: \(failures) assertion(s) FAILED")
    exit(1)
}
