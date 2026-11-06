import Foundation

/// QQ 音乐 QRC 回包的 **XML 外壳**：`<Lyric_1 LyricType="1" LyricContent="…"/>`。
///
/// ── 为什么单列一份
/// 正文里会出现**裸引号**（`Xだけの"人マニア"` —— 那一条正文里有 16 个），
/// 而原来的取法是 `LyricContent="([^"]*)"`：正则遇到第一个裸引号就收尾，
/// 于是那一行之后的**所有行**都消失。`人マニア` 的 QRC 有 36 行，只解析出 20 行，
/// 连带罗马字（同一份外壳、同样被截断）与译文一起缺 —— 表现就是"歌词/翻译/罗马字缺失"
/// 就是这一条，不是服务端少给了。
///
/// ── 判据
/// 属性值从 `LyricContent="` 之后一直取到**最后那个** `"`：它后面只剩 `/>`（或 `>`）
/// 与几个闭合标签（`</LyricInfo>` / `</QrcInfos>`）。取到的尾部如果连这些都不像，
/// 说明这不是我们认识的外壳（没有外壳、或者正文恰好以引号结尾且没有收尾标记）⇒ 原样返回，不猜。
///
/// ⚠️ 不要退回"取第一个 `"`"：正文以引号结尾（`…"人マニア"`）时，第一个 `"` 在正文中间，
/// 那不是收尾。反过来"取最后一个 `"`"也只在**外壳存在**时成立 —— 所以 `/>` 那道闸必须在。
enum QrcPayloadWrapper {

    private static let contentMarker = "LyricContent=\""

    /// 剥掉外壳，返回正文（`&quot;` 之类的实体已还原）。
    static func body(from payload: String) -> String {
        guard let marker = payload.range(of: contentMarker) else { return payload }

        let tail = payload[marker.upperBound...]
        guard let closing = tail.range(of: "\"", options: .backwards) else {
            return String(tail)
        }

        let remainder = String(tail[closing.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 收尾只可能是这几种：`/>`、`>`（自闭合写成 `>…</Lyric_1>` 的变体）、或什么都没有。
        let closesAttribute = remainder.isEmpty
            || remainder.hasPrefix("/>")
            || remainder.hasPrefix(">")
        guard closesAttribute else {
            // 形状不认识：宁可把整段当正文，也不要凭一个引号把后半截切掉。
            return String(tail)
        }

        // 属性值与 `"/>` 之间通常隔着空行（QQ 回包就是 `…正文…\n\n"/>`）。
        // 那段空白不属于正文：留着会让正文多出两个尾部换行，按换行切分时多出空段，
        // 也让"正文以引号结尾"变得看不出来。只裁尾，不裁头 —— 正文第一行是 `[ti:…]`。
        var body = String(tail[..<closing.lowerBound])
        while let last = body.last, last.isWhitespace {
            body.removeLast()
        }
        return unescapeXML(body)
    }

    /// 属性值里的 `&quot;` 之类要还原 —— 正文裹在 XML 属性里时，`"` **本该**写成实体。
    ///
    /// QQ 两种都下发过：`人マニア` 是裸引号（所以 `body` 那一步必须容得下），
    /// 别的条目是 `&quot;`。两条路都要对。
    /// `&amp;` 放最后：先还原它会把 `&amp;lt;` 变成 `&lt;` 再被下一轮吃掉。
    static func unescapeXML(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
