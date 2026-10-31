import Foundation

struct LyricsLineDto {
    var content: String
    var offsetMs: Int?
    /// （Q6 清点里的第 ② 条）：**这一行唱完的时刻**（AMLL 的 `<p end>`）。
    ///
    /// 以前只在解析层用来算 `lastLineEndMs`/打日志，进了 DTO 就丢 ⇒ 显示层只能拿
    /// **下一行的起点**当这一行的结束（`LyricLinesAdapter` 的 `nextStartTime`）——
    /// 于是"这一句拖得很长"和"这里没人唱"在数据上**长得一模一样**（慢歌/间奏会偏）。
    ///
    /// ⚠️ **目前只是把它收下来，显示层还没用它**：真机 `LyricLinesAdapter` 现在把
    /// `nextStartTime - startTime` 当整行的时长（高亮会一直亮到下一行开始），
    /// 改成"唱完就收"会连带改观感与间奏判定 ⇒ 那一步要有一次真机 A/B 才动。
    /// 只有 AMLL 会给这个字段（别的源一律 nil）。
    var endOffsetMs: Int? = nil
    var words: [LyricsWordDto]? = nil
    /// 背景人声/副唱（目前只有 AMLL 会给出）。
    ///
    /// 它**不属于** `content` / `words`：那些是主词序列。副唱与主词时间重叠，
    /// 由渲染层单独画一小行，而不是顺序拼进主歌。
    var backgroundVocal: LyricsBackgroundVocalDto? = nil

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
