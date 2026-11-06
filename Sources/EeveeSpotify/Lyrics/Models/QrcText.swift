import Foundation

/// QQ 音乐 QRC 的解密与解析 —— 逐字那一档。
///
/// ── 它是什么
/// `GetPlayLyricInfo` 带 `qrc: 1, crypt: 1` 时，`lyric` 字段给的是**加密的 QRC**，
/// 解出来长这样：
///
/// [ti:…]
/// [0,3520]我(0,352)的(352,352)心(704,352)
///
/// ── 解密（三步，缺一不可）
/// 1. **hex 解码**（云端返回的是十六进制字符串；也见过 base64 形态，两种都试）；
/// 2. **3DES 解密** —— ⚠️ 但**不是标准 3DES**：QQ 用的是自己的 DES 变体，
///    S 盒与 PC-2 各有一处偏差，见 `QrcDES` 文件头；
/// 3. **zlib 解压**（走 `ZlibInflate`，与酷狗 KRC 共用）。
///
/// ⚠️ 第 2 步是**踩过的坑**：这里原本用 CommonCrypto 的 `kCCAlgorithm3DES` 直接解，
/// 看着"密钥对、ECB、无填充"样样都对，可解出来的首块永远不是 `78 9c` —— 因为
/// QQ 加密时用的不是标准 DES。表现是**解密恒失败**：QRC 逐字档永远拿不到，
/// 一路退化成行级 LRC 或直接没有歌词。换成 `QrcDES` 之后能解开
/// （`晴天` / `夜に駆ける` 都可以）。
///
/// ── 与 yrc / KRC 的两处格式差异（都踩过）
/// · **时间戳写在文字后面**：`词(起始,时长)`，不是 `(起始,时长)词`；
/// · 字偏移一般是**整首绝对时间**（和 yrc 一样、和 KRC 相反）。
/// 但不同来源的样本里也见过相对行首的，所以这里**逐行探测**（见 `lines(from:)`）。
enum QrcText {

    /// DES 块长（8 字节）。密文长度必须是它的整数倍。
    private static let blockSize = 8

    private static let headerRegex = try? NSRegularExpression(pattern: "^\\[(\\d+),(\\d+)\\]")
    /// `(起始,时长)`。第三个字段（标志位）是 yrc 的写法，QRC 一般没有，
    /// 但见过混进来的样本，所以允许它存在 —— 有也不影响取值。
    private static let pieceRegex = try? NSRegularExpression(
        pattern: "\\((\\d+),(\\d+)(?:,-?\\d+)?\\)"
    )

    // MARK: - 解密
    //
    // 加密串 → QRC 正文。任何一步不对都返回 nil。
    static func decode(_ encrypted: String) -> String? {
        guard let cipher = cipherBytes(encrypted) else { return nil }
        guard let plain = QrcDES.decrypt(cipher) else { return nil }
        guard let inflated = ZlibInflate.inflate([UInt8](plain)) else { return nil }
        return String(data: strippingBOM(inflated), encoding: .utf8)
    }

    /// 解出来的明文可能带 UTF-8 BOM（`EF BB BF`）。不剥的话第一行是 `\u{FEFF}[ti:…]`，
    /// 后面所有 `^\\[` 开头的判据（标题头、时间行）都会对不上。
    private static func strippingBOM(_ data: Data) -> Data {
        guard data.count >= 3,
              data[data.startIndex] == 0xEF,
              data[data.startIndex + 1] == 0xBB,
              data[data.startIndex + 2] == 0xBF else { return data }
        return data.dropFirst(3)
    }

    /// 云端给的是 hex；备一份 base64 的尝试（代价只有几微秒，比"某个条目解不开"划算）。
    private static func cipherBytes(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let hex = hexDecoded(trimmed), hex.count % blockSize == 0 { return hex }
        if let base64 = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters),
           base64.count % blockSize == 0 { return base64 }
        return nil
    }

    private static func hexDecoded(_ text: String) -> Data? {
        guard text.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(text.count / 2)

        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    // MARK: - 解析

    static func dto(fromEncrypted encrypted: String) -> LyricsDto? {
        guard let text = decode(encrypted) else { return nil }
        return dto(from: text)
    }

    static func dto(from qrc: String) -> LyricsDto? {
        let tags = LyricsCreditLine.headerTags(in: qrc)
        let all = lines(from: qrc)
        let kept = all.filter {
            !LyricsCreditLine.isCreditLine($0.content)
                && !LyricsCreditLine.isTitleArtistHeader(
                    $0.content, title: tags.title, artist: tags.artist
                )
        }
        guard !kept.isEmpty else { return nil }
        let contents = kept.map(\.content)
        var dto = LyricsDto(
            lines: kept,
            timeSynced: true,
            romanization: contents.canBeRomanized ? .canBeRomanized : .original
        )
        // 署名只认文件头 `[by:]` 里的**众包贡献者**（QQ Music 把"歌词贡献者"写在这里），
        // 不再从正文的「词：」里取作词者。
        if let by = tags.by {
            dto.providerContributors = [LyricsContributor(role: .uploader, name: by, url: nil)]
        }
        return dto
    }

    /// QRC 正文 → 带词级时间轴的行。
    ///
    /// 词文本取"上一个 `(起始,时长)` 的右括号到这一个的左括号之间"的**原样字符串**，
    /// 不做 trim/合并 —— 渲染层要求 `content` 严格等于各词 `text` 顺序拼接
    /// （见 `AmllLyricsMapper` 文件头的硬不变量），原样切分能**构造上**满足它。
    static func lines(from qrc: String) -> [LyricsLineDto] {
        guard let headerRegex, let pieceRegex else { return [] }

        var out: [LyricsLineDto] = []

        for row in lyricBody(qrc).components(separatedBy: .newlines) {
            let row = row.trimmingCharacters(in: .whitespaces)
            guard !row.isEmpty else { continue }

            let ns = row as NSString
            guard let header = headerRegex.firstMatch(
                in: row, range: NSRange(location: 0, length: ns.length)
            ), header.numberOfRanges >= 3,
               let lineStart = Int(ns.substring(with: header.range(at: 1))) else { continue }

            let restStart = NSMaxRange(header.range)
            let restLength = ns.length - restStart
            // 只有 `[起始,时长]`、后面什么都没有 ⇒ 空行 / 间奏，按既有纪律整行丢掉。
            guard restLength > 0 else { continue }

            let pieces = pieceRegex.matches(
                in: row, range: NSRange(location: restStart, length: restLength)
            )
            guard !pieces.isEmpty else { continue }

            // 时间基准逐行探测：绝对时间的第一个字一定 **≥ 行首**；
            // 第一个字比行首还早，只可能是"相对本行"的写法。
            let firstWordStart = Int(ns.substring(with: pieces[0].range(at: 1))) ?? lineStart
            let base = firstWordStart < lineStart ? lineStart : 0

            var words: [LyricsWordDto] = []
            for (index, piece) in pieces.enumerated() {
                let textFrom = index == 0 ? restStart : NSMaxRange(pieces[index - 1].range)
                let textTo = piece.range.location
                guard textTo > textFrom else { continue }

                let text = ns.substring(with: NSRange(location: textFrom, length: textTo - textFrom))
                guard !text.isEmpty else { continue }

                let start = max(Int(ns.substring(with: piece.range(at: 1))) ?? lineStart, 0) + base
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

    /// 剥掉 `<Lyric_1 … LyricContent="…"/>` 外壳（没有外壳就原样返回）。
    ///
    /// ⚠️ 这一步**不能**用正则 `LyricContent="([^"]*)"`：正文里会出现裸引号
    /// （`Xだけの"人マニア"`），正则会在第一个引号处收尾，把后半首歌整个切掉 ——
    /// `人マニア` 36 行只解析出 20 行。判据与理由见 `QrcPayloadWrapper`。
    private static func lyricBody(_ qrc: String) -> String {
        QrcPayloadWrapper.body(from: qrc)
    }
}
