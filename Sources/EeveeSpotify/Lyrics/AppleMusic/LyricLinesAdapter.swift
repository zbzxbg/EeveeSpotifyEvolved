// 本项目新增（非 MeloX 移植件）：把仓库层现有的 `LyricsDto` 转成 MeloX 渲染层
// 消费的 `[LyricLine]`。
//
// 为什么不直接用 MeloX 的数据层：MeloX 的 `LyricsService` / `LyricsStore` /
// `LyricSourceMerger` 绑定它自己的取词与缓存体系，而本项目的 Repository 层已经
// 覆盖更多来源（网易 yrc / Musixmatch richsync / Spicy / AMLL / Petit / LRCLIB /
// Genius），没必要替换。这里只做模型适配。

import Foundation

// MARK: - 逐语言罗马化开关（"歌词页面里的选择"）

/// 三个逐语言罗马化开关的指纹。
///
/// **只此一份**：两处要用它 ——
///   · `LyricsDto.romanizedContentsForDisplay()` 的缓存键；
///   · `NowPlayingLyricsPlate` 判断"要不要把行模型重写一遍"（用户在设置里一改就该立刻生效）。
///
/// ⚠️ 2026-10-11 的教训就在隔壁（`seekToTappedLyricLine`）：**同一个判据抄两份 = 迟早只修一份**。
func romanizationSwitchesFingerprint() -> Int {
    var bits = 0
    if UserDefaults.standard.bool(forKey: "ngzhwm_japaneseRomanization") { bits |= 1 }
    if UserDefaults.standard.bool(forKey: "ngzhwm_chineseRomanization") { bits |= 2 }
    if UserDefaults.standard.bool(forKey: "ngzhwm_koreanRomanization") { bits |= 4 }
    // ★ 2026-10-12（用户新加的"展示歌词翻译/罗马化歌词"两颗总开关）：
    //   **译文那一档也进指纹** —— 理由与罗马字那三个完全一样：它只写 `UserDefaults`、
    //   不会让 `currentLyricsVersion` 变，而播放器那一层的宿主是按这个指纹决定要不要重建的
    //   （`NowPlayingLyricsHost.isCurrent`）⇒ 不进来的话，用户一拨开关要**等换歌**才看到效果
    //   （那就是一颗"哑开关"，正是用户这次要解决的那种体验）。
    if !NgzhwmSettingsViewModel.isNeteaseHideTranslationEnabled { bits |= 8 }
    // ★ 2026-10-12（用户新加的「未播放歌词行模糊化」）：**同一类开关，同一个理由** ——
    //   它也只写 `UserDefaults`、不让版本号变，不进来就得等换歌才生效（哑开关）。
    if UserDefaults.nowPlayingBlurUnplayedLyrics { bits |= 16 }
    return bits
}

// MARK: - 罗马化结果的小缓存

/// 缓存键：**歌词版本 + 三个开关**（换歌 / 改开关才会重算，见 `romanizedContentsForDisplay()`）。
private var romanizationCacheKey = ""
private var romanizationCache: [String] = []

extension LyricsDto {

    /// 给**显示层**用的逐行罗马化文本（与 `lines` 同序、同长度）。
    ///
    /// ⚠️ 这个函数每 0.3s 会被叫一次（`NowPlayingLyricsPlate.currentLines()` 那条复查节拍），
    /// 而罗马化（日文还要走分词）不便宜 ⇒ **带缓存**：
    ///   · 键 = `currentLyricsVersion` + `romanizationSwitchesFingerprint()`；
    ///   · 命中还要 `count == lines.count`（防串行）。
    func romanizedContentsForDisplay() -> [String] {
        // 键里除了版本与开关，还带上"行数 + 首行内容"：两个调用点（播放器那一层、全屏页）
        // 现在都用 `currentLyricsDto`，但**万一**将来有人拿一份别的 dto 进来，
        // 这两项能挡住"命中同一份缓存但内容不是它"的那种串行（`hashValue` 只在本进程内稳定，
        // 做缓存键足够）。
        let key = "\(currentLyricsVersion)-\(romanizationSwitchesFingerprint())"
            + "-\(lines.count)-\(lines.first?.content.hashValue ?? 0)"
        if key == romanizationCacheKey, romanizationCache.count == lines.count {
            return romanizationCache
        }

        // ★ 2026-10-12：**源给的官方罗马字优先**（网易 `romalrc`，见 `LyricsDto.officialRomanizedLines`）。
        //
        // 它以前是**替换正文**的（`NeteaseLyricsRepository` 直接改 `lines[i].content`）——
        // 那正是用户报的「直接把原日文替换了」。现在它只当"原文上方那一行"：
        // 正文永远是原文，这里返回的是罗马字那一层。
        //
        // ⚠️ 三个前提缺一不可：
        //   · 对应的语言开关开着（官方罗马字是取词时按"日语罗马化"存下来的，
        //     用户后来把开关关掉时必须跟着不显示 —— 缓存键里已经含这个开关）；
        //   · 长度与 `lines` 一致（按下标配对，对不上就不用）；
        //   · 官方有的那几行用官方，缺的那几行**退回本地转换**（官方罗马音常常不全，
        //     旧的 `preferLocalRomaji` 兜底逻辑就是为这个存在的）。
        if UserDefaults.standard.bool(forKey: "ngzhwm_japaneseRomanization"),
           !officialRomanizedLines.isEmpty,
           officialRomanizedLines.count == lines.count {
            // ★ 2026-10-12（用户）：「如果日语罗马字用的是**网易云自己做的**，首字母不会被大写」。
            //
            // 官方 `romalrc` 全是小写，而本地那条管线（`romanizedForWordByWordIfEnabled()`）会做
            // `capitalizingFirstLetterIfAlphabetic()`。两者显示的是**同一行**（原文上方那一行），
            // 大小写必须一致 —— 否则"换了官方罗马字"看起来就像少做了一步。
            // 这里只动**显示的那份**，主歌词与词级对齐都不受影响。
            let official = officialRomanizedLines.map { line -> String in
                line.isEmpty ? line : line.capitalizingFirstLetterIfAlphabetic()
            }
            var merged: [String]
            if official.contains(where: { $0.isEmpty }) {
                let local = romanizedForWordByWordIfEnabled().lines.map(\.content)
                merged = zip(official, local).map { pair in
                    pair.0.isEmpty ? pair.1 : pair.0
                }
            } else {
                merged = official
            }
            romanizationCacheKey = key
            romanizationCache = merged
            return merged
        }

        let fresh = romanizedForWordByWordIfEnabled().lines.map(\.content)
        romanizationCacheKey = key
        romanizationCache = fresh
        return fresh
    }
}

extension LyricsDto {

    /// 转成 Apple Music 风格渲染层使用的行模型。
    ///
    /// 时间语义：
    ///   - 有词级时间轴的行 → `.precise`，并给出 `duration`
    ///   - 只有行级时间的行 → `.lineSynchronized`，`duration` 取「下一行起始 − 本行起始」
    ///     （末行用 `LyricVocalDurationEstimator` 估算），供渲染层按需拆「伪逐字」
    func toAppleMusicLyricLines() -> [LyricLine] {
        // ★ 2026-10-11：**罗马字**（用户要的"主歌词上方那一行"）。
        //
        // 数据**不新造**：`romanizedForWordByWordIfEnabled()` 就是仓库里那条既有的罗马化管线 ——
        // 整首语言判定（`dominantCJKLanguageAbove`）+ 逐语言开关
        // （`ngzhwm_japaneseRomanization` / `_chineseRomanization` / `_koreanRomanization`，
        // 也就是"歌词页面里的选择"）+ 首字母大写。它返回的副本里 `content` 已是罗马化文本。
        //
        // ⚠️ 我们**只读它的 `content`**，主歌词仍用原文 ⇒ 两行都在（原文 + 上方罗马字）。
        // ⚠️ 索引要按**原数组**取：下面要按 offset 重排，用排序后的下标会串行。
        // ⚠️ 走 `romanizedContentsForDisplay()`（带缓存）—— 这个函数每 0.3s 会被叫一次。
        let romanizedContents = romanizedContentsForDisplay()

        let indexed = lines.enumerated()
            .filter { $0.element.offsetMs != nil }
            .sorted { ($0.element.offsetMs ?? 0) < ($1.element.offsetMs ?? 0) }

        guard !indexed.isEmpty else { return [] }

        let translationLines = translation?.lines ?? []

        return indexed.enumerated().map { index, pair in
            let line = pair.element
            let startMs = line.offsetMs ?? 0
            let startTime = TimeInterval(startMs) / 1000

            // 下一行的起点 → 本行的显示时长。末行没有下一行可用，退回估算。
            let nextStartTime: TimeInterval? = index + 1 < indexed.count
                ? TimeInterval(indexed[index + 1].element.offsetMs ?? startMs) / 1000
                : nil

            let syllables = Self.syllables(
                for: line,
                startTime: startTime,
                nextStartTime: nextStartTime
            )
            let isPrecise = !syllables.isEmpty

            let duration: TimeInterval?
            if isPrecise {
                // 精确行以作者标注的最后一个音节结束为准。
                duration = max((syllables.last?.endTime ?? startTime) - startTime, 0)
            } else if let nextStartTime {
                duration = max(nextStartTime - startTime, 0)
            } else {
                duration = LyricVocalDurationEstimator.estimatedDuration(for: line.content)
            }

            let translationText: String? = index < translationLines.count
                ? translationLines[index]
                : nil

            // 罗马字：和原文**不一样**才有（见 `romanization(original:romanized:)`）。
            let romanization = Self.romanization(
                original: line.content,
                romanized: pair.offset < romanizedContents.count
                    ? romanizedContents[pair.offset]
                    : nil
            )

            return LyricLine(
                id: Self.lineID(index: index, startMs: startMs),
                time: startTime,
                duration: duration,
                timingKind: isPrecise ? .precise : .lineSynchronized,
                // ★ 必须用 `line.content`，**不要**把 words 拼回来当行文本。
                //
                // 原因：SpicyLyrics 的解析器会给非首词补一个前导空格
                // （`SpicyLyricsRepository.swift` 里 `wordText = " " + syllableText`），
                // 而 `content` 已经是按同一规则拼好的。若这里再拼一次，文本就比
                // 逐字时间轴多出一批空格字符，填充前沿会整体漂移。
                // 用 content 才能保证「文本」与「音节时间轴」严格对应。
                text: line.content,
                syllables: syllables,
                romanization: romanization,
                romanizationSyllables: [],
                translation: Self.normalized(translationText),
                agent: nil,
                backgroundVocal: Self.backgroundVocal(for: line)
            )
        }
    }

    /// 罗马字那一行：和原文**不一样**才算有。
    ///
    /// 为什么要这条判据：`romanizedForWordByWordIfEnabled()` 会把整首歌都过一遍 ——
    /// 一首日文歌里的英文行（或本来就是拉丁字母的行）罗马化后就是它自己，
    /// 那种行再显示一遍罗马字纯属噪声、还白占一行高度。
    ///
    /// ★ 2026-10-04：比较改成**忽略大小写**。
    ///
    /// 为什么：`romanizedForWordByWordIfEnabled()` 顺手会把行首字母大写
    /// （`capitalizingFirstLetterIfAlphabetic()`，那是仓库的显示约定），而**原文**没有那一步。
    /// 于是 "i love you" 这种全小写的拉丁行会算成"罗马字与原文不同"⇒ 上面多出一行
    /// 只差一个字母大小写的"罗马字"（用户报的罗马化那一条修完之后才会露出来 ——
    /// 以前原文早就被整行替换成罗马字了，这一支根本走不到）。
    private static func romanization(original: String, romanized: String?) -> String? {
        guard let romanized else { return nil }
        let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRomanized = romanized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRomanized.isEmpty else { return nil }
        guard trimmedRomanized.compare(trimmedOriginal, options: .caseInsensitive) != .orderedSame else {
            return nil
        }
        return trimmedRomanized
    }

    /// 背景人声/副唱 → MeloX 的背景人声模型。
    ///
    /// 位置语义要把仓库层的 `isBeforePrimary` 翻成渲染层的
    /// `.beforePrimary` / `.afterPrimary` —— 名字一样但归属类型不同，别直接传。
    private static func backgroundVocal(
        for line: LyricsLineDto
    ) -> LyricBackgroundVocal? {
        guard let background = line.backgroundVocal,
              !background.isEmpty else { return nil }

        let syllables = background.syllables.compactMap { word -> LyricSyllable? in
            guard !word.text.isEmpty else { return nil }
            let start = TimeInterval(word.startMs) / 1000
            // 副唱允许零时长：括号之类的标记不该有填充动画。
            let end = word.endMs.map { TimeInterval($0) / 1000 } ?? start
            guard end >= start else { return nil }
            return LyricSyllable(text: word.text, startTime: start, endTime: end)
        }
        guard !syllables.isEmpty else { return nil }

        let text = background.text
        guard !text.isEmpty else { return nil }

        return LyricBackgroundVocal(
            time: syllables[0].startTime,
            duration: max(
                (syllables.last?.endTime ?? syllables[0].startTime)
                    - syllables[0].startTime,
                0
            ),
            text: text,
            syllables: syllables,
            translation: nil,
            position: background.isBeforePrimary
                ? .beforePrimary
                : .afterPrimary
        )
    }

    // MARK: - 私有

    /// 词级时间轴 → 音节数组。
    ///
    /// 只用**首尾都拿得到**的词构建：`endMs` 缺失的词会借用「下一个词的 startMs」，
    /// 借不到（末词）就用行时长兜底；两者都没有时返回空数组，
    /// 让调用方退回 `.lineSynchronized`（宁可整行同步，也不要编造时间轴）。
    private static func syllables(
        for line: LyricsLineDto,
        startTime: TimeInterval,
        nextStartTime: TimeInterval?
    ) -> [LyricSyllable] {
        guard let words = line.words, !words.isEmpty else { return [] }

        var result: [LyricSyllable] = []
        result.reserveCapacity(words.count)

        for (index, word) in words.enumerated() {
            // ⚠️ 这里**不能**跳过纯空白 token。
            //
            // 音节列表会被渲染层拼回行文本（`TimedLyricTextBuilder` 用
            // `syllables.map(\.text).joined()`），而 `line.content` 里那个空格是存在的。
            // 一旦这里把空格丢掉，后续所有词的字符区间都会**前移一位**，
            // 填充前沿就会整体错位。空白本身在渲染时会被跳过（渲染器只处理
            // 非空白 run），所以留着它没有任何副作用。
            guard !word.text.isEmpty else { continue }

            let wordStart = TimeInterval(word.startMs) / 1000

            let wordEnd: TimeInterval?
            if let endMs = word.endMs {
                wordEnd = TimeInterval(endMs) / 1000
            } else if index + 1 < words.count {
                wordEnd = TimeInterval(words[index + 1].startMs) / 1000
            } else {
                wordEnd = nextStartTime
            }

            guard let wordEnd, wordEnd >= wordStart else {
                // 时间戳反了（end < start）才是真坏数据，丢这一个词即可。
                //
                // 曾经这里写的是 `wordEnd > wordStart` 并把整行作废，结果是：
                // AMLL 故意给括号/间隔标记零时长，任何带背景人声的行都会整行
                // 退回行级（表现为「带括号的行不逐词」）。零时长在渲染上是安全的 ——
                // `LyricHighlightRevealProgress` 有 `guard duration > 0 else { return 1 }`，
                // 零时长音节会瞬间填满并保持，正是括号想要的静态效果。
                continue
            }

            result.append(
                LyricSyllable(
                    text: word.text,
                    startTime: wordStart,
                    endTime: wordEnd
                )
            )
        }

        // 至少要有一个**真正占时长**的音节才值得走精确时间轴；
        // 全零时长的行等价于行级，交给调用方退回。
        //
        // 曾经这里要求 count >= 2，于是「单字行」（比如独立一句 "ah"）也被降级成行级，
        // 那是没必要的：单字行同样能正常填充。
        guard result.contains(where: { $0.endTime > $0.startTime }) else {
            return []
        }
        return result
    }

    private static func lineID(index: Int, startMs: Int) -> String {
        "lyric-\(index)-\(startMs)"
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
