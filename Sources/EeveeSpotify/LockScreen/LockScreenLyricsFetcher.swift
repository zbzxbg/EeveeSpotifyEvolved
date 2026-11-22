import Foundation

/// 给锁屏现取一份"带时间轴的行"。
///
/// 为什么不直接调 `CustomLyrics.loadCustomLyricsForCurrentTrack`：那条路会改全局的
/// `lyricsState`、弹"令牌无效"这类配置错误的窗，而且只在歌词页请求时才跑。锁屏要的是一份
/// 安静的数据 —— 给一个 `LyricsSearchQuery`，拿行；失败就返回 nil，界面退回动态封面。
///
/// 来源选择仍是用户自己那一套：`UserDefaults.lyricsSource` 选单源，`.autoSelect` 走
/// `LyricsAutoSelect.chain()` 的顺序。
///
/// 锁屏「逐字」关着时：谁先给出**行级时间轴**就用谁（一次都不多问）。
/// 开着时：先收一份行级的当**兜底**，再为**词级时间轴**继续问后面的源 —— 档次判据复用
/// 页内自动优选那一份（`LyricsAutoSelect.tier(of:)`），多花的时间也复用同一条预算
/// （`LyricsAutoSelect.upgradeBudget` / `fuzzyVerificationBudget`），不另立一套。
/// 「猜的」那一份（AMLL 模糊命中）同样只当兜底：同名可能是另一个编曲，
/// 继续问到"对上的"那一份为止。
enum LockScreenLyricsFetcher {

    struct Result {
        let lines: [LockScreenLyricLine]
        let source: LyricsSource
    }

    /// 同步执行（调用方负责放到后台队列）。`deadline` 是"整次取词"的预算：
    /// 每个源之间查一次，过了就不再问下一个。
    ///
    /// `onFallback` 在逐字开着、并且第一份行级结果到手时**立刻**回调一次（仍在调用方
    /// 的后台队列上）。同步取词没法"先返回再继续找"，而整条链找逐字要好几秒 —— 不回调
    /// 的话锁屏在每首歌开头都会空白这么久。调用方先把这份兜底装上，函数返回的最终
    /// 结果若升级成逐字档，再整体替换。
    static func lines(
        for query: LyricsSearchQuery,
        trackId: String,
        deadline: Date,
        onFallback: ((Result) -> Void)? = nil
    ) -> Result? {
        // 「实验 → 启用 Apple Music 官方 TTML 歌词」是**忽略其它所有歌词设置**的总覆盖
        // （见 `CustomLyrics.loadCustomLyricsForCurrentTrack` 顶部）：它连"禁用歌词替换"
        // 也压过去。锁屏这一层必须同样处理，否则开关打开后两边可能拿到不同的词。
        let officialOverride = UserDefaults.experimentsOptions.appleMusicOfficialTtml
        let setting = UserDefaults.lyricsSource
        if !officialOverride {
            guard setting.isReplacingLyrics else { return nil }
        }

        let candidates: [LyricsSource] = officialOverride
            ? [.appleMusicOfficialTtml]
            : (setting == .autoSelect ? LyricsAutoSelect.chain() : [setting])
        let options = UserDefaults.lyricsOptions

        // 锁屏这颗开关决定这一层要不要为词级时间轴继续问。页内那颗
        // `LyricsAutoSelect.wantsWordTiming` 只决定仓库层要不要保留 `words`
        // （Spicy / Petit / 网易 / MxM 按它裁剪），锁屏这边以 dto 的实际内容为准。
        let wantsWordTiming = UserDefaults.lockScreenWordByWord
        // 手里第一份可用的行级结果。逐字开着时它不一定是最终结果 —— 只是兜底。
        var fallback: Result?
        // 兜底是不是已经带逐字帧（模糊命中也可能带）。
        var fallbackIsWord = false
        // 兜底到手之后最多再问多久。起点是**兜底到手**那一刻，不是整次取词的起点：
        // 这里的每个源都是同步请求，没法像 `LyricsAutoSelect.autoSelectLyrics` 那样
        // 按剩余预算给单源夹超时 —— 从起跑算窗口的话，一个慢源就能在问到任何能出
        // 词级时间轴的源之前把窗口花光。
        var upgradeDeadline: Date?

        for (index, candidate) in candidates.enumerated() {
            guard Date() < deadline else {
                writeDebugLog("[\(LockScreenLyrics.logTag)] out of time before \(candidate.description)")
                break
            }
            if let upgradeDeadline, Date() >= upgradeDeadline {
                writeDebugLog(
                    "[\(LockScreenLyrics.logTag)] upgrade budget spent — keeping the line-timed fallback"
                )
                break
            }
            if fallback != nil,
               !candidates.dropFirst(index).contains(where: \.canProduceWordTiming) {
                // ⚠️ 从**当前这一个**算起（`dropFirst(index)`），不是从下一个：这一跳还没问，
                // 排除了它就会在"唯一能出词级时间轴的源正好排在这一位"时提前收工
                // （`LyricsAutoSelect.shouldStop` 的注释里记着同一个坑）。
                writeDebugLog(
                    "[\(LockScreenLyrics.logTag)] no word-capable source left —"
                        + " keeping the line-timed fallback"
                )
                break
            }

            let source = substituteIfNeeded(candidate)
            guard let repository = repository(for: source) else { continue }

            let started = Date()
            do {
                var dto = try repository.getLyrics(query, options: options)
                if LyricsTimingOffset.supportsOffset(source: source) {
                    dto = dto.applyingTimingOffset(
                        LyricsTimingOffset.offsetMs(forTrackId: trackId, source: source)
                    )
                }
                guard let lines = convert(dto, source: source) else {
                    writeDebugLog(
                        "[\(LockScreenLyrics.logTag)] \(source.description) gave no timed lines"
                            + " — \(took(started))"
                    )
                    continue
                }
                // 逐字关着 = 与改动前完全一致：第一个给出带时间轴行的源就是结果。
                if !wantsWordTiming {
                    writeDebugLog(
                        "[\(LockScreenLyrics.logTag)] \(lines.count) line(s) from"
                            + " \(source.description) — \(took(started))"
                    )
                    return Result(lines: lines, source: source)
                }

                let coverage = coverageLogSuffix(for: lines)
                // 「升级完成」要同时满足三条：dto 确实到了词级档（`tier(of:)`，与页内
                // auto-select 同一判据）、转换后的行真的带上了帧（词拼起来等于行文本，
                // 见 `LockScreenKaraoke.frames`）、而且这一份不是**猜的**。
                // 只有前两条时整首仍然是单帧；只有第三条命中时是同名不同编曲。
                let wordTimed = LyricsAutoSelect.tier(of: dto) == .word
                    && wordByWordLineCount(in: lines) > 0
                // 「AMLL 优先」对锁屏同样生效：AMLL 交出逐字就收工，不再问后面的源。
                if wordTimed, LyricsAutoSelect.prefersAmll, source == .amllTtml {
                    writeDebugLog(
                        "[\(LockScreenLyrics.logTag)] \(lines.count) line(s) from"
                            + " \(source.description) — \(took(started))\(coverage)"
                            + " — AMLL is preferred, stopping here"
                    )
                    return Result(lines: lines, source: source)
                }
                if wordTimed, !dto.isFuzzyMatch {
                    writeDebugLog(
                        "[\(LockScreenLyrics.logTag)] \(lines.count) line(s) from"
                            + " \(source.description) — \(took(started))\(coverage)"
                    )
                    return Result(lines: lines, source: source)
                }

                // 模糊命中（按名字猜的）先当兜底：它比行级好（能逐字），但同名可能是
                // 另一个编曲，继续问后面有没有用真实曲目 id / 时长闸门命中的那一份。
                if fallback == nil || (wordTimed && !fallbackIsWord) {
                    let result = Result(lines: lines, source: source)
                    fallback = result
                    fallbackIsWord = wordTimed
                    let budget = dto.isFuzzyMatch
                        ? LyricsAutoSelect.fuzzyVerificationBudget
                        : LyricsAutoSelect.upgradeBudget
                    upgradeDeadline = Date().addingTimeInterval(budget)
                    writeDebugLog(
                        "[\(LockScreenLyrics.logTag)] \(lines.count) line(s) from"
                            + " \(source.description) — \(took(started))\(coverage)"
                            + (wordTimed
                                ? " — fuzzy word-by-word fallback, still asking for a verified source"
                                : " — line-timed fallback, still asking for word-by-word")
                    )
                    // 先让锁屏有字：整条链找逐字可能要好几秒（见函数头注）。
                    onFallback?(result)
                } else {
                    writeDebugLog(
                        "[\(LockScreenLyrics.logTag)] \(source.description) gave no word-by-word"
                            + " — \(took(started))"
                    )
                }
            } catch {
                writeDebugLog(
                    "[\(LockScreenLyrics.logTag)] \(source.description) failed — \(error) (\(took(started)))"
                )
            }
        }

        if let fallback {
            writeDebugLog(
                "[\(LockScreenLyrics.logTag)] kept \(fallback.lines.count) line(s) from"
                    + " \(fallback.source.description)\(coverageLogSuffix(for: fallback.lines))"
                    + (fallbackIsWord
                        ? " — only a fuzzy word-by-word match, no verified source answered"
                        : " — no word-by-word data, single-frame lines")
            )
        }
        return fallback
    }

    /// 这一份行里有多少行真的带上了逐字帧（0 ⇒ 整首都会按单帧画）。
    private static func wordByWordLineCount(in lines: [LockScreenLyricLine]) -> Int {
        lines.reduce(0) { $0 + ($1.karaoke.isEmpty ? 0 : 1) }
    }

    /// 日志后缀：` (5/41 word-by-word)`。
    ///
    /// 逐字开关关着时为空串 —— 那时 `convert` 根本不建帧表，打一个 `0/41` 只会让人
    /// 误以为"取不到词级时间轴"。锁屏的两条日志（取词那行、升级那行）共用这一份格式。
    static func coverageLogSuffix(for lines: [LockScreenLyricLine]) -> String {
        guard UserDefaults.lockScreenWordByWord, !lines.isEmpty else { return "" }
        return " (\(wordByWordLineCount(in: lines))/\(lines.count) word-by-word)"
    }

    /// 内存里已经加载过这一首时直接转，不发网络请求。
    /// 只有 `currentLyricsDtoTrackId` 对得上才可信 —— 否则那是上一首的词。
    ///
    /// `source` 决定**要不要带译文**：与歌词页同一条规则（见 `showsTranslation`）。
    static func convert(_ dto: LyricsDto, source: LyricsSource?) -> [LockScreenLyricLine]? {
        guard dto.timeSynced, !dto.isInstrumental else { return nil }

        // 译文的配对口径必须与 `LyricLinesAdapter` 一致：按**"起点非空的行"排序后的位置**
        // 取 `translation.lines[index]`。所以先在完整列表上排序，再筛掉没有文字的行 ——
        // 反过来（先筛再排序）会让带空白行的歌整体错位一句。
        let ordered = dto.lines.enumerated()
            .filter { $0.element.offsetMs != nil }
            .sorted { ($0.element.offsetMs ?? 0) < ($1.element.offsetMs ?? 0) }
        guard !ordered.isEmpty else { return nil }

        let translationLines = dto.translation?.lines ?? []
        let showsTranslation = showsTranslation(for: source)
        // 罗马字：与歌词页**同一份**（官方罗马字优先，否则按语言开关本地罗马化）。
        // 它按 `lines` 下标对齐，所以下面用 `pair.offset`（= 在 `dto.lines` 里的位置）取。
        let romanizations = dto.romanizedContentsForDisplay()
        // 对唱：只有 TTML 源会给歌手信息（解析层只在"恰好两位个人歌手"时才置 flipped），
        // 所以"整首至少有一行 flipped"就是"这是一首对唱"。
        let isDuet = dto.lines.contains { $0.agent?.isFlipped == true }

        var timed: [(start: Int, end: Int?, text: String, translation: String, romanization: String, flipped: Bool, karaoke: [LockScreenKaraokeFrame])] = []
        let wantsKaraoke = UserDefaults.lockScreenWordByWord
        for (index, pair) in ordered.enumerated() {
            let line = pair.element
            guard let start = line.offsetMs else { continue }
            let text = line.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let translation = showsTranslation && index < translationLines.count
                ? normalizedTranslation(translationLines[index], text: text)
                : ""
            let romanization = pair.offset < romanizations.count
                ? normalizedRomanization(romanizations[pair.offset], text: text)
                : ""
            // 逐字：词级时间轴 → 帧表；词拼起来和这行字不完全一样就给空（退回单帧）。
            let karaoke = wantsKaraoke
                ? (LockScreenKaraoke.frames(words: line.words ?? [], lineText: text) ?? [])
                : []
            timed.append((
                start,
                line.endOffsetMs,
                text,
                translation,
                romanization,
                line.agent?.isFlipped ?? false,
                karaoke
            ))
        }
        // 一行也算：有些歌整首只有一句词（念白/采样），不该被当成"没词"。
        guard !timed.isEmpty else { return nil }

        var lines: [LockScreenLyricLine] = []
        lines.reserveCapacity(timed.count)
        for (index, item) in timed.enumerated() {
            let nextStart = index + 1 < timed.count ? timed[index + 1].start : nil
            // 源给了"唱完的时刻"就用它（AMLL 的 `<p end>`）；没有就退回下一行的起点。
            let end = item.end ?? nextStart ?? (item.start + LockScreenLyrics.breakMs)
            lines.append(
                LockScreenLyricLine(
                    startMs: item.start,
                    endMs: max(end, item.start),
                    text: item.text,
                    translation: item.translation,
                    romanization: item.romanization,
                    isDuet: isDuet,
                    agentFlipped: item.flipped,
                    karaoke: item.karaoke
                )
            )
        }
        return lines
    }

    /// 锁屏这一行要不要带译文 —— 与歌词页的 `showsTranslationNow` 同一条规则：
    /// · 「用系统翻译」开着时歌词页会自己补译文，锁屏照常显示源给的译文；
    /// · 「隐藏部分歌词源的翻译」开着时，AMLL / 网易云 / QQ / 酷狗 那几家不下发译文行。
    private static func showsTranslation(for source: LyricsSource?) -> Bool {
        if UserDefaults.lyricsAutoTranslate { return true }
        guard let source else { return true }
        if NgzhwmSettingsViewModel.isHideLyricsTranslationEnabled,
           source.hidesTranslationWhenToggled {
            return false
        }
        return true
    }

    /// 译文与正文完全一样时不画（AMLL 的英文歌 x-translation 常常就是原文）。
    private static func normalizedTranslation(_ raw: String, text: String) -> String {
        let translation = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translation.isEmpty else { return "" }
        guard translation.compare(text, options: .caseInsensitive) != .orderedSame else {
            return ""
        }
        return translation
    }

    /// 罗马字与正文完全一样时不画：英文/拉丁行的"罗马化"就是它自己，
    /// 画上去只是一行重复（歌词页那边同一条判据，见 `LyricLinesAdapter.romanization`）。
    private static func normalizedRomanization(_ raw: String, text: String) -> String {
        let romanization = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !romanization.isEmpty else { return "" }
        guard romanization.compare(text, options: .caseInsensitive) != .orderedSame else {
            return ""
        }
        return romanization
    }

    // MARK: - 来源

    /// 没填 Spicy Lyrics 密钥时用 Musixmatch 顶上（与歌词页那条路一致：
    /// 不走被条款禁止的内部接口）。
    private static func substituteIfNeeded(_ source: LyricsSource) -> LyricsSource {
        if source == .spicy, !UserDefaults.hasSpicyLyricsApiKey {
            return .musixmatch
        }
        return source
    }

    /// 与 `CustomLyrics` 里那份映射同义。那边是 fileprivate，这里是锁屏自己的入口。
    private static func repository(for source: LyricsSource) -> LyricsRepository? {
        switch source {
        case .genius: return GeniusLyricsRepository()
        case .lrclib: return LrclibLyricsRepository.shared
        case .musixmatch: return MusixmatchLyricsRepository.shared
        case .petit: return PetitLyricsRepository()
        case .spicy: return SpicyLyricsRepository.shared
        case .netease: return NeteaseLyricsRepository.shared
        case .amllTtml: return AmllTtmlLyricsRepository.shared
        case .bini: return BiniLyricsRepository.shared
        case .unison: return UnisonLyricsRepository.shared
        case .qqMusic: return QQMusicLyricsRepository.shared
        case .kugou: return KuGouLyricsRepository.shared
        case .appleMusicOfficialTtml: return AppleMusicOfficialTtmlLyricsRepository.shared
        case .imported: return ImportedLyricsRepository.shared
        case .notReplaced, .autoSelect: return nil
        }
    }

    private static func took(_ started: Date) -> String {
        "\(Int(Date().timeIntervalSince(started) * 1000)) ms"
    }
}
