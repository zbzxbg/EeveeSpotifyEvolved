import Foundation

// MARK: - 自动优选（auto select）
//
// 排序依据三层，顺序不可颠倒：
//
// 1. **时间轴档次**（逐字 > 逐行 > 纯文本）永远先比。判据复用渲染层那两个
//    `hasUsableWordLevelData` / `hasUsableLineLevelData`（`WordByWordLyricsFacts.swift`），
//    口径只有一份 —— 否则会出现「优选认为是逐字、渲染层认为不是」。
// 2. **置信度**：同档里"对上的"（源用真实曲目 id / 时长闸门命中）赢过"猜的"
//    （AMLL 模糊搜索按歌名选中，见 `LyricsDto.isFuzzyMatch`）。
// 3. **同档质量面**（`LyricsAutoSelectFacets`）：译文、官方整行罗马字、官方逐词罗马字、
//    对唱分边、副唱，**按覆盖率**计分（不是布尔）。同档同置信度里只认严格更大；一样多时
//    按链路顺序。结构面只在候选真的带了时加分，不会让链路为它多等。
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

/// 同一时间轴档次内的**质量面**，按**覆盖率**计分（0…1）。
///
/// 旧的布尔口径只问"有没有"，于是只翻了一行的源和整首 51/51 的源打平。现在每一项都是
/// "这块可见内容覆盖了这一行的多少比例"：
/// · 译文 / 官方整行罗马字 / 官方逐词罗马字 —— 画在正文下面/上面的那几行字；
/// · 对唱分边（`agent`）—— 左右两边的排版结构（目前只有 TTML 源有）；
/// · 副唱（`backgroundVocal`）—— 主词上方/下方那一小行（只有 TTML 源会给）。
///
/// 权重都是 1：它们各自是一块独立的可见内容，没有证据说哪一块更重要。结构面是
/// **present-only**（不进 `wantedFacets`）：只给"这一份真的带了"的源加分，从不为它
/// 多等一个源 —— 没人能保证别的源里一定有对唱/副唱。
struct LyricsAutoSelectFacets {
    var translation = 0.0
    var officialRomanization = 0.0
    var wordLevelRomanization = 0.0
    var duetLayout = 0.0
    var backgroundVocals = 0.0

    /// 0…5。同档比较只看它（浮点求和，`isBetter` 里用 epsilon 比）。
    var score: Double {
        translation + officialRomanization + wordLevelRomanization + duetLayout + backgroundVocals
    }

    var isEmpty: Bool { score <= 0 }
}

/// 自动优选保留下来的一份结果。
struct LyricsAutoSelectPick {
    let dto: LyricsDto
    /// **实际**给出这份歌词的源（不是"链路的第几跳"）。
    let source: LyricsSource
    let tier: LyricsTimingTier
    /// 从链路起跑到这份答案到手用了多久（秒）。只用于日志。
    let elapsed: TimeInterval

    /// 这一份 dto **实际**满足的质量面（只算用户要的那几项；按覆盖率计分）。
    ///
    /// 用计算属性、不做存储字段：它就是 dto + 设置开关的函数，没有"到达时才知道"的信息；
    /// 这样 `CustomLyrics` 里那几个构造点一个都不用改。
    var facets: LyricsAutoSelectFacets { LyricsAutoSelect.facets(of: dto, source: source) }

    /// 这一份是"猜的"（模糊搜索按名字选中）还是"对上的"（源用真实曲目 id / 时长闸门命中）。
    /// 同档、同质量面时，"对上的"赢 —— 按名字猜中的那一份可能是另一个编曲。
    var isFuzzyMatch: Bool { dto.isFuzzyMatch }
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

    /// 手里只有一份**没被验证过的模糊命中**时，还愿意为"对上的那一份"多等多久。
    ///
    /// 这条是 `upgradeBudget` 之外**唯一**新增的窗口，只对这类模糊命中生效：按名字猜中的
    /// 那一份可能是同名不同编曲（对唱版 / 独唱版 / TV size），值得再问一两个源换一份
    /// 用真实曲目 id / 时长闸门命中的。模糊命中若被时长闸门验证过，就不带
    /// `isFuzzyMatch`，也不会走这个窗口；没开模糊搜索时它根本不存在。
    static let fuzzyVerificationBudget: TimeInterval = 8

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

    /// 「AMLL 优先」：AMLL 交出逐字歌词就收工，不再让后面的"同档质量面"把它换掉。
    ///
    /// 这个开关的语义是"先信 AMLL 的逐词歌词"，不是"参与打分"。默认开着，而来源选择器
    /// 默认是自动优选 —— 如果只在单源模式里生效，默认组合下这个开关等于不存在：同档的
    /// 酷狗会靠"逐词罗马字"这一项把 AMLL 换掉。自动优选与锁屏取词共用这一条判断，
    /// 各自的"逐词开关"由调用方叠加。
    static var prefersAmll: Bool {
        NgzhwmSettingsViewModel.isAmllPreferred
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
    // · 译文：与 `AppleMusicLyricsOverlayView.showsTranslationNow` 同一判据 ——
    //   只有"隐藏开关开着**且**这一家在名单里"时才不显示；其余情况都会显示，也都该参与
    //   比较。机翻（`UserDefaults.lyricsAutoTranslate`）不在这里判：它在选定之后才跑，
    //   对"这一份源自己的译文值不值得选"没有影响。
    //
    // · 官方罗马字 / 逐词罗马字：与 `LyricLinesAdapter.isOfficialRomanizationEnabled(for:)`
    //   同一套键、同一套语言分支。那个函数是 private 且挂在显示层文件里，这里只能按同样的
    //   键名重写一遍；三颗键名（`ngzhwm_japaneseRomanization` / `_chineseRomanization`
    //   / `_koreanRomanization`）改一处必须两处一起改。
    //
    // · 对唱分边 / 副唱：只按 dto 里真的带了这一列来算（present-only），不看开关；它们
    //   决定的是排版结构，不是可选行，别的源给不出来。
    //
    // ⚠️ 三条不变量（改动时逐条对照）：
    //   ① 档次优先：`isBetter` 先比 tier，facets 只在 tier 相同时参与；
    //   ② 同档同面 ⇒ 先到先用：`score` 必须**严格更大**才算更好（浮点用 epsilon 比）；
    //   ③ 预算不变：facets 不新增长度，只复用 `upgradeBudget` / `totalBudget`；结构面不
    //      进 `wantedFacets`，所以不会把等待窗口拖长。

    /// 这一家给的译文要不要参与比较。
    ///
    /// 与显示层同一条：隐藏开关开着、且这一家在名单里 ⇒ 译文不会显示，也**不该**算成一个
    /// 质量面。其余情况（开关关着 = 全都显示）都该算。
    static func wantsTranslation(for source: LyricsSource?) -> Bool {
        if NgzhwmSettingsViewModel.isHideLyricsTranslationEnabled,
           source?.hidesTranslationWhenToggled == true {
            return false
        }
        return true
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

    /// 用户这一次"想要哪些面"（1 = 想要）。结构面不进来（present-only）。
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
        wanted.translation = wantsTranslation(for: source) ? 1 : 0
        let romanizationWanted = isOfficialRomanizationEnabled(for: dto.languageCode)
            && romanizationIsRelevant(dto)
        wanted.officialRomanization = romanizationWanted ? 1 : 0
        wanted.wordLevelRomanization = romanizationWanted && tier(of: dto) == .word ? 1 : 0
        return wanted
    }

    /// 这一份 dto **实际**给出的质量面（覆盖率 0…1）。只保留用户要的那几项；
    /// 对唱 / 副唱是结构面，不受开关影响。
    static func facets(of dto: LyricsDto, source: LyricsSource? = nil) -> LyricsAutoSelectFacets {
        let wanted = wantedFacets(for: dto, source: source)
        var present = LyricsAutoSelectFacets()
        present.translation = translationCoverage(dto)
        present.officialRomanization = officialRomanizationCoverage(dto)
        present.wordLevelRomanization = wordLevelRomanizationCoverage(dto)
        present.duetLayout = duetLayoutCoverage(dto)
        present.backgroundVocals = backgroundVocalCoverage(dto)

        var result = LyricsAutoSelectFacets()
        result.translation = wanted.translation > 0 ? present.translation : 0
        result.officialRomanization = wanted.officialRomanization > 0
            ? present.officialRomanization
            : 0
        result.wordLevelRomanization = wanted.wordLevelRomanization > 0
            ? present.wordLevelRomanization
            : 0
        result.duetLayout = present.duetLayout
        result.backgroundVocals = present.backgroundVocals
        return result
    }

    /// 用户想要、而这一份**一行都没有**的面。结构面不参与（它们不进 `wantedFacets`）。
    ///
    /// 覆盖率大于 0 但不满也算"有"：这里只决定要不要为它继续等下一个源，不是打分。
    static func missingFacets(of dto: LyricsDto, source: LyricsSource? = nil) -> LyricsAutoSelectFacets {
        let wanted = wantedFacets(for: dto, source: source)
        let present = facets(of: dto, source: source)
        var missing = LyricsAutoSelectFacets()
        missing.translation = wanted.translation > 0 && present.translation <= 0 ? 1 : 0
        missing.officialRomanization = wanted.officialRomanization > 0
            && present.officialRomanization <= 0
            ? 1
            : 0
        missing.wordLevelRomanization = wanted.wordLevelRomanization > 0
            && present.wordLevelRomanization <= 0
            ? 1
            : 0
        return missing
    }

    /// 译文覆盖：非空译文行 / 歌词行数。显示层按行下标取，空串等于没有。
    static func translationCoverage(_ dto: LyricsDto) -> Double {
        guard let translation = dto.translation, !dto.lines.isEmpty else { return 0 }
        let visible = translation.lines.prefix(dto.lines.count)
        let filled = visible.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        return clampedCoverage(filled, of: dto.lines.count)
    }

    /// 官方整行罗马字覆盖：长度必须与 `lines` 一致（显示层按下标配对，对不上不用）。
    static func officialRomanizationCoverage(_ dto: LyricsDto) -> Double {
        guard dto.officialRomanizedLines.count == dto.lines.count else { return 0 }
        let filled = dto.officialRomanizedLines.filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }.count
        return clampedCoverage(filled, of: dto.lines.count)
    }

    /// 官方逐词罗马字覆盖：按"这一行有没有逐词组"计，不是按"每个词都有组"计。
    ///
    /// AMLL 的逐词组是从整行 x-roman 切出来的：一个分词覆盖多个音节时，文本挂在**第一个**
    /// 音节的组上，其余组是空串（拼起来仍等于官方整行）。按非空组数算会把这种行严重低估。
    static func wordLevelRomanizationCoverage(_ dto: LyricsDto) -> Double {
        guard dto.officialRomanizedWordGroups.count == dto.lines.count else { return 0 }
        let filled = dto.officialRomanizedWordGroups.filter { groups in
            groups.contains { !$0.isEmpty }
        }.count
        return clampedCoverage(filled, of: dto.lines.count)
    }

    /// 对唱分边：解析层真的把第二位排到了另一边（`isFlipped`）才计；覆盖率 = 带歌手
    /// 信息的行占比。只有 TTML 源会给这一列。
    static func duetLayoutCoverage(_ dto: LyricsDto) -> Double {
        guard !dto.lines.isEmpty,
              dto.lines.contains(where: { $0.agent?.isFlipped == true }) else { return 0 }
        let filled = dto.lines.filter { $0.agent != nil }.count
        return clampedCoverage(filled, of: dto.lines.count)
    }

    /// 副唱：带一条非空副唱的行占比。只有 TTML 源会给这一列。
    static func backgroundVocalCoverage(_ dto: LyricsDto) -> Double {
        guard !dto.lines.isEmpty else { return 0 }
        let filled = dto.lines.filter { line in
            guard let background = line.backgroundVocal else { return false }
            return !background.isEmpty
        }.count
        return clampedCoverage(filled, of: dto.lines.count)
    }

    /// 覆盖率统一夹到 0…1：调用方给的数组长度偶尔会比 `lines` 长，别让一项超过满分。
    private static func clampedCoverage(_ count: Int, of total: Int) -> Double {
        guard total > 0, count > 0 else { return 0 }
        return min(1, Double(count) / Double(total))
    }

    /// 一行紧凑的质量面账，给"kept / not better"日志用。
    static func coverageLog(for dto: LyricsDto, source: LyricsSource? = nil) -> String {
        let facets = facets(of: dto, source: source)
        return String(
            format: "%.2f (trans %.2f, romaji %.2f, word %.2f, duet %.2f, bg %.2f)",
            facets.score,
            facets.translation,
            facets.officialRomanization,
            facets.wordLevelRomanization,
            facets.duetLayout,
            facets.backgroundVocals
        )
    }

    /// 候选比手里那份更好吗？
    ///
    /// 顺序：**时间轴档次**（逐字赢逐行、逐行赢纯文本）→ **置信度**（对上的赢猜的）→
    /// 同档质量面（覆盖率之和）。质量面必须**严格更大** —— 一样多时保持"先到先用"，
    /// 链路顺序就是同档的优先级。浮点求和在 epsilon 以内视为相等，避免 1/3 这类
    /// 覆盖率把"同样多"算成"更好"。
    ///
    /// 置信度只放在"同档"里比：逐行的"对上的"不会顶掉逐字的"猜的"（那一刻仍然只有
    /// 逐字能给出逐词渲染）；但同样是逐字时，用真实曲目 id 命中的那一份必须赢过
    /// 按歌名猜中的那一份。
    static func isBetter(_ candidate: LyricsAutoSelectPick, than current: LyricsAutoSelectPick?) -> Bool {
        logFacetsOnce(for: candidate.dto, source: candidate.source)
        guard let current else { return true }
        if candidate.tier != current.tier { return candidate.tier > current.tier }
        if candidate.isFuzzyMatch != current.isFuzzyMatch { return !candidate.isFuzzyMatch }
        return candidate.facets.score > current.facets.score + 0.000_001
    }

    /// 可以收工了吗。
    ///
    /// 五条停止条件，按"越早越省时间"排：
    /// 1. 手里已经是「想要的那一档」，且质量面**齐了** → 停（同档后面不可能更好）；
    ///    质量面没齐、且还在 `upgradeBudget` 之内 → 继续问；
    /// 2. 手里那一份是**模糊命中**（按歌名猜的）→ 还有能出逐字的源就继续问到
    ///    `fuzzyVerificationBudget`：同档的"对上的"比"猜的"优先，值得多问一两个源；
    /// 3. 手里是逐行、而链路上**再没有能出逐字的源** → 停（没必要为纯文本白等）；
    /// 4. 手里是逐行、为升级已经等满 `upgradeBudget` → 停；
    /// 5. 整条链路 `totalBudget` 到点 → 停。
    ///
    /// ⚠️ 第 3、4 条**只对逐行生效**。手里还是纯文本时必须一路问到 `totalBudget` ——
    /// 否则「先答上来的是纯文本、后面才有带时间轴的源」这个正是要修的场景会被提前掐掉。
    ///
    /// ⚠️ 第 2 条是唯一在 `upgradeBudget` 之外新加的窗口，只对模糊命中生效（没开模糊
    /// 搜索时它根本走不到）。它不改变"质量面齐了就停"的老行为 —— 只让"猜的"多等一会儿。
    /// 窗口起点仍是**请求开始**（`elapsed` 由调用方从链路起跑算起）。
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
            // 猜中的那一份还值得再等一份"对上的"：即使质量面齐了也继续问。
            if best.isFuzzyMatch, remaining.contains(where: \.canProduceWordTiming) {
                return elapsed >= fuzzyVerificationBudget
            }
            return missingFacets(of: best.dto, source: best.source).isEmpty
                || elapsed >= upgradeBudget
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
        case .amllTtml:
            // 模糊搜索那条路最多三个请求（搜索 → 取词 → 版本校验），3 秒不够。
            // 精确那条路仍然按快源算。
            return UserDefaults.experimentsOptions.amllFuzzySearch
                ? slowSourceTimeout
                : fastSourceTimeout
        case .lrclib, .spicy:
            return fastSourceTimeout
        case .musixmatch, .petit, .netease, .genius, .appleMusicOfficialTtml,
             .bini, .unison, .qqMusic, .kugou:
            // 这四个新源每个都要**两个**请求（搜索 + 取词），酷狗还可能连试三条候选，
            // 所以一律按"慢源"给 5 秒。
            return slowSourceTimeout
        case .notReplaced, .autoSelect, .imported:
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
        let mark: (Double) -> String = { $0 > 0 ? "Y" : "N" }
        let coverage: (Double) -> String = { String(format: "%.2f", $0) }
        writeDebugLog(
            "[AutoSelect] facets wanted: translation=\(mark(wanted.translation))"
                + " officialRomaji=\(mark(wanted.officialRomanization))"
                + " wordRomaji=\(mark(wanted.wordLevelRomanization))"
                + " (lang=\(dto.languageCode ?? "-"))"
                + " | first pick: trans=\(coverage(present.translation))"
                + " romaji=\(coverage(present.officialRomanization))"
                + " wordRomaji=\(coverage(present.wordLevelRomanization))"
                + " duet=\(coverage(present.duetLayout))"
                + " bg=\(coverage(present.backgroundVocals))"
                + " -> \(coverage(present.score))/\(coverage(wanted.score))"
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
             .bini, .unison, .kugou, .qqMusic, .imported:
            // MxM 的 richsync、Petit 的逐字档、网易云的 yrc、Spicy 的 syllable、
            // AMLL / Apple Music / BiniLyrics / Unison 的 TTML syllable、酷狗的 KRC、
            // QQ 的 QRC —— 都能给到词级。
            return true
        }
    }
}
