import Foundation

/// 标准 LRC（`[mm:ss.xx]词`）解析 —— QQ 音乐、酷狗的纯文本档共用。
///
/// 为什么不复用 `LrclibLyricsRepository.mapSyncedLyricsLines`：那份是私有方法，而且只认
/// `[mm:ss]` 单时间戳、且对每个捕获组 `!` 强解包。这里要处理的是 QQ / 酷狗那种更脏的输入：
/// 一行挂多个时间戳（副歌复用）、毫秒位 1~3 位混用、`[ti:]`/`[ar:]` 元数据行、`[offset:]`。
///
/// 本文件**只依赖 Foundation**，所以能进 `Tests/` 单独编译。
enum LrcText {

    /// `[mm:ss]` / `[mm:ss.x]` / `[mm:ss.xx]` / `[mm:ss.xxx]`，分钟位最多三位。
    private static let tagRegex = try? NSRegularExpression(
        pattern: "\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]"
    )

    /// 解析出**带行时间轴**的行，按时间升序。没有任何时间标签时返回空数组。
    ///
    /// ⚠️ 空白行（只有时间戳、没有词）**整行丢弃**，不换成 `♪`。
    /// 这是定下的间奏纪律（见 `SpicyLineFilter` 文件头）：
    /// 空行在渲染层与"漏了一句词"同形，间奏应该由 `LyricInterludeTimeline`
    /// 从相邻行的时间间隙去推，而不是靠一行占位。
    ///
    /// ⚠️ `[offset:±N]` **不施加**：这个标签的符号方向在各家播放器里不统一
    /// （有的是"歌词提前"，有的是"时间轴整体加"），照着某一家的语义写会有一半场景反向偏。
    /// 真要调，歌词偏移（`LyricsTimingOffset`），按曲目存、不会猜错。
    static func lines(from text: String) -> [LyricsLineDto] {
        guard let tagRegex else { return [] }

        var parsed: [(offset: Int, line: LyricsLineDto)] = []

        for row in text.components(separatedBy: .newlines) {
            let row = row.trimmingCharacters(in: .whitespaces)
            guard !row.isEmpty else { continue }

            let ns = row as NSString
            let matches = tagRegex.matches(in: row, range: NSRange(location: 0, length: ns.length))
            // 没有时间标签 ⇒ 这是 `[ti:…]` / `[ar:…]` / `[offset:…]` 这类元数据行，
            // 或者根本就是一段不带时间的纯文本。两种都不该进"同步歌词"。
            guard let last = matches.last else { continue }

            var content = ns.substring(from: NSMaxRange(last.range))
            content = String(content.drop(while: { $0 == " " || $0 == "\t" }))
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            for match in matches {
                guard let offset = offsetMs(of: match, in: ns) else { continue }
                parsed.append((offset, LyricsLineDto(content: content, offsetMs: offset)))
            }
        }

        guard !parsed.isEmpty else { return [] }
        // 一行挂多个时间戳时，原顺序不再是时间顺序 —— 必须重排，否则渲染层的高亮会倒着走。
        // `sorted` 在 Swift 里不保证稳定，但同 offset 的两行内容相同，先后无所谓。
        return parsed.sorted { $0.offset < $1.offset }.map { $0.line }
    }

    /// 解析成 dto。没有一行带时间轴 ⇒ nil（交给调用方判"这个源没答上来"）。
    static func dto(from text: String) -> LyricsDto? {
        let parsed = lines(from: text)
        guard !parsed.isEmpty else { return nil }
        let contents = parsed.map(\.content)
        return LyricsDto(
            lines: parsed,
            timeSynced: true,
            romanization: contents.canBeRomanized ? .canBeRomanized : .original
        )
    }

    private static func offsetMs(of match: NSTextCheckingResult, in ns: NSString) -> Int? {
        guard match.numberOfRanges >= 3 else { return nil }
        guard let minutes = Int(ns.substring(with: match.range(at: 1))),
              let seconds = Int(ns.substring(with: match.range(at: 2))) else { return nil }

        var fraction = 0
        let fractionRange = match.range(at: 3)
        if fractionRange.location != NSNotFound {
            let raw = ns.substring(with: fractionRange)
            let value = Int(raw) ?? 0
            // `.5` 是半秒（500ms）、`.50` 是 50 厘秒（500ms）、`.500` 是 500 毫秒。
            switch raw.count {
            case 1: fraction = value * 100
            case 2: fraction = value * 10
            default: fraction = value
            }
        }
        return minutes * 60_000 + seconds * 1_000 + fraction
    }
}
