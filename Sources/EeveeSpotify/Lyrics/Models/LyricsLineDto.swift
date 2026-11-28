import Foundation

/// 这一行是谁唱的（目前只有 TTML 源会给：`ttm:agent`）。
///
/// 与 `LyricsBackgroundVocalDto` 的区别：那个是**同一行里叠着的**副唱，这个是
/// **这一整行的主角** —— 对唱歌里左右两边各是谁。渲染层据此把另一位歌手的行排到另一端。
struct LyricsAgentDto {
    var identifier: String
    var displayName: String
    var isGroup: Bool
    /// 这一行要不要排到另一端（判据在解析层：恰好两位个人歌手时，第二位为 true）。
    var isFlipped: Bool
}

struct LyricsLineDto {
    var content: String
    var offsetMs: Int?
    /// 这一行**唱完**的时刻（TTML 的 `<p end>`）。
    ///
    /// 与"下一行的起点"不是一回事：两者之间可能有一段空白（间奏）。没有它时，显示层
    /// 只能拿下一行起点当这一行的结束 ⇒ "这一句拖得很长"和"这里没人唱"在数据上长得一模一样。
    ///
    /// 现在页内这一层也用它：`LyricLinesAdapter` 拿它当显示时长（行级来源从"到下一句为止"
    /// 变成"唱完为止"），并原样记进 `LyricLine.contentEndTime`；间奏判定
    /// （`LyricInterludeTimeline`）因此不用再靠 `LyricVocalDurationEstimator` 猜尾点。
    /// 锁屏同样按它切行（`LockScreenLyricsFetcher` 取 `line.endOffsetMs`，缺了才退回下一行起点）。
    ///
    /// 只有 TTML 源会给这个字段（AMLL / Apple 官方 TTML / BiniLyrics / Unison /
    /// 用户导入的 `.ttml` 都走同一个 `AmllTtmlParser` + `AmllLyricsMapper`）；别的源一律 nil。
    var endOffsetMs: Int? = nil
    var words: [LyricsWordDto]? = nil
    /// 背景人声/副唱（与上面那一列同一个来源集合：只有 TTML 源会给，看 `ttm:role="x-bg"`）。
    ///
    /// 它**不属于** `content` / `words`：那些是主词序列。副唱与主词时间重叠，
    /// 由渲染层单独画一小行，而不是顺序拼进主歌。
    var backgroundVocal: LyricsBackgroundVocalDto? = nil

    /// 这一行的歌手（与上面两列同一个来源集合：只有 TTML 源会给；别的源一律 nil）。
    var agent: LyricsAgentDto? = nil

    /// **空白行** —— 内容去掉空白就没了，而且这一行上**没有**词级数据、
    /// 也没有副唱。显示层/注入 payload 用它把这种行整行丢掉（判据**只有这一份**，
    /// 两个调用点见 `LyricsDto.droppingBlankLinesForDisplay` 与
    /// `LyricsDto.toSpotifyLyricsData`）。
    ///
    /// 为什么要把 `words` / `backgroundVocal` 也写进判据：
    /// · AMLL 的「纯副唱行」主词文本本来就是空的（`AmllLyricsMapper.makeDto` 特意保留它，
    /// 注释写着"只有副唱的行要保留，否则会丢掉纯副唱那几行的内容"）——
    /// 只看 `content` 会把那种行整行删掉；
    /// · 词级序列在的行同样不该因为 `content` 空就被删（那是上游的形态，不是空行）。
    ///
    /// ⚠️ 它**不是**「间奏行」判据：这里只认真正的空白（空串 / 纯空格 / 纯换行），
    /// `♪` `♫` 那类占位符一律不动 —— 音乐符号由各仓库自己更严格的判据管
    /// （`NeteaseLyricsRepository.isInterludeRow` /
    /// `MusixmatchLyricsRepository.isMxmInterludeRow`，起无条件整行丢弃），
    /// 别在这里抢它们的活。
    var isBlankForDisplay: Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (words?.isEmpty ?? true)
            && backgroundVocal == nil
    }
}
