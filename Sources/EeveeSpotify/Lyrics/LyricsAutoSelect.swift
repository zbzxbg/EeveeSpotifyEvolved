import Foundation

// MARK: - 自动优选（auto select）
//
// 排序依据两层，顺序不可颠倒：
//
// 1. **时间轴档次**（逐字 > 逐行 > 纯文本）永远先比。判据复用渲染层那两个
//    `hasUsableWordLevelData` / `hasUsableLineLevelData`（`WordByWordLyricsFacts.swift`），
//    口径只有一份 —— 否则会出现「优选认为是逐字、渲染层认为不是」。
// 2. **同档质量面**（`LyricsAutoSelectFacets`）：有没有译文、有没有官方罗马字、罗马字
//    是不是逐词的。同档里只认严格更多，一样多时按链路顺序。
//
// 链路顺序由用户自己排（`LyricsSourceOrder`），只决定「先问谁」，不决定「谁赢」。
//
// 两条硬规则：**纯文本不能终止查找**（否则「有没有歌词」会被最差的答案决定）；手里
// 已有逐行歌词时最多再等 `upgradeBudget` 秒 —— Spotify 的歌词卡片等这次响应才建
// （见 `LyricsResponseCache`）。
//
// ⚠️ 没有独立断言程序：`isBetter` / `shouldStop` 依赖的 `LyricsDto`、
//    `WordByWordLyricsFacts`、`NgzhwmSettingsViewModel` 都拖着 UIKit / SwiftUI，
//    编不进 `Tests/` 那种只编被测文件的程序。改动时逐条对照下面的不变量。

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

/// 同一时间轴档次内的**质量面**。
///
/// 只记"用户要、且这一份 dto 真的给了"的项组成的分（`score`）。三项地位相同：
/// 它们各自决定一块可见内容，没有证据说哪一项更重要，所以一项算一分。
struct LyricsAutoSelectFacets {
    /// 有能显示的译文（`LyricsDto.translation`）。
    var translation = false
    /// 有官方罗马字整行（`LyricsDto.officialRomanizedLines`，且长度对得上）。
    var officialRomanization = false
    /// 有官方**逐词**罗马字（`LyricsDto.officialRomanizedWordGroups`）——
    /// 这就是"罗马字那一行能跟着逐字亮"的来源。
    var wordLevelRomanization = false

    /// 0…3。同档比较只看它。
    var score: Int {
        var count = 0
        if translation { count += 1 }
        if officialRomanization { count += 1 }
        if wordLevelRomanization { count += 1 }
        return count
    }

    var isEmpty: Bool { score == 0 }
}

/// 自动优选保留下来的一份结果。
struct LyricsAutoSelectPick {
    let dto: LyricsDto
    /// **实际**给出这份歌词的源（不是"链路的第几跳"）。
    let source: LyricsSource
    let tier: LyricsTimingTier
    /// 从链路起跑到这份答案到手用了多久（秒）。只用于日志。
    let elapsed: TimeInterval

    /// 这一份 dto **实际**满足的质量面（只算用户要的那几项）。
    ///
    /// 用计算属性、不做存储字段：它就是 dto + 设置开关的函数，没有"到达时才知道"的信息；
    /// 这样 `CustomLyrics` 里那几个构造点一个都不用改。
    var facets: LyricsAutoSelectFacets { LyricsAutoSelect.facets(of: dto, source: source) }
}

enum LyricsAutoSelect {

    // MARK: - 预算
    //
    // 单个源的等待上限。分两档，沿用「多级回退」时期的值：
    // 只打一个接口的源（LRCLIB / AMLL / Spicy）3 秒足够；
    // 要先搜索再取词的源（MxM / Petit / 网易 / Genius）给 5 秒。
    //
    // ⚠️ Genius 不要设 3 秒，
    // 而同一场里它又有正常出词的例子 —— 3 秒那一档经常是"超时被跳过"而不是"被评估"。
    static let fastSourceTimeout: TimeInterval = 3
    static let slowSourceTimeout: TimeInterval = 5

    /// 手里已经有逐行歌词时，**还愿意为逐字多等多久**。
    ///
    /// 4 秒是个折中：链路前几跳的失败通常在 1~2 秒内返回，4 秒足够再问两三个源；
    /// 再长就会踩到「响应太晚，卡片建不出来」那条线（见文件头）。
    ///
    /// 同档质量面也复用这一个窗口（不新加预算）：拿到"想要的那一档"但质量面还缺时，
    /// 最多等到这里为止 —— 到点就交手里那份，与逐行升级逐字共用同一条线。
    static let upgradeBudget: TimeInterval = 4

    /// 整条链路的上限。Spotify 那次 `color-lyrics` 请求的预算是 18 秒
    /// （`LyricsResponseCache.firstAttemptBudget`），这里留 2 秒余量给序列化与投递。
    static let totalBudget: TimeInterval = 16

    // MARK: - 判据
    //
    // 这一次「想要」哪一档。
    //
    // 逐字歌词开着 ⇒ 想要逐字（值得为它多等 `upgradeBudget`）；
    // 关着 ⇒ 逐行就够（拿到就停，一个字节的时间都不多花）。
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

    // MARK: - 同档质量面
    //
    // 判据全部来自**显示层实际读的那批开关**，不是新发明的一套：
    //
    // · 译文：与 `AppleMusicLyricsOverlayView.showsTranslationNow` /
    //   `LyricsWordByWordOverlayView` 同一判据 —— 开关开着**且这一家在名单里**
    //   才算"用户不想要这份译文"（`hidesTranslationWhenToggled`）。
    //   机翻（`UserDefaults.lyricsAutoTranslate`）**不在这里判**：它在选定之后才跑，
    //   对"这一份源自己的译文值不值得选"没有影响。
    //
    // · 官方罗马字 / 逐词罗马字：与 `LyricLinesAdapter.isOfficialRomanizationEnabled(for:)`
    //   同一套键、同一套语言分支。那个函数是 private 且挂在显示层文件里，这里只能按同样的
    //   键名重写一遍；三颗键名（`ngzhwm_japaneseRomanization` / `_chineseRomanization`
    //   / `_koreanRomanization`）改一处必须两处一起改。
    //
    // ⚠️ 三条不变量（改动时逐条对照）：
    //   ① 档次优先：`isBetter` 先比 tier，facets 只在 tier 相同时参与；
    //   ② 同档同面 ⇒ 先到先用：`score` 必须**严格更大**才算更好；
    //   ③ 预算不变：facets 不新增长度，只复用 `upgradeBudget` / `totalBudget`。

    /// 这一家给的译文要不要参与比较。
    ///
    /// 「不展示部分歌词源的翻译」只隐藏名单里的那几家（`hidesTranslationWhenToggled`），
    /// 所以同一场比较里，被隐藏的那份译文**不该**再算成一个质量面 ——
    /// 否则自动优选会为了一个根本不会显示的东西多给分。
    static func wantsTranslation(for source: LyricsSource?) -> Bool {
        guard !NgzhwmSettingsViewModel.isHideLyricsTranslationEnabled else { return true }
        return !(source?.hidesTranslationWhenToggled ?? false)
    }

    /// 这门语言的官方罗马字开关开着吗（与 `LyricLinesAdapter` 同一条判据）。
    static func isOfficialRomanizationEnabled(for languageCode: String?) -> Bool {
        let defaults = UserDefaults.standard
        // 日语那条是网易 `romalrc` 路的既有判据（先判它、不看曲目语言），保持不动。
        if defaults.bool(forKey: "ngzhwm_japaneseRomanization") { return true }
        let code = (languageCode ?? "").lowercased()
        if code.hasPrefix("zh") { return defaults.bool(forKey: "ngzhwm_chineseRomanization") }
        if code.hasPrefix("ko") { return defaults.bool(forKey: "ngzhwm_koreanRomanization") }
        return false
    }

    /// 这一份 dto 会不会真的画出"罗马字那一行"。
    ///
    /// 不是 CJK 内容的歌，本地罗马化就是原文、官方罗马字也不存在（显示层按行比较
    /// "原文 == 罗马字"后不画那行），所以这三个面在那种歌上没有意义 ——
    /// 不挡掉的话，英文歌的每一次取词都会为一个永远补不上的面多等到窗口结束。
    static func romanizationIsRelevant(_ dto: LyricsDto) -> Bool {
        if dto.romanization != .original { return true }
        let code = (dto.languageCode ?? "").lowercased()
        return code.hasPrefix("ja") || code.hasPrefix("zh") || code.hasPrefix("ko")
    }

    /// 用户这一次"想要哪些面"。
    ///
    /// 罗马字那两半还要看这门语言的开头与这份内容能不能罗马化。
    /// 逐词罗马字另有一道**按档次**的上限：它要求这一份歌词有词级时间轴
    /// （`officialRomanizedWordGroups` 是按 `words` 挂的），行级 / 纯文本的候选
    /// **不可能**满足它。不封顶的话，行级候选永远会缺一项，同档比较就永远停不下来 ——
    /// 那一档明明已经拿满了它**能**拿到的面。
    static func wantedFacets(
        for dto: LyricsDto,
        source: LyricsSource? = nil
    ) -> LyricsAutoSelectFacets {
        var wanted = LyricsAutoSelectFacets()
        wanted.translation = wantsTranslation(for: source)
        let romanizationWanted = isOfficialRomanizationEnabled(for: dto.languageCode)
            && romanizationIsRelevant(dto)
        wanted.officialRomanization = romanizationWanted
        wanted.wordLevelRomanization = romanizationWanted && tier(of: dto) == .word
        return wanted
    }

    /// 这一份 dto **实际**满足的质量面（只算用户要的那几项）。
    ///
    /// 只算"要的"很重要：用户把译文关掉之后，一份带译文的歌词不该在同档比较里多得分。
    static func facets(of dto: LyricsDto, source: LyricsSource? = nil) -> LyricsAutoSelectFacets {
        let wanted = wantedFacets(for: dto, source: source)
        var present = LyricsAutoSelectFacets()
        present.translation = hasUsableTranslation(dto)
        present.officialRomanization = hasOfficialRomanization(dto)
        present.wordLevelRomanization = hasWordLevelRomanization(dto)

        var result = LyricsAutoSelectFacets()
        result.translation = wanted.translation && present.translation
        result.officialRomanization = wanted.officialRomanization && present.officialRomanization
        result.wordLevelRomanization = wanted.wordLevelRomanization && present.wordLevelRomanization
        return result
    }

    /// 用户想要、而这一份没给的面。
    static func missingFacets(of dto: LyricsDto, source: LyricsSource? = nil) -> LyricsAutoSelectFacets {
        let wanted = wantedFacets(for: dto, source: source)
        let present = facets(of: dto, source: source)
        var missing = LyricsAutoSelectFacets()
        missing.translation = wanted.translation && !present.translation
        missing.officialRomanization = wanted.officialRomanization && !present.officialRomanization
        missing.wordLevelRomanization = wanted.wordLevelRomanization && !present.wordLevelRomanization
        return missing
    }

    /// 译文"有且能显示"：至少一行非空。显示层按行下标逐行取，空串等于没有。
    static func hasUsableTranslation(_ dto: LyricsDto) -> Bool {
        guard let translation = dto.translation else { return false }
        return translation.lines.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 官方罗马字整行：长度必须与 `lines` 一致（显示层按下标配对，对不上不用），
    /// 且至少一行非空。
    static func hasOfficialRomanization(_ dto: LyricsDto) -> Bool {
        guard dto.officialRomanizedLines.count == dto.lines.count else { return false }
        return dto.officialRomanizedLines.contains {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// 官方逐词罗马字：至少有一行按"组数 == 词数"挂上了（`KrcText` 的闸）。
    /// 那一行就是罗马字那一行能逐字亮的依据。
    static func hasWordLevelRomanization(_ dto: LyricsDto) -> Bool {
        guard dto.officialRomanizedWordGroups.count == dto.lines.count else { return false }
        return dto.officialRomanizedWordGroups.contains { !$0.isEmpty }
    }

    /// 候选比手里那份更好吗？
    ///
    /// **先比时间轴档次**（逐字赢逐行、逐行赢纯文本，与质量面无关）；
    /// 同档才比质量面，而且**必须严格更多** —— 一样多时保持"先到先用"，
    /// 链路顺序就是同档的优先级。
    static func isBetter(_ candidate: LyricsAutoSelectPick, than current: LyricsAutoSelectPick?) -> Bool {
        logFacetsOnce(for: candidate.dto, source: candidate.source)
        guard let current else { return true }
        if candidate.tier != current.tier { return candidate.tier > current.tier }
        return candidate.facets.score > current.facets.score
    }

    /// 可以收工了吗。
    ///
    /// 四条停止条件，按"越早越省时间"排：
    /// 1. 手里已经是「想要的那一档」，且质量面**齐了** → 停（同档后面不可能更好）；
    ///    质量面没齐、且还在 `upgradeBudget` 之内 → 继续问；
    /// 2. 手里是逐行、而链路上**再没有能出逐字的源** → 停（没必要为纯文本白等）；
    /// 3. 手里是逐行、为升级已经等满 `upgradeBudget` → 停；
    /// 4. 整条链路 `totalBudget` 到点 → 停。
    ///
    /// ⚠️ 第 2、3 条**只对逐行生效**。手里还是纯文本时必须一路问到 `totalBudget` ——
    /// 否则「先答上来的是纯文本、后面才有带时间轴的源」这个正是要修的场景会被提前掐掉。
    ///
    /// ⚠️ 第 1 条的后半句是质量面唯一的"多等"来源：它**不新加任何长度**，
    /// 用的还是 `upgradeBudget`；质量面齐了的答案与改动前**同时**停（一个字节都不多等）。
    /// 这个窗口与「逐行升级逐字」共用同一个起点：**请求开始**（`elapsed` 由调用方从链路
    /// 起跑算起），不是"拿到答案之后再等 4 秒" —— 链路前面连问几个慢源时它可能已经过去。
    ///
    /// ⚠️ 这里刻意**不**用 `remaining` 去判"还有没有源能补这个面"：调用方传进来的
    /// `remaining` 是 `chain.dropFirst(index + 1)`，**不含即将要问的那一个源**
    /// （`CustomLyrics.autoSelectLyrics`）。按能力过滤会正好在"唯一能给逐词罗马字的源
    /// 就是当前这一个"（默认链路里的酷狗）时提前停住 —— 那是这个功能最要紧的场景。
    static func shouldStop(
        best: LyricsAutoSelectPick?,
        elapsed: TimeInterval,
        remaining: [LyricsSource]
    ) -> Bool {
        guard let best else { return elapsed >= totalBudget }

        if best.tier >= wantedTier {
            return missingFacets(of: best.dto).isEmpty || elapsed >= upgradeBudget
        }

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

    // MARK: - 质量面日志
    //
    // 一行，每次请求写一次。`isBetter` 每答上来一份就会被叫一次，每轮都写会把日志埋掉。
    // 谁开窗：`chain()` —— 链路每次都是从头算一份（`CustomLyrics.autoSelectLyrics`），
    // 那次调用就是"一次请求"。
    private static var facetVerdictLogged = false

    static func logFacetsOnce(for dto: LyricsDto, source: LyricsSource? = nil) {
        guard !facetVerdictLogged else { return }
        facetVerdictLogged = true

        let wanted = wantedFacets(for: dto, source: source)
        let present = facets(of: dto, source: source)
        let mark: (Bool) -> String = { $0 ? "Y" : "N" }
        writeDebugLog(
            "[AutoSelect] facets wanted: translation=\(mark(wanted.translation))"
                + " officialRomaji=\(mark(wanted.officialRomanization))"
                + " wordRomaji=\(mark(wanted.wordLevelRomanization))"
                + " (lang=\(dto.languageCode ?? "-"))"
                + " | first pick: trans=\(mark(present.translation))"
                + " romaji=\(mark(present.officialRomanization))"
                + " wordRomaji=\(mark(present.wordLevelRomanization))"
                + " -> \(present.score)/\(wanted.score)"
        )
    }

    // MARK: - 链路
    //
    // 自动优选的链路 —— **就是用户在排序页里排的那一份**（`LyricsSourceOrder`）。
    //
    // 「我记得金牛座那边是不是可以自己排序歌词来源的？如果可以，
    // 默认排序这样：amll - sl - pl - 网易云 - qq - 酷狗 - un - mxm - bini - gen」。
    // 在那之前这里是写死的地区序（日本用户 Petit 起头、中文用户网易云起头）。
    // 现在地区序退成**默认值**（`LyricsSourceOrder.defaultOrder`），用户可以改。
    //
    // ⚠️ 顺序**只影响"先问谁"**，不影响"谁赢"：质量档（逐字 > 逐行 > 纯文本）的判据
    // 在 `isBetter` / `shouldStop` 里，与位置无关。所以用户把 LRCLIB 拖到第一位，
    // 也不会让一份行级歌词顶掉后面某个源的逐字歌词 —— 它只会让链路先花 0.5 秒问一次。
    static func chain() -> [LyricsSource] {
        // 一次请求 = 一次 `chain()`：质量面那行日志在这里重新开窗。
        facetVerdictLogged = false
        return LyricsSourceOrder.current
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
