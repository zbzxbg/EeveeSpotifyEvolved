import Foundation

/// 用户自带歌词文件的解析层（设置页「导入」用）。
///
/// 只做**文本 → 时间轴**：不碰文件系统、不碰 UI、不判断"这歌该用哪一份"，
/// 所以 `Tests/ImportedLyrics` 能在 CI 里直接编译这一份并断言（本机没有 Swift 工具链）。
/// 落盘、匹配当前曲目、接到 `LyricsDto` 都在上层。
///
/// 支持的格式只收"歌词格式"：LRC（含增强型的词级标记）、SPL（Salt Player，LRC 的
/// 超集）、YRC（网易云逐字）、Lyricify Syllable（`.lys`，逐音节 + 行属性）、
/// Lyricify Lines（`.lyl`，逐行）。QRC / KRC 是加密打包的（正文需各自的密钥/包头），
/// SRT / ASS 是字幕容器（cue 与样式，行内时间语义与歌词不同），TTML 复用
/// `AmllTtmlParser` 那条线 —— 这几类不在这里解析，扩展名也不会被识别。
enum ImportedLyricFormat: String, CaseIterable {
    case lrc
    case spl
    case yrc
    case lys
    case lyl
    case ttml

    /// 允许出现在文件里的扩展名。
    var fileExtensions: [String] {
        switch self {
        case .lrc: return ["lrc"]
        case .spl: return ["spl"]
        case .yrc: return ["yrc"]
        case .lys: return ["lys"]
        case .lyl: return ["lyl"]
        case .ttml: return ["ttml"]
        }
    }
}

/// 一行导入歌词。`words` 为 nil 表示这一行只有行级时间。
struct ImportedLyricLine: Equatable {
    var startMs: Int
    var endMs: Int?
    var text: String
    var translation: String?
    var words: [ImportedLyricWord]?
}

struct ImportedLyricWord: Equatable {
    var text: String
    var startMs: Int
    var endMs: Int?
}

struct ImportedLyricMetadata: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var lengthMs: Int?
    /// `[offset:+500]` 这类全局偏移（毫秒），正数 = 歌词提前显示。
    var offsetMs: Int = 0
}

struct ImportedLyrics: Equatable {
    var format: ImportedLyricFormat
    var metadata: ImportedLyricMetadata
    var lines: [ImportedLyricLine]
}

enum ImportedLyricsParser {

    /// 扩展名 → 格式。不认识的扩展名返回 nil（上层据此提示"这个格式不支持"）。
    static func detect(fileExtension: String) -> ImportedLyricFormat? {
        let normalized = fileExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        for format in ImportedLyricFormat.allCases where format.fileExtensions.contains(normalized) {
            return format
        }
        return nil
    }

    static func parse(text: String, format: ImportedLyricFormat) -> ImportedLyrics {
        switch format {
        case .lrc, .spl:
            // SPL 是 LRC 的超集：行内词级标记、显式行结尾、同时间戳的译文都在这一条里。
            return parseLrcFamily(text, format: format)
        case .yrc:
            return parseYrc(text)
        case .lys:
            return parseLys(text)
        case .lyl:
            return parseLyl(text)
        case .ttml:
            // TTML 的行/词解析复用 `AmllTtmlParser`（App 层，测试目标里没有）：
            // 这一层只负责被识别、进入候选列表，真正取词在 `ImportedLyricsRepository`。
            return ImportedLyrics(format: .ttml, metadata: ImportedLyricMetadata(), lines: [])
        }
    }

    // MARK: - LRC / SPL

    /// 行首时间戳：`[mm:ss]`、`[mm:ss.xxx]`、`[mm:ss:xx]`。
    /// 小数位按 SPL 规则解释：不足三位是"后位省略了 0"（`[3:12.5]` = 500 ms）。
    private static let timestampPattern = try? NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,6}))?\]"#
    )
    /// 行内词级标记：SPL 的 `[mm:ss.xxx]` / `<mm:ss.xxx>`，以及 ESLyric 的 `<offset,duration>`。
    private static let wordMarkerPattern = try? NSRegularExpression(
        pattern: #"[\[<](\d{1,3}):(\d{1,2})(?:[.:](\d{1,6}))?[\]>]|[\[<](\d+),(\d+)[\]>]"#
    )
    private static let metadataPattern = try? NSRegularExpression(
        pattern: #"^\[([A-Za-z][A-Za-z0-9_]{1,15}):(.*)\]$"#
    )
    private static let awlrcPattern = try? NSRegularExpression(
        pattern: #"^\[awlrc:.*\]$"#, options: [.caseInsensitive]
    )
    private static let yrcLinePattern = try? NSRegularExpression(pattern: #"^\[(\d+),(\d+)\]"#)
    private static let yrcWordPattern = try? NSRegularExpression(pattern: #"\((\d+),(\d+)(?:,\d+)?\)([^\(]*)"#)

    private static func parseLrcFamily(_ text: String, format: ImportedLyricFormat) -> ImportedLyrics {
        var metadata = ImportedLyricMetadata()
        var lines: [ImportedLyricLine] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)

            // LX Music 会把重复的整份歌词塞进 `[awlrc:…]`；SPL 明确要求忽略这一行。
            if let awlrcPattern,
               awlrcPattern.firstMatch(in: line, range: fullRange) != nil {
                continue
            }

            // 纯元信息行：`[ti:]` / `[ar:]` / `[offset:]` ...
            if let metadataPattern,
               let match = metadataPattern.firstMatch(in: line, range: fullRange),
               let key = substring(match, 1, nsLine)?.lowercased(),
               let value = substring(match, 2, nsLine) {
                switch key {
                case "ti": metadata.title = value.nonEmpty
                case "ar": metadata.artist = value.nonEmpty
                case "al": metadata.album = value.nonEmpty
                case "length": metadata.lengthMs = lengthMs(value)
                case "offset": metadata.offsetMs = Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
                default: break
                }
                continue
            }

            // 行首可能有一串时间戳（重复行简写）；每一个都产生一行，正文相同。
            var starts: [Int] = []
            var cursor = 0
            if let timestampPattern {
                while cursor < nsLine.length {
                    let remaining = NSRange(location: cursor, length: nsLine.length - cursor)
                    guard let match = timestampPattern.firstMatch(in: line, range: remaining),
                          match.range.location == cursor,
                          let startMs = timestampMs(match, nsLine) else { break }
                    starts.append(startMs)
                    cursor = match.range.location + match.range.length
                }
            }

            let body = nsLine.substring(from: cursor)

            // 纯结束标记行（`[05:21.22]` 后面什么都不跟）：给前一行补结束时间。
            if starts.count == 1,
               body.trimmingCharacters(in: .whitespaces).isEmpty,
               let last = lines.last,
               last.endMs == nil {
                lines[lines.count - 1].endMs = starts[0]
                continue
            }

            guard !starts.isEmpty else {
                // 没有时间戳：SPL 允许紧挨主歌词的纯文本行是译文（一行）。
                if let last = lines.last, last.translation == nil, last.text != line {
                    lines[lines.count - 1].translation = line
                }
                continue
            }

            let parsed = parseBody(body, lineStartMs: starts[0])
            let text = parsed.text

            for (index, startMs) in starts.enumerated() {
                if text.isEmpty {
                    // 纯结束标记行：给前一行补上结束时间，不产生新行。
                    if index == 0, let endMs = parsed.endMs, !lines.isEmpty {
                        lines[lines.count - 1].endMs = endMs
                    }
                    continue
                }
                if index == 0, let last = lines.last, last.startMs == startMs, last.translation == nil {
                    // 同一时间戳的下一行是译文。
                    lines[lines.count - 1].translation = text
                    if lines[lines.count - 1].endMs == nil { lines[lines.count - 1].endMs = parsed.endMs }
                    continue
                }
                lines.append(
                    ImportedLyricLine(
                        startMs: startMs,
                        endMs: parsed.endMs,
                        text: text,
                        translation: nil,
                        words: parsed.words
                    )
                )
            }
        }

        // `[offset:]`：正数表示歌词应当提前显示，所以时间整体减去它。
        if metadata.offsetMs != 0 {
            let shift = metadata.offsetMs
            for index in lines.indices {
                lines[index].startMs = max(lines[index].startMs - shift, 0)
                if let end = lines[index].endMs { lines[index].endMs = max(end - shift, 0) }
                if let words = lines[index].words {
                    lines[index].words = words.map { word in
                        var shifted = word
                        shifted.startMs = max(shifted.startMs - shift, 0)
                        if let end = shifted.endMs { shifted.endMs = max(end - shift, 0) }
                        return shifted
                    }
                }
            }
        }

        return ImportedLyrics(format: format, metadata: metadata, lines: lines)
    }

    private struct ParsedBody {
        var text: String
        var endMs: Int?
        var words: [ImportedLyricWord]?
    }

    /// 把一行正文切成"文本 + 行内词级时间 + 行结束时间"。
    ///
    /// 三种写法都归一到同一条路：SPL 的 `[mm:ss.xxx]`、LRC A2 / SPL 的 `<mm:ss.xxx>`、
    /// ESLyric 的 `<offset,duration>`（相对行首）。行尾那个后面没有文字的标记就是行结束。
    private static func parseBody(_ body: String, lineStartMs: Int) -> ParsedBody {
        guard let wordMarkerPattern else {
            return ParsedBody(text: body, endMs: nil, words: nil)
        }
        let nsBody = body as NSString
        let matches = wordMarkerPattern.matches(
            in: body,
            range: NSRange(location: 0, length: nsBody.length)
        )
        guard !matches.isEmpty else {
            return ParsedBody(text: body, endMs: nil, words: nil)
        }

        var segments: [(text: String, startMs: Int)] = []
        var cursor = 0
        var currentStart = lineStartMs
        for match in matches {
            let text = nsBody.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor)
            )
            segments.append((text, currentStart))
            currentStart = markerMs(match, nsBody, fallback: currentStart)
            cursor = match.range.location + match.range.length
        }
        segments.append((nsBody.substring(from: cursor), currentStart))

        // 末尾只有标记、没有文字 ⇒ 这是行结束时间。
        var endMs: Int?
        if let last = segments.last, last.text.isEmpty {
            endMs = last.startMs
            segments.removeLast()
        }
        let nonEmpty = segments.filter { !$0.text.isEmpty }
        guard !nonEmpty.isEmpty else {
            return ParsedBody(text: "", endMs: endMs, words: nil)
        }

        var words: [ImportedLyricWord] = []
        for (index, segment) in nonEmpty.enumerated() {
            let next = index + 1 < nonEmpty.count ? nonEmpty[index + 1].startMs : endMs
            words.append(ImportedLyricWord(text: segment.text, startMs: segment.startMs, endMs: next))
        }
        let text = nonEmpty.map(\.text).joined()
        return ParsedBody(text: text, endMs: endMs, words: words.count > 1 ? words : nil)
    }

    private static func substring(
        _ match: NSTextCheckingResult,
        _ index: Int,
        _ string: NSString
    ) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let range = match.range(at: index)
        guard range.location != NSNotFound else { return nil }
        return string.substring(with: range)
    }

    private static func timestampMs(_ match: NSTextCheckingResult, _ string: NSString) -> Int? {
        guard let minute = integer(match, 1, string),
              let second = integer(match, 2, string) else { return nil }
        return (minute * 60 + second) * 1000 + fractionMs(match, 3, string)
    }

    /// 行内标记：优先按 `mm:ss.xxx` 解析；ESLyric 的 `<offset,duration>` 相对行首。
    private static func markerMs(
        _ match: NSTextCheckingResult,
        _ string: NSString,
        fallback: Int
    ) -> Int {
        if let minute = integer(match, 1, string), let second = integer(match, 2, string) {
            return (minute * 60 + second) * 1000 + fractionMs(match, 3, string)
        }
        guard let offset = integer(match, 4, string) else { return fallback }
        return fallback + offset
    }

    private static func integer(_ match: NSTextCheckingResult, _ index: Int, _ string: NSString) -> Int? {
        guard let value = substring(match, index, string), !value.isEmpty else { return nil }
        return Int(value)
    }

    /// 小数位：`5` = 500 ms、`05` = 50 ms、`050` = 50 ms、`0500` = 50 ms（多出的位截掉）。
    private static func fractionMs(_ match: NSTextCheckingResult, _ index: Int, _ string: NSString) -> Int {
        guard let digits = substring(match, index, string), !digits.isEmpty else { return 0 }
        let padded: String
        switch digits.count {
        case 1: padded = digits + "00"
        case 2: padded = digits + "0"
        default: padded = String(digits.prefix(3))
        }
        return Int(padded) ?? 0
    }

    private static func lengthMs(_ value: String) -> Int? {
        // `[length:03:12]` 与纯毫秒两种写法都见过。
        let wrapped = "[\(value)]"
        if let timestampPattern {
            let nsWrapped = wrapped as NSString
            if let match = timestampPattern.firstMatch(
                in: wrapped,
                range: NSRange(location: 0, length: nsWrapped.length)
            ) {
                return timestampMs(match, nsWrapped)
            }
        }
        return Int(value.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - YRC

    private static func parseYrc(_ text: String) -> ImportedLyrics {
        var lines: [ImportedLyricLine] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            guard let yrcLinePattern,
                  let header = yrcLinePattern.firstMatch(in: line, range: fullRange),
                  header.numberOfRanges >= 3,
                  let startMs = integer(header, 1, nsLine) else { continue }
            let durationMs = integer(header, 2, nsLine)

            let rest = nsLine.substring(
                from: header.range.location + header.range.length
            ) as NSString
            var content = ""
            var words: [ImportedLyricWord] = []
            if let yrcWordPattern {
                let matches = yrcWordPattern.matches(
                    in: rest as String,
                    range: NSRange(location: 0, length: rest.length)
                )
                for match in matches {
                    guard match.numberOfRanges >= 4,
                          let wordStart = integer(match, 1, rest) else { continue }
                    let wordDuration = integer(match, 2, rest) ?? 0
                    let wordText = substring(match, 3, rest) ?? ""
                    content += wordText
                    words.append(
                        ImportedLyricWord(
                            text: wordText,
                            startMs: wordStart,
                            endMs: wordStart + max(wordDuration, 0)
                        )
                    )
                }
            }
            guard !content.isEmpty else { continue }
            lines.append(
                ImportedLyricLine(
                    startMs: startMs,
                    endMs: durationMs.map { startMs + max($0, 0) },
                    text: content,
                    translation: nil,
                    words: words.count > 1 ? words : nil
                )
            )
        }
        return ImportedLyrics(format: .yrc, metadata: ImportedLyricMetadata(), lines: lines)
    }

    // MARK: - Lyricify Syllable（.lys）

    /// 行头是**行属性**而不是时间：`[property]Word (start,duration)word(start,duration)`。
    /// 属性 0–8 编码"背景人声 / 对唱视图"（0/3 无对唱、1 左、2 右、6–8 背景人声）。
    /// `ImportedLyricLine` 还没有这两个维度，属性先只读不用 —— 按属性丢行会把主歌词
    /// 也一起丢掉（背景人声行与主歌词行属性不同），所以这里保守地保留所有行。
    private static let lysLinePattern = try? NSRegularExpression(pattern: #"^\[(\d{1,2})\]"#)
    /// LYS 的括号在**词后面**：`Lately (358,1336)` = Lately 从 358 起持续 1336 ms。
    private static let lysWordPattern = try? NSRegularExpression(pattern: #"\((\d+),(\d+)\)"#)

    private static func parseLys(_ text: String) -> ImportedLyrics {
        var metadata = ImportedLyricMetadata()
        var lines: [ImportedLyricLine] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)

            if let metadataPattern,
               let match = metadataPattern.firstMatch(in: line, range: fullRange),
               let key = substring(match, 1, nsLine)?.lowercased(),
               let value = substring(match, 2, nsLine) {
                switch key {
                case "ti": metadata.title = value.nonEmpty
                case "ar": metadata.artist = value.nonEmpty
                case "al": metadata.album = value.nonEmpty
                default: break
                }
                continue
            }

            guard let lysLinePattern,
                  let header = lysLinePattern.firstMatch(in: line, range: fullRange),
                  let lysWordPattern else { continue }

            let body = nsLine.substring(
                from: header.range.location + header.range.length
            ) as NSString
            let matches = lysWordPattern.matches(
                in: body as String,
                range: NSRange(location: 0, length: body.length)
            )
            guard !matches.isEmpty else { continue }

            var words: [ImportedLyricWord] = []
            var cursor = 0
            for match in matches {
                let wordText = body.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor)
                )
                guard let start = integer(match, 1, body) else { continue }
                let duration = integer(match, 2, body) ?? 0
                words.append(
                    ImportedLyricWord(
                        text: wordText,
                        startMs: start,
                        endMs: start + max(duration, 0)
                    )
                )
                cursor = match.range.location + match.range.length
            }
            // 尾部落单的文字（没有时间）挂到最后一个词上：宁可时间不准，也别整句少字。
            let tail = body.substring(from: cursor)
            if !tail.isEmpty, var last = words.last {
                last.text += tail
                words[words.count - 1] = last
            }

            let content = words.map(\.text).joined()
            guard !content.trimmingCharacters(in: .whitespaces).isEmpty,
                  let first = words.first else { continue }
            lines.append(
                ImportedLyricLine(
                    startMs: first.startMs,
                    endMs: words.last?.endMs,
                    text: content,
                    translation: nil,
                    words: words.count > 1 ? words : nil
                )
            )
        }
        return ImportedLyrics(format: .lys, metadata: metadata, lines: lines)
    }

    // MARK: - Lyricify Lines（.lyl）

    /// `[start,end]Lyrics`：**两个数字都是绝对毫秒**（第二个是结束时刻，不是时长）；
    /// 头部带 `[type:LyricifyLines]`，由元信息分支吞掉。
    private static let lylLinePattern = try? NSRegularExpression(
        pattern: #"^\[(\d+),(\d+)\](.*)$"#
    )

    private static func parseLyl(_ text: String) -> ImportedLyrics {
        var metadata = ImportedLyricMetadata()
        var lines: [ImportedLyricLine] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)

            if let metadataPattern,
               let match = metadataPattern.firstMatch(in: line, range: fullRange),
               let key = substring(match, 1, nsLine)?.lowercased(),
               let value = substring(match, 2, nsLine) {
                switch key {
                case "ti": metadata.title = value.nonEmpty
                case "ar": metadata.artist = value.nonEmpty
                case "al": metadata.album = value.nonEmpty
                default: break
                }
                continue
            }

            guard let lylLinePattern,
                  let match = lylLinePattern.firstMatch(in: line, range: fullRange),
                  let start = integer(match, 1, nsLine),
                  let end = integer(match, 2, nsLine),
                  end >= start else { continue }
            let content = (substring(match, 3, nsLine) ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { continue }
            lines.append(
                ImportedLyricLine(
                    startMs: start,
                    endMs: end,
                    text: content,
                    translation: nil,
                    words: nil
                )
            )
        }
        return ImportedLyrics(format: .lyl, metadata: metadata, lines: lines)
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 读文件的编码：UTF-8 → UTF-16（含 BOM）→ GB18030。
///
/// 中文歌词文件里 GBK/GB18030 很常见（Windows 记事本的默认编码），而 Foundation 的
/// `String(encoding:)` 原样交给系统，GB18030 只能走 CFString 那个编号（0x80000632）。
enum ImportedLyricsDecoder {
    private static let gb18030 = String.Encoding(rawValue: 0x8000_0632)

    static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        // 只有带 BOM 时才按 UTF-16 解：任意 4 个字节都能被 UTF-16 解成"合法"的乱码，
        // 那会把 GBK 文件吃掉（GBK 是中文歌词最常见的编码）。
        let bomLittle = Data([0xFF, 0xFE])
        let bomBig = Data([0xFE, 0xFF])
        if data.starts(with: bomLittle) || data.starts(with: bomBig),
           let text = String(data: data, encoding: .utf16) {
            return text
        }
        if let text = String(data: data, encoding: gb18030) { return text }
        if let text = String(data: data, encoding: .utf16LittleEndian) { return text }
        return String(data: data, encoding: .isoLatin1)
    }
}
