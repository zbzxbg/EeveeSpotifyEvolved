import Foundation

// MARK: - 「SpicyLyrics 交叉验证」：把上游和谐的星号词补回来
//
// 做成**实验开关**，名字「SpicyLyrics交叉验证」，**默认关**。
//
// 机制与上游那份一致，但**判据换掉了**（见 `LyricsCensorFill` 文件头）：
// · 上游用 `\b\*{3,}\b` 检测 —— 实测只命中 `f***k` 那种"星号两侧紧贴字母"的写法，
// `my **** line` / `**** you` **一个都不命中** ⇒ 那个功能从来没真正接线过。
// 现在改成 `\*{3,}`，并把"按词数 + 词位置"换成"**行内字面片段**做锚 + 替换词唯一"。
// · 明确要修掉的 CJK 事故：旧算法按空格切词，中日韩整行只有 1 个"词"，于是
// `containsFullCensor` 对整行成立、`wordsMatchExceptCensored` 又把它 `continue` 掉
// ⇒ **任何**同长度（=1 词）的候选行都会被当成匹配，整行被替换成别的歌词。
//
// 源的选择与顺序（与「NetEase 交叉验证」的分级同理，但要求不一样）：
// 这里要保证的是"**同一句**"，不是"同一首歌" —— 行内字面锚点已经把这件事钉住了
// （锚点不吻合就补不了），所以不需要像判错歌那样只认 track-id 源。顺序因此按
// **未被和谐的可能性 + 独立性 + 开销**排：
// ① AMLL（track id 锚定、社区逐词、独立于 SL 的上游）
// ② LRCLIB（精确键单条、社区提交、通常未打码）
// ③ PetitLyrics（精确键单条，日系覆盖面好）
// ④ Musixmatch（track id 锚定，但 **SL 的上游就是 MXM** ⇒ 很可能带着同样的星号，
// 放后面：不为它单独多花一次请求，只在前面都没补全时才试）
// ⑤ Genius（有"自己挑"那一步，身份最不保险 ⇒ 最后，且只作补词用）
// 命中即停：一个源补完了就不再往下问。

struct LyricsUncensorFill {

    /// 单个源的预算（秒）。这里的源都不做 503 退避（SL 自己才做），3s 够；
    /// 整次最多 5 个源 × 3s，但因为"补完即停"，实际几乎总是 1~2 次。
    static let perSourceBudget: TimeInterval = 3.0

    private struct UncensorSource {
        let name: String
        let repository: LyricsRepository
    }

    /// Returns a new array of line texts with censored tokens filled in
    /// where a confident match was found, otherwise unchanged.
    ///
    /// 接在 `SpicyLyricsRepository.parseLyricsData` 之后：Static / Line / Syllable 三条解析
    /// 路径最终都汇合到 `dto.lines`，所以只改这一处即可全覆盖。**只改行文本**，
    /// 行的时间戳 / 逐字时间轴原样保留。
    static func fill(
        lines: [String],
        query: LyricsSearchQuery,
        options: LyricsOptions
    ) -> [String] {
        // 实验开关（默认关）。关着就**一次网络都不发**。
        guard UserDefaults.experimentsOptions.spicyLyricsCrossValidation else {
            return lines
        }

        let censoredBefore = lines.filter { LyricsCensorFill.hasCensor($0) }.count
        // 没有星号 ⇒ 直接返回，避免任何回退请求（与上游那条提前返回同一个目的）。
        guard censoredBefore > 0 else { return lines }

        writeDebugLog("[SpicyLyrics] uncensor — \(censoredBefore) censored line(s), asking other sources")

        var result = lines
        for source in uncensorSources() {
            let remaining = result.filter { LyricsCensorFill.hasCensor($0) }.count
            guard remaining > 0 else { break }

            guard let candidateLines = LyricsLinesBudget.lines(perSourceBudget, {
                try source.repository.getLyrics(query, options: options).lines.map { $0.content }
            }) else {
                writeDebugLog("[SpicyLyrics] uncensor source=\(source.name) no usable text")
                continue
            }

            let filled = LyricsCensorFill.fill(lines: result, withCandidates: candidateLines)
            if filled.resolved > 0 {
                writeDebugLog(
                    "[SpicyLyrics] uncensor source=\(source.name)"
                        + " filled \(filled.resolved) line(s), \(remaining - filled.resolved) left"
                )
            }
            result = filled.lines
        }

        let censoredAfter = result.filter { LyricsCensorFill.hasCensor($0) }.count
        if censoredAfter > 0 {
            writeDebugLog("[SpicyLyrics] uncensor — \(censoredAfter) censored line(s) left as-is")
        }
        return result
    }

    private static func uncensorSources() -> [UncensorSource] {
        [
            UncensorSource(name: "AMLL", repository: AmllTtmlLyricsRepository.shared),
            UncensorSource(name: "LRCLIB", repository: LrclibLyricsRepository.shared),
            UncensorSource(name: "PetitLyrics", repository: PetitLyricsRepository()),
            UncensorSource(name: "Musixmatch", repository: MusixmatchLyricsRepository.shared),
            UncensorSource(name: "Genius", repository: GeniusLyricsRepository()),
        ]
    }
}
