import CommonCrypto
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
/// 2. **3DES 解密**，ECB、无填充、密钥写死 24 字节；
/// 3. **zlib 解压**（走 `ZlibInflate`，与酷狗 KRC 共用）。
///
/// 密钥 `!@#)(*$%123ZXC!@!@#)(NHL` 与"三步顺序"由两个独立项目交叉验证过：
/// `chenmozhijin/LDDC`（GPL-3.0，`core/decryptor/__init__.py` 的 `QRC_KEY`）与
/// `naiyQAQ/pyqdes`（MIT，`main.cpp` 里三个 8 字节密钥 + `ddes/des/ddes` 的顺序）。
/// 两者的字节序完全一致 —— 所以 `CCCrypt(kCCAlgorithm3DES, kCCDecrypt, ECB)` 就是它。
///
/// ── 与 yrc / KRC 的两处格式差异（都踩过）
/// · **时间戳写在文字后面**：`词(起始,时长)`，不是 `(起始,时长)词`；
/// · 字偏移一般是**整首绝对时间**（和 yrc 一样、和 KRC 相反）。
/// 但不同来源的样本里也见过相对行首的，所以这里**逐行探测**（见 `lines(from:)`）。
enum QrcText {

    /// 24 字节 = k1|k2|k3，每个 8 字节。顺序错了会解出一堆乱码然后解压失败。
    private static let tripleDESKey = Array("!@#)(*$%123ZXC!@!@#)(NHL".utf8)

    /// 解密后的正文有时裹在 `<Lyric_1 LyricType="1" LyricContent="…"/>` 里。
    private static let wrapperRegex = try? NSRegularExpression(
        pattern: "<Lyric_1[^>]*LyricContent=\"([^\"]*)\""
    )
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
        guard let plain = threeDESDecrypt(cipher) else { return nil }
        guard let inflated = ZlibInflate.inflate(plain) else { return nil }
        return String(data: inflated, encoding: .utf8)
    }

    /// 云端给的是 hex；备一份 base64 的尝试（代价只有几微秒，比"某个条目解不开"划算）。
    private static func cipherBytes(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let hex = hexDecoded(trimmed), hex.count % kCCBlockSize3DES == 0 { return hex }
        if let base64 = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters),
           base64.count % kCCBlockSize3DES == 0 { return base64 }
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

    private static func threeDESDecrypt(_ data: Data) -> Data? {
        let blockSize = kCCBlockSize3DES
        let keyLength = tripleDESKey.count
        let total = data.count
        guard total > 0, total % blockSize == 0 else { return nil }

        var output = Data(count: total)
        var moved = 0

        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                tripleDESKey.withUnsafeBufferPointer { keyBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithm3DES),
                        // ECB + **不加填充**：密文本身就是 8 的整数倍，加填充会把尾部弄坏。
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress, keyLength,
                        nil,
                        inBytes.baseAddress, total,
                        outBytes.baseAddress, total,
                        &moved
                    )
                }
            }
        }

        guard status == kCCSuccess, moved == total else { return nil }
        return output
    }

    // MARK: - 解析

    static func dto(fromEncrypted encrypted: String) -> LyricsDto? {
        guard let text = decode(encrypted) else { return nil }
        return dto(from: text)
    }

    static func dto(from qrc: String) -> LyricsDto? {
        let parsed = lines(from: qrc)
        guard !parsed.isEmpty else { return nil }
        let contents = parsed.map(\.content)
        return LyricsDto(
            lines: parsed,
            timeSynced: true,
            romanization: contents.canBeRomanized ? .canBeRomanized : .original
        )
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
    private static func lyricBody(_ qrc: String) -> String {
        guard let wrapperRegex else { return qrc }
        let ns = qrc as NSString
        guard let match = wrapperRegex.firstMatch(
            in: qrc, range: NSRange(location: 0, length: ns.length)
        ), match.numberOfRanges >= 2 else { return qrc }
        return unescapeXML(ns.substring(with: match.range(at: 1)))
    }

    /// 属性值里的 `&quot;` 之类要还原 —— 正文裹在 XML 属性里时，`"` 只能写成实体。
    /// `&amp;` 放最后：先还原它会把 `&amp;lt;` 变成 `&lt;` 再被下一轮吃掉。
    private static func unescapeXML(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
