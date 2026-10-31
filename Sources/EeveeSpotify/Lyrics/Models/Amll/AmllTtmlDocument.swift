import Foundation

// MARK: - 极简 TTML DOM
//
// TTML 是空格敏感的 XML，且用到了 ttm: / itunes: / amll: / tts: 多个命名空间前缀。
// 这里用 Foundation 的 XMLParser 建一棵最简节点树，保留「文本节点与子元素的有序交错」——
// 这一点是必须的：`<span>You</span> <span>said</span>` 中间那个空格是真实文本节点，
// 承载着英文词间空格，丢掉它会把整行拼成 "Yousaid"。
//
// 命名空间处理策略（与 AMLL 官方解析库 MeloX 的实现一致）：
// shouldProcessNamespaces = false → elementName / attributeDict 里保留原始前缀（"ttm:role"）
// shouldReportNamespacePrefixes = true → qName 可用
// 然后一律按 localName（冒号后半段）匹配，这样 `ttm:role`、`itunes:key`、`xml:lang`
// 都能用不带前缀的名字取到，不用关心投稿者写的是哪个前缀。

final class AmllTtmlNode {
    enum Content {
        case text(String)
        case child(AmllTtmlNode)
    }

    let name: String
    let attributes: [String: String]
    var contents: [Content] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// 去掉命名空间前缀的标签名。`ttm:agent` → `agent`。
    var localName: String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    var children: [AmllTtmlNode] {
        contents.compactMap {
            guard case .child(let node) = $0 else { return nil }
            return node
        }
    }

    /// 按 localName 取属性值。`attribute("role")` 能命中 `ttm:role`。
    func attribute(_ names: String...) -> String? {
        for requested in names {
            if let value = attributes[requested] { return value }
            if let match = attributes.first(where: {
                $0.key.split(separator: ":").last.map(String.init) == requested
            }) {
                return match.value
            }
        }
        return nil
    }

    /// 是否带指定 role（`ttm:role="x-translation"` 等）。
    func hasRole(_ role: String) -> Bool {
        attributes.contains {
            $0.key.split(separator: ":").last == "role" && $0.value == role
        }
    }

    /// 深度优先收集满足条件的子孙节点（含自身）。
    func descendants(where predicate: (AmllTtmlNode) -> Bool) -> [AmllTtmlNode] {
        var result: [AmllTtmlNode] = []
        if predicate(self) { result.append(self) }
        for child in children {
            result.append(contentsOf: child.descendants(where: predicate))
        }
        return result
    }

    /// 只承载**注音**（不是歌词）的标签。
    ///
    /// TTML 的 ruby 注音写成 `<ruby>漢<rt>かん</rt></ruby>`：`<rt>` 里是读音，`<rp>` 是
    /// 给不支持 ruby 的渲染器看的括号。两者都不属于歌词正文。
    static let rubyAnnotationNames: Set<String> = ["rt", "rp"]

    /// 只承载注音的 **`tts:ruby` 取值**（`text` = 注音文本本身，`textContainer` = 它的容器）。
    ///
    /// **AMLL 真正的 ruby 写法不是 `<ruby>/<rt>`，而是 `tts:ruby` 属性**
    /// （官方文档 <https://amll.dev/guides/lyric/ttml> 的「Ruby 注音」一节）：
    /// ```
    /// <span tts:ruby="container">
    ///   <span tts:ruby="base">所</span>
    ///   <span tts:ruby="textContainer">
    ///     <span tts:ruby="text" begin="00:27.690" end="00:27.820">しょ</span>
    ///   </span>
    /// </span>
    /// ```
    /// 不跳这两档，`text` 会拼成 `所しょ詮せん`（正文混进读音）；更糟的是**时间只挂在
    /// `tts:ruby="text"` 上**，所以 `parseTimedSpans` 会把"注音"当成歌词词条、把 base 丢掉
    /// ⇒ 屏幕上整行变成一片假名读音（见 `AmllTtmlParser.rubySyllable(in:)`）。
    static let rubyAnnotationStyles: Set<String> = ["text", "textContainer"]

    /// 这个节点的 `tts:ruby` 取值（没有就是 nil）。`attribute("ruby")` 按 localName 取，前缀无关。
    var rubyStyle: String? { attribute("ruby") }

    /// 递归拼接全部文本；`excludingRoles` 里的 role 子树整棵跳过。
    ///
    /// `<rt>` / `<rp>` 与 `tts:ruby="text"/"textContainer"` 一并跳过
    /// （`rubyAnnotationNames` / `rubyAnnotationStyles`）。
    /// 不跳它们，正文会被拼成 `漢かん`（或 `所しょ`）—— 真机上就是那一行多出读音；
    /// 逐词 span 里的读音也会一起进词条（高亮的字范围跟着偏）。
    ///
    /// ⚠️ 更正复核）：`Lyrics-Audit` 那份笔记里还写着"随后 mapper 的对齐
    /// 不变量会把那一行的逐词丢掉" —— **不成立**。`AmllLyricsMapper.wordTokens` 拿
    /// `line.primaryText` 当期望值，而 `primaryText` 本身就是 `syllables` 的拼接
    /// （`syllables.isEmpty ? plainText : joined`）⇒ 两者恒等，那条 guard 在 AMLL 这条路上
    /// 根本不会触发。所以 ruby 的后果只是**正文多出读音**，不是"降级为逐行"。
    /// 测试：`Tests/AmllTtmlRuby`（CI）。
    func text(excludingRoles excludedRoles: Set<String> = []) -> String {
        if excludedRoles.contains(where: hasRole) { return "" }
        if AmllTtmlNode.rubyAnnotationNames.contains(localName) { return "" }
        if let rubyStyle, AmllTtmlNode.rubyAnnotationStyles.contains(rubyStyle) { return "" }
        return contents.map { content in
            switch content {
            case .text(let text): return text
            case .child(let child): return child.text(excludingRoles: excludedRoles)
            }
        }.joined()
    }
}

enum AmllTtmlDocument {
    /// 解析 TTML 字符串；失败返回 nil。
    static func parse(_ source: String) -> AmllTtmlNode? {
        guard let data = source.data(using: .utf8) else { return nil }
        let builder = AmllTtmlDocumentBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = true
        guard parser.parse() else { return nil }
        return builder.root
    }
}

private final class AmllTtmlDocumentBuilder: NSObject, XMLParserDelegate {
    private(set) var root: AmllTtmlNode?
    private var stack: [AmllTtmlNode] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = AmllTtmlNode(name: qName ?? elementName, attributes: attributeDict)
        if let parent = stack.last {
            parent.contents.append(.child(node))
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let node = stack.last else { return }
        // 与相邻文本节点合并：XMLParser 对同一段文本可能分多次回调。
        if case .text(let existing)? = node.contents.last {
            node.contents[node.contents.count - 1] = .text(existing + string)
        } else {
            node.contents.append(.text(string))
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        _ = stack.popLast()
    }
}
