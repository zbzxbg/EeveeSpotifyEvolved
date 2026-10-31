import Foundation

/// 酷狗 KRC 的解包与解析。
///
/// ── 它是什么
/// 酷狗下发的 `content` 是 base64，解开之后是：
///
/// "krc1"（4 字节魔数） + zlib( KRC 文本 XOR 16 字节密钥 )
///
/// 那个 16 字节密钥是酷狗**所有客户端都内置**的一串常量，不是按用户/按曲目变的 ——
/// 所以这里写死一份。XOR 作用在 **zlib 流整体**上（含 2 字节头），所以顺序必须是
/// 先 XOR 再解压，反过来一定失败。
///
/// ── KRC 文本长什么样
/// [行首ms,行时长ms]<字偏移ms,字时长ms,标志>字<…>字…
///
/// 与网易云的 yrc 只差一对括号（yrc 用圆括号）与**时间基准**：
/// yrc 的字偏移是**整首绝对时间**，KRC 的是**相对本行行首**。
/// 这一点搞反的表现是"第一行准、后面越来越离谱"。
///
/// ── 解压
/// 解压那一步走 `ZlibInflate`（与 QQ 音乐的 QRC 共用同一份）。那里面写着为什么
/// 不能直接用 Apple 的 `COMPRESSION_ZLIB`（它吃裸 DEFLATE，而这两家给的是带头的 zlib 流）。
enum KrcText {

    /// 酷狗客户端里写死的那 16 字节。
    private static let xorKey: [UInt8] = [
        64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105
    ]

    private static let magic: [UInt8] = Array("krc1".utf8)

    /// 歌词只有几 KB。解包超过这个数的一律当坏数据（上限由 `ZlibInflate` 执行）。
    private static let maxBytes = ZlibInflate.defaultLimit

    private static let headerRegex = try? NSRegularExpression(pattern: "^\\[(\\d+),(\\d+)\\]")
    private static let pieceRegex = try? NSRegularExpression(pattern: "<(-?\\d+),(-?\\d+),-?\\d+>")

    // MARK: - 解包
    //
    // base64 → KRC 文本。任何一步不对都返回 nil（调用方据此换下一条候选）。
    static func decode(_ base64: String) -> String? {
        guard let packed = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return decode(packed)
    }

    static func decode(_ packed: Data) -> String? {
        guard packed.count > magic.count + 6, packed.count <= maxBytes else { return nil }
        guard Array(packed.prefix(magic.count)) == magic else { return nil }

        var zipped = Array(packed.dropFirst(magic.count))
        for index in zipped.indices {
            zipped[index] ^= xorKey[index % xorKey.count]
        }

        guard let plain = ZlibInflate.inflate(zipped) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    // MARK: - 解析
    //
    // KRC 文本 → 带词级时间轴的行。
    //
    // 词文本取"这一段的 `<…>` 到下一段的 `<…>` 之间"的**原样字符串**，不做 trim/合并：
    // 渲染层要求 `content` 严格等于各词 `text` 顺序拼接（见 `AmllLyricsMapper` 文件头的
    // 硬不变量），原样切分能**构造上**满足它；一 trim 就得自己补空格，迟早补错。
    static func lines(from krc: String) -> [LyricsLineDto] {
        guard let headerRegex, let pieceRegex else { return [] }

        var out: [LyricsLineDto] = []

        for row in krc.components(separatedBy: .newlines) {
            let ns = row as NSString
            let full = NSRange(location: 0, length: ns.length)
            guard let header = headerRegex.firstMatch(in: row, range: full),
                  header.numberOfRanges >= 3,
                  let lineStart = Int(ns.substring(with: header.range(at: 1))) else { continue }

            let contentRange = NSRange(
                location: NSMaxRange(header.range),
                length: ns.length - NSMaxRange(header.range)
            )
            let pieces = pieceRegex.matches(in: row, range: contentRange)
            guard !pieces.isEmpty else { continue }

            var words: [LyricsWordDto] = []
            for (index, piece) in pieces.enumerated() {
                guard piece.numberOfRanges >= 3 else { continue }
                let from = NSMaxRange(piece.range)
                let to = index + 1 < pieces.count ? pieces[index + 1].range.location : ns.length
                guard to > from else { continue }

                let text = ns.substring(with: NSRange(location: from, length: to - from))
                guard !text.isEmpty else { continue }

                // KRC 的字偏移相对**本行行首**（yrc 是绝对时间，两者差这一项）。
                let start = (Int(ns.substring(with: piece.range(at: 1))) ?? 0) + lineStart
                let duration = max(Int(ns.substring(with: piece.range(at: 2))) ?? 0, 1)
                words.append(LyricsWordDto(text: text, startMs: start, endMs: start + duration))
            }

            guard !words.isEmpty else { continue }
            let content = words.map(\.text).joined()
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            out.append(LyricsLineDto(content: content, offsetMs: lineStart, words: words))
        }

        return out
    }

    /// 解包 + 解析，一步到位。拿不到可用行 ⇒ nil。
    static func dto(fromBase64 base64: String) -> LyricsDto? {
        guard let text = decode(base64) else { return nil }
        return dto(from: text)
    }

    static func dto(from krc: String) -> LyricsDto? {
        let parsed = lines(from: krc)
        guard !parsed.isEmpty else { return nil }
        let contents = parsed.map(\.content)
        return LyricsDto(
            lines: parsed,
            timeSynced: true,
            romanization: contents.canBeRomanized ? .canBeRomanized : .original
        )
    }
}
