import Foundation

// MARK: - 自动优选（auto select）
//
// 取代原来的「多级回退」。两者唯一的、也是全部的区别：
//
//   多级回退 —— **谁先答出来就用谁**（Mxm → PL → LRC → Gen，第一个非空即返回）。
//   自动优选 —— **谁的时间轴更细就用谁**：先到的纯文本 / 逐行歌词先留在手里，
//               链路继续往下问，直到拿到逐字歌词，或者为「升级」预留的预算用完。
//
// 为什么必须保留「先到先用」那一半：Spotify 的歌词卡片是**等这次响应**才建的
// （见 `LyricsResponseCache` 文件头那张真机实测表：响应晚于 1~4 秒就赶不上建列表那一刻）。
// 所以链路不能为了逐字歌词一路问到底 —— 手里已经有一份逐行歌词时，最多再等
// `upgradeBudget` 秒，到点就交手里的那份。这一条是照 Taurus 的做法：
// 它把「第一个有时间轴的答案就收工」写成了链路的硬规则，理由同样是卡片会等不到。
//
// 另一个照抄 Taurus 的点：**纯文本不能终止查找**。Genius 那种没有时间轴的源答上来
// 之后，链路必须继续问后面能给时间轴的源 —— 否则「有没有歌词」会被一个最差的答案决定。
//
// 链路顺序是**用户自己排的**（设置 → 歌词 → 来源顺序，见 `LyricsSourceOrder`），
// 但**顺序只决定"先问谁"，不决定"谁赢"**：
// 逐字永远赢逐行，逐行永远赢纯文本，与谁先被问到无关。

/// 一份歌词的「时间轴档次」——自动优选唯一的排序依据。
///
/// 判据不新写一套：直接用渲染层那两个 `hasUsableWordLevelData` / `hasUsableLineLevelData`
/// （`WordByWord/WordByWordLyricsFacts.swift`）。口径必须只有一份 ——
/// 否则会出现「优选认为这是逐字、渲染层认为不是」这种自相矛盾的结果。
enum LyricsTimingTier: Int, Comparable {
    /// 没有时间轴（Genius 那种纯文本），或者时间轴稀疏到不可用。
    case untimed = 0
    /// 行级时间轴（LRCLIB 的 synced lyrics、没有 yrc 的网易云…）。
    case line = 1
    /// 词级时间轴（Spicy / AMLL / yrc / Petit 的逐字档 / MxM 的 richsync）。
    case word = 2

    static func < (lhs: LyricsTimingTier, rhs: LyricsTimingTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// 日志用。写死字符串而不是 `\(self)`：反射形式跨 Swift 版本不稳定，日志要能 grep。
    var logName: String {
        switch self {
        case .untimed: return "untimed"
        case .line: return "line-timed"
        case .word: return "word-timed"
        }
    }
}

/// 自动优选保留下来的一份结果。
struct LyricsAutoSelectPick {
    let dto: LyricsDto
    /// **实际**给出这份歌词的源（不是"链路的第几跳"）。
    let source: LyricsSource
    let tier: LyricsTimingTier
    /// 从链路起跑到这份答案到手用了多久（秒）。只用于日志。
    let elapsed: TimeInterval
}

enum LyricsAutoSelect {

    // MARK: - 预算

    /// 单个源的等待上限。分两档，沿用旧「多级回退」真机调过的值：
    /// 只打一个接口的源（LRCLIB / AMLL / Spicy）3 秒足够；
    /// 要先搜索再取词的源（MxM / Petit / 网易 / Genius）给 5 秒。
    ///
    /// ⚠️ Genius 曾经是 3 秒，真机日志里出现过两次 `Genius timed out after 3.0s`，
    /// 而同一场里它又有正常出词的例子 —— 3 秒那一档经常是"超时被跳过"而不是"被评估"。
    static let fastSourceTimeout: TimeInterval = 3
    static let slowSourceTimeout: TimeInterval = 5

    /// 手里已经有逐行歌词时，**还愿意为逐字多等多久**。
    ///
    /// 4 秒是个折中：链路前几跳的失败通常在 1~2 秒内返回，4 秒足够再问两三个源；
    /// 再长就会踩到「响应太晚，卡片建不出来」那条线（见文件头）。
    static let upgradeBudget: TimeInterval = 4

    /// 整条链路的上限。Spotify 那次 `color-lyrics` 请求的预算是 18 秒
    /// （`LyricsResponseCache.firstAttemptBudget`），这里留 2 秒余量给序列化与投递。
    static let totalBudget: TimeInterval = 16

    // MARK: - 判据

    /// 这一次「想要」哪一档。
    ///
    /// 逐字歌词开着 ⇒ 想要逐字（值得为它多等 `upgradeBudget`）；
    /// 关着 ⇒ 逐行就够（拿到就停，一个字节的时间都不多花）。
    static var wantedTier: LyricsTimingTier {
        wantsWordTiming ? .word : .line
    }

    static var wantsWordTiming: Bool {
        NgzhwmSettingsViewModel.isWordByWordLyricsEnabled
    }

    /// 这一份 dto 算哪一档。空行不在这里判（空行由调用方当成"没答上来"处理）。
    static func tier(of dto: LyricsDto) -> LyricsTimingTier {
        if hasUsableWordLevelData(dto) { return .word }
        if hasUsableLineLevelData(dto) { return .line }
        return .untimed
    }

    /// 候选比手里那份更好吗？**同档不算更好** —— 先问到的赢，链路顺序就是同档的优先级。
    static func isBetter(_ candidate: LyricsAutoSelectPick, than current: LyricsAutoSelectPick?) -> Bool {
        guard let current else { return true }
        return candidate.tier > current.tier
    }

    /// 可以收工了吗。
    ///
    /// 四条停止条件，按"越早越省时间"排：
    ///   1. 手里已经是「想要的那一档」→ 停（逐字开着时拿到逐字、关着时拿到逐行）；
    ///   2. 手里是逐行、而链路上**再没有能出逐字的源** → 停（没必要为纯文本白等）；
    ///   3. 手里是逐行、为升级已经等满 `upgradeBudget` → 停；
    ///   4. 整条链路 `totalBudget` 到点 → 停。
    ///
    /// ⚠️ 第 2、3 条**只对逐行生效**。手里还是纯文本时必须一路问到 `totalBudget` ——
    /// 否则「先答上来的是纯文本、后面才有带时间轴的源」这个正是要修的场景会被提前掐掉。
    static func shouldStop(
        best: LyricsAutoSelectPick?,
        elapsed: TimeInterval,
        remaining: [LyricsSource]
    ) -> Bool {
        guard let best else { return elapsed >= totalBudget }
        if best.tier >= wantedTier { return true }
        if best.tier == .line {
            if !remaining.contains(where: \.canProduceWordTiming) { return true }
            if elapsed >= upgradeBudget { return true }
        }
        return elapsed >= totalBudget
    }

    /// 这个源这一次最多等多久（调用方还要再和剩余总预算取小）。
    static func timeout(for source: LyricsSource) -> TimeInterval {
        switch source {
        case .lrclib, .amllTtml, .spicy:
            return fastSourceTimeout
        case .musixmatch, .petit, .netease, .genius, .appleMusicOfficialTtml,
             .bini, .unison, .qqMusic, .kugou:
            // 这四个新源每个都要**两个**请求（搜索 + 取词），酷狗还可能连试三条候选，
            // 所以一律按"慢源"给 5 秒。
            return slowSourceTimeout
        case .notReplaced, .autoSelect:
            return 0
        }
    }

    // MARK: - 链路

    /// 自动优选的链路 —— **就是用户在排序页里排的那一份**（`LyricsSourceOrder`）。
    ///
    /// ★ 2026-10-31（用户）：「我记得金牛座那边是不是可以自己排序歌词来源的？如果可以，
    ///   默认排序这样：amll - sl - pl - 网易云 - qq - 酷狗 - un - mxm - bini - gen」。
    ///   在那之前这里是写死的地区序（日本用户 Petit 起头、中文用户网易云起头）。
    ///   现在地区序退成**默认值**（`LyricsSourceOrder.defaultOrder`），用户可以改。
    ///
    /// ⚠️ 顺序**只影响"先问谁"**，不影响"谁赢"：质量档（逐字 > 逐行 > 纯文本）的判据
    ///   在 `isBetter` / `shouldStop` 里，与位置无关。所以用户把 LRCLIB 拖到第一位，
    ///   也不会让一份行级歌词顶掉后面某个源的逐字歌词 —— 它只会让链路先花 0.5 秒问一次。
    static func chain() -> [LyricsSource] {
        LyricsSourceOrder.current
    }

}

extension LyricsSource {
    /// 这个源**有没有能力**给出词级时间轴。
    ///
    /// 只用于「后面还有没有希望升级到逐字」这一个判断（`shouldStop` 第 2 条）。
    /// 说 true 不代表它一定给得出 —— 只是值得为它多等一会儿。
    var canProduceWordTiming: Bool {
        switch self {
        case .genius, .lrclib, .notReplaced, .autoSelect:
            // Genius 是纯文本；LRCLIB 只给行级；后两个不是具体来源。
            return false
        case .musixmatch, .petit, .netease, .spicy, .amllTtml, .appleMusicOfficialTtml,
             .bini, .unison, .kugou, .qqMusic:
            // MxM 的 richsync、Petit 的逐字档、网易云的 yrc、Spicy 的 syllable、
            // AMLL / Apple Music / BiniLyrics / Unison 的 TTML syllable、酷狗的 KRC、
            // QQ 的 QRC —— 都能给到词级。
            return true
        }
    }
}
