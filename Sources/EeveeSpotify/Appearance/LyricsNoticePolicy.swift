import Foundation

/// 打开之后"没词可画时写哪一句话"的**判定结果**（本地化字符串由视图层映射 —— 这里只选分支）。
///
/// 四种"没词"必须分开说，这正是用户要的；把它们混成一句就是历史上那条误报
/// （"歌词明明有、我们却说未找到"）的来源。见 `LyricsNoticePolicy.notice`。
enum LyricsNotice: Equatable {
    /// 源**明确**判定是纯音乐（`LyricsDto.isInstrumental`）。
    case instrumental
    /// 有行，但**一行时间都没有**、连文本都提不出来。
    case noTimeline
    /// 查完了没有 / 转换异常。
    case unavailable
    /// 还在查。
    case lookingUp
}

/// 「这一拍该不该写说明、写哪一句」的**纯判定**。
///
/// 为什么值得单独一个类型：这条策略被反复改过（先是"没词 ⇒ 键点不动"，再是"要有句话"，
/// 然后是"纯音乐不许冒充查无此歌"、"没有时间轴不许说成未找到"），而每一档都对应一个
/// **用户能看见的错**。抽出来之后 `Tests/LyricsNoticePolicy` 把**优先级**钉住：
/// ① 有行而且画得出来 ⇒ 正常画歌词（`nil`，不写说明）；② 纯音乐；③ 有行却画不出来
/// （先分"没有时间轴"与"转换异常"）；④ 数据还没到（正在查 / 查完了没有）。
enum LyricsNoticePolicy {

    /// 判定这一拍要不要写说明、写哪一句。`nil` = **有歌词可画**，不写说明。
    ///
    /// - Parameters:
    /// - hasLines: 这一首**有行**（`currentLyricsDto?.lines.isEmpty == false`）。
    /// - hasDrawableLines: 行模型**画得出来**（`currentLines != nil`）。
    /// - isInstrumental: 源**明确**说是纯音乐（不许拿"查无此歌"冒充它）。
    /// - hasAnyTimestamp: 行里**至少一行带时间**（只有 `hasLines` 为真时才有意义）。
    /// - hasUntimedText: 文本提得出来 ⇒ 可以画**静态歌词**（`currentUntimedLines != nil`）。
    /// - isLookingUp: 数据还没到，而且**还在查**（`.idle` / `.loading`）；
    /// 为假且没有行 ⇒ 查完了没有（`.failed` / `.found`）。
    static func notice(
        hasLines: Bool,
        hasDrawableLines: Bool,
        isInstrumental: Bool,
        hasAnyTimestamp: Bool,
        hasUntimedText: Bool,
        isLookingUp: Bool
    ) -> LyricsNotice? {
        // ① 有行、而且画得出来 ⇒ 正常画歌词。
        if hasLines, hasDrawableLines { return nil }
        // ② 源**明确**说是纯音乐（`isInstrumental` 只在源这么判定时才置位）。
        if isInstrumental { return .instrumental }
        // ③ 有行、却画不出来 —— 先说清是**哪一档**"画不出来"，别一律报"没找到"。
        if hasLines {
            if !hasAnyTimestamp {
                // 一行时间都没有：能提出文本就画**静态歌词**（不写说明），提不出来才写那句话。
                return hasUntimedText ? nil : .noTimeline
            }
            // 有行、也有时间，却还是画不出来 ⇒ 转换异常。按"没找到"说，**别做成死键**。
            return .unavailable
        }
        // ④ 数据还没到：正在查 vs 查完了没有。
        return isLookingUp ? .lookingUp : .unavailable
    }
}
