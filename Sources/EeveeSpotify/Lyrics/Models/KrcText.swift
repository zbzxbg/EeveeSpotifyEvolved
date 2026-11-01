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
        rows(from: krc).map(\.line)
    }

    /// 与 `lines(from:)` 同一次解析，但带**时间行下标**。
    ///
    /// 为什么要行号：KRC 的 `[language:…]` 里那份罗马字是**按时间行下标**排的
    /// （没有词、被跳过的行照样占位），要和正文行一一对上只能靠这个下标 —
    /// 拿 `lines` 的下标去取，只要中间跳过一行，后面整体串行。
    private static func rows(from krc: String) -> [(index: Int, line: LyricsLineDto)] {
        guard let headerRegex, let pieceRegex else { return [] }

        var out: [(index: Int, line: LyricsLineDto)] = []
        var rowIndex = -1

        for row in krc.components(separatedBy: .newlines) {
            let ns = row as NSString
            let full = NSRange(location: 0, length: ns.length)
            guard let header = headerRegex.firstMatch(in: row, range: full),
                  header.numberOfRanges >= 3,
                  let lineStart = Int(ns.substring(with: header.range(at: 1))) else { continue }

            // 只要这一行是 `[start,dur]` 开头就占一个下标（哪怕后面解析不出词）。
            rowIndex += 1

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

            out.append((rowIndex, LyricsLineDto(content: content, offsetMs: lineStart, words: words)))
        }

        return out
    }

    // MARK: - 官方罗马字（`[language:…]`）
    //
    // 酷狗把**逐词罗马字**与译文塞在 KRC 的 `[language:<base64>]` 那一行里：
    // 解出来是 `{"version":1,"content":[{"type":0,"lyricContent":[[词,词…],…]},{"type":1,…}]}`
    // —— `type == 0` 是罗马字、`type == 1` 是译文，两者都是"每个时间行一组词"。
    // 下标与时间行严格一一对应（实测《夜に駆ける》69 个时间行 ↔ 69 组）。
    //
    // 这里取 `type == 0`（罗马字）与 `type == 1`（译文）两条，按同一个行下标贴回去。
    private static func romanizedRows(from krc: String) -> [[String]]? {
        languageRows(from: krc, type: 0)
    }

    /// `[language:<base64>]` 里指定 `type` 那一组（0 = 罗马字，1 = 译文）。
    private static func languageRows(from krc: String, type: Int) -> [[String]]? {
        for row in krc.components(separatedBy: .newlines) {
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[language:"), trimmed.hasSuffix("]") else { continue }

            let payload = String(trimmed.dropFirst("[language:".count).dropLast())
            guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = root["content"] as? [[String: Any]] else { return nil }

            for entry in entries where (entry["type"] as? Int) == type {
                return entry["lyricContent"] as? [[String]]
            }
            return nil
        }
        return nil
    }

    /// 把那份逐词罗马字按**同一个行下标**贴到保留下来的行上。
    ///
    /// 长度对不上（上游多一组/少一组）就整份丢掉：显示层是按行下标配对的，
    /// 长度不等它也会整份忽略 —— 先判掉能省一次空转，也避免错行。
    private static func romanizedLines(
        from krc: String,
        rows: [(index: Int, line: LyricsLineDto)]
    ) -> [String]? {
        guard let source = romanizedRows(from: krc), !source.isEmpty else { return nil }

        var out: [String] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            guard row.index < source.count else { return nil }
            out.append(source[row.index].joined().trimmingCharacters(in: .whitespaces))
        }

        // 整份都是空串 ⇒ 当没有罗马字（否则显示层会画一行空白）。
        guard out.contains(where: { !$0.isEmpty }) else { return nil }

        // 韩文歌的 `type 0` **不是罗马字，是中文谐音**（"马列做 say it back" 那种）。
        // 判据用汉字占比：真罗马字几乎不含汉字，谐音轨则一大半是。
        // 不挡的话，只要「日语罗马化」那个开关是开的（显示层对日语是先看它、
        // 不看曲目语言），韩文歌就会顶着罗马字那一行显示中文谐音。
        guard hanRatio(out.joined()) <= 0.3 else { return nil }

        return out
    }

    /// 逐词罗马字：与 `romanizedLines` 读的是同一份 `[language:]` type 0，
    /// 但**保留词边界**，让渲染层能把罗马字那一行也做成逐字填充。
    ///
    /// KRC 的罗马字组和词片是同一套切分（`<…>词` 有几段，`type 0` 就有几组），
    /// 所以只在"组数 == 那一行的词数"时才敢挂；对不上就留空数组，
    /// 由显示层退回整行罗马字。
    private static func romanizedWordGroups(
        from krc: String,
        rows: [(index: Int, line: LyricsLineDto)]
    ) -> [[String]]? {
        guard let source = romanizedRows(from: krc), !source.isEmpty else { return nil }

        var out: [[String]] = []
        out.reserveCapacity(rows.count)
        var matchedAny = false
        for row in rows {
            guard row.index < source.count else { return nil }
            let groups = source[row.index]
            if let words = row.line.words, !words.isEmpty, groups.count == words.count {
                out.append(groups)
                matchedAny = true
            } else {
                out.append([])
            }
        }
        guard matchedAny else { return nil }

        // 与 `romanizedLines` 同一道闸：韩文歌的 type 0 是中文谐音，不是罗马字。
        guard hanRatio(out.flatMap { $0 }.joined()) <= 0.3 else { return nil }

        return out
    }

    /// 一段文本里汉字占"非空白字符"的比例。
    private static func hanRatio(_ text: String) -> Double {
        var total = 0
        var han = 0
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            total += 1
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
                han += 1
            default:
                break
            }
        }
        guard total > 0 else { return 0 }
        return Double(han) / Double(total)
    }

    /// 解包 + 解析，一步到位。拿不到可用行 ⇒ nil。
    static func dto(fromBase64 base64: String) -> LyricsDto? {
        guard let text = decode(base64) else { return nil }
        return dto(from: text)
    }

    /// 两类非歌词行在这里剔掉：
    /// · 制作信息（`词：X`）—— 不是歌词；
    /// · 开头那条「歌名 - 歌手」页眉行（判据见 `LyricsCreditLine.isTitleArtistHeader`）。
    /// 过滤放在 dto 这一层而不是 `lines(from:)` 里，罗马字/译文才能按**时间行下标**继续对齐。
    ///
    /// 署名只用文件头的 `[by:]`（众包贡献者），不再从正文的「词：」里取作词者 ——
    /// 那是曲目元信息，不是"这份歌词是谁贡献的"。
    static func dto(from krc: String) -> LyricsDto? {
        let tags = LyricsCreditLine.headerTags(in: krc)
        let all = rows(from: krc)
        let kept = all.filter {
            !LyricsCreditLine.isCreditLine($0.line.content)
                && !LyricsCreditLine.isTitleArtistHeader(
                    $0.line.content, title: tags.title, artist: tags.artist
                )
        }
        guard !kept.isEmpty else { return nil }

        let lines = kept.map(\.line)
        let contents = lines.map(\.content)
        var dto = LyricsDto(
            lines: lines,
            timeSynced: true,
            romanization: contents.canBeRomanized ? .canBeRomanized : .original
        )
        if let by = tags.by {
            dto.providerContributors = [LyricsContributor(role: .uploader, name: by, url: nil)]
        }
        // 语言写进 dto：显示层按它挑"该看哪个罗马化开关"（ja/zh/ko 三个键）。
        if let languageCode = contents.romanizationLanguageCode, !languageCode.isEmpty {
            dto.languageCode = languageCode
        }
        if let romanized = romanizedLines(from: krc, rows: kept) {
            dto.officialRomanizedLines = romanized
            if let groups = romanizedWordGroups(from: krc, rows: kept) {
                dto.officialRomanizedWordGroups = groups
            }
        }
        if let translated = translatedLines(from: krc, rows: kept) {
            dto.translation = LyricsTranslationDto(languageCode: "zh", lines: translated)
        }
        return dto
    }

    // MARK: - 官方译文（`[language:…]` 的 `type == 1`）
    //
    // 与罗马字同一个容器、同一套下标：`type 0` 是罗马字、`type 1` 是译文（实测《夜に駆ける》
    // 69 行 ↔ 69 组；译文前几组常是空串或「以下歌词翻译由…提供」那种声明行）。
    // 译文与 `lines` 必须**同序同长**（显示层按下标配对，见 `LyricsDto.droppingBlankLinesForDisplay`）。
    private static func translatedLines(
        from krc: String,
        rows: [(index: Int, line: LyricsLineDto)]
    ) -> [String]? {
        guard let source = languageRows(from: krc, type: 1), !source.isEmpty else { return nil }

        var out: [String] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            guard row.index < source.count else { return nil }
            let text = source[row.index].joined().trimmingCharacters(in: .whitespaces)
            let original = row.line.content.trimmingCharacters(in: .whitespaces)
            // 声明行、占位行、以及"译文和原文一模一样"（中文歌常见）都不算译文。
            out.append(isTranslationNotice(text) || text == original ? "" : text)
        }
        guard out.contains(where: { !$0.isEmpty }) else { return nil }
        return out
    }

    /// `[language:]` 里那几条声明行（不是歌词）。**窄判据**：只有在整行都像声明时才丢。
    private static func isTranslationNotice(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        if text == "//" { return true }
        for marker in ["以下歌词", "翻译由", "本翻译作品", "TME享有", "QQ音乐"] {
            if text.contains(marker) { return true }
        }
        return false
    }
}
