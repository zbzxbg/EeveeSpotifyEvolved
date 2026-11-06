import Foundation

// MARK: - AmllTtmlResult → LyricsDto
//
// ── 硬不变量
// 每一行的 `content` 必须严格等于该行 `words` 的 text 顺序拼接（trim 后）。
// LyricsWordByWord 的渲染是「把 words 拼成显示文本 + 按 range 上色」，
// 一旦两者不一致，高亮会整行错位（看起来像「逐词数据质量差」，其实是映射 bug）。
// 因此 x-translation / x-roman 这类 span 在解析阶段就已被抽走，绝不留在词序列里；
// 并且行 content 不是取自解析结果，而是**由词序列反推**，从构造上保证两者一致。
//
// ── 逐词覆盖率
// 渲染层的 hasUsableWordLevel 阈值是「≥50% 的行有 ≥2 个词」。低于阈值时保留行级时间轴、
// 丢弃全部词级数据，让 overlay 自然回退到原生歌词滚动 —— 这比丢掉整首歌划算。
//
// ── 官方罗马音（x-roman）
// TTML 自带的 x-roman 是人工校对的逐行罗马音，质量高于本地 toJapaneseRomaji。
// 采用与 NetEase romalrc 相同的既有路径：在 repository 层直接替换主行文本并标记
// .romanized，让本地罗马化链路整体跳过，保证 overlay 与原生歌词行看到同一份文本。
// 只在「确实是日语歌 + 用户开了日语罗马化开关 + 官方罗马音能覆盖过半行数」时才替换，
// 对不上就整体放弃，绝不做模糊贴靠。

enum AmllLyricsMapper {

    /// 渲染层判定「词级数据可用」的阈值，与 LyricsWordByWord.hasUsableWordLevel 保持一致。
    private static let wordLevelCoverageNumerator = 5
    private static let wordLevelCoverageDenominator = 10

    private static let japaneseRomanizationKey = "ngzhwm_japaneseRomanization"

    /// - Parameter authorUsername: `AmllSongItem.primaryAuthorUsername`（歌词主要贡献者的 GitHub
    /// 名）。**AMLL 仓库 README 明确希望下游展示歌词作者**，而这一路
    /// 以前**只把它打进日志**、没进署名 ⇒ 署名永远是裸的源名。
    /// - Parameter logTag: 日志前缀。默认 `AMLL`；Apple Music 官方 TTML 那条线传 `AMTTML`
    static func makeDto(
        _ parsed: AmllTtmlResult,
        authorUsername: String? = nil,
        logTag: String = "AMLL"
    ) -> LyricsDto {
        var lines: [LyricsLineDto] = []
        var translations: [String] = []

        // ── 逐行：先建主词序列，再挂上（独立的）背景人声
        var wordLines: [[LyricsWordDto]?] = []
        var backgroundVocals: [LyricsBackgroundVocalDto?] = []
        /// 官方罗马字，**与 `lines` 同序同长**（被丢弃的行不占位）—— 它是"正文上方那一行"，
        /// 不是正文。旧实现直接拿它替换 `content`，于是日文正文整个消失。
        var officialRomanizations: [String] = []
        for line in parsed.lines {
            let tokens = wordTokens(for: line, logTag: logTag)
            // 行文本直接用 primaryText（解析层保证它**不含** x-bg），
            // 与 wordTokens 的自检口径一致：主词的拼接结果 == primaryText。
            let content = line.primaryText
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            let background = backgroundVocalDto(for: line)

            // 主词与副唱都空的行才丢弃 —— 只有副唱的行要保留，
            // 否则会丢掉"纯副唱"那几行的内容。
            guard !trimmed.isEmpty || background != nil else {
                wordLines.append(nil)
                backgroundVocals.append(nil)
                continue
            }

            // 把 AMLL 自己给的**行结束时间**也带上（`<p end>`）。
            // 以前它只用来算 `lastLineEndMs` 打日志、进 DTO 就丢了。
            lines.append(
                LyricsLineDto(
                    content: trimmed,
                    offsetMs: line.offsetMs,
                    endOffsetMs: line.endMs,
                    words: nil
                )
            )
            translations.append(line.translation ?? "")
            officialRomanizations.append(
                (line.romanization ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
            wordLines.append(tokens)
            backgroundVocals.append(background)
        }

        guard !lines.isEmpty else {
            return LyricsDto(lines: [], timeSynced: true, romanization: .original)
        }

        // 背景人声与 words 一样，只有整体判定为「逐词可用」时才挂上去。
        for index in lines.indices {
            lines[index].backgroundVocal = backgroundVocals[index]
        }

        // ── 逐词覆盖率闸门
        let usableWordLines = wordLines.filter { ($0?.count ?? 0) >= 2 }.count
        let wordLevelUsable = usableWordLines * wordLevelCoverageDenominator
            >= lines.count * wordLevelCoverageNumerator

        if wordLevelUsable {
            for index in lines.indices {
                lines[index].words = wordLines[index]
            }
            writeDebugLog("[\(logTag)] word-level coverage \(usableWordLines)/\(lines.count) — keeping words")
        } else {
            writeDebugLog(
                "[\(logTag)] word-level coverage \(usableWordLines)/\(lines.count) below threshold — line-synced only"
            )
        }

        // ── 罗马化状态
        //
        // 官方罗马字（`x-roman` / 侧挂的 transliteration 轨）**只当"正文上方那一行"**：
        // `lines` 永远是原文（日文），罗马字进 `officialRomanizedLines`，显示层按行下标配对
        // （见 `LyricLinesAdapter.romanizedContentsForDisplay`）。
        //
        // ⚠️ 旧实现在这里把 `content` 换成罗马音、并把 `words` 清空 —— 表现是"开 AMLL 后
        // 日文正文变成一整屏罗马字、逐字高亮也没了"。这与网易云/酷狗/QQ 已经改掉的那条
        // 是同一个病，判据与那几家对齐：
        // · 开关关着 ⇒ 连官方那份都不存（与网易 `romalrc` 一样，"取用时按开关存"）；
        // · 覆盖过半才收（个别行缺 `x-roman` 可以接受，整首对不上就整份丢弃）；
        // · 收下时 `languageCode` 记成 ja，显示层据此挑日语那个罗马化开关。
        let contents = lines.map(\.content)
        var languageCode = contents.romanizationLanguageCode
        let romanization: LyricsRomanizationStatus = contents.canBeRomanized
            ? .canBeRomanized
            : .original
        var officialRomanizedLines: [String] = []

        if parsed.hasRomanization,
           UserDefaults.standard.bool(forKey: japaneseRomanizationKey),
           isJapanese(parsed: parsed, languageCode: languageCode) {
            // 行数对不上就不用（显示层按下标配对，错一行整份都会串）。
            let covered = officialRomanizations.filter { !$0.isEmpty }.count
            if officialRomanizations.count == lines.count, covered > 0, covered * 2 >= lines.count {
                officialRomanizedLines = officialRomanizations
                languageCode = "ja"
                writeDebugLog(
                    "[\(logTag)] kept official romanization for \(covered)/\(lines.count) line(s)"
                )
            } else if officialRomanizations.count != lines.count {
                writeDebugLog(
                    "[\(logTag)] official romanization line count mismatch"
                        + " (\(officialRomanizations.count) vs \(lines.count)) — discarded"
                )
            } else {
                writeDebugLog(
                    "[\(logTag)] official romanization covers only \(covered)/\(lines.count)"
                        + " line(s) — discarded"
                )
            }
        } else if parsed.hasRomanization {
            writeDebugLog(
                "[\(logTag)] official romanization present, but Japanese romanization is off"
                    + " or the song is not Japanese — keeping original"
            )
        }

        // ── 翻译层
        // 必须与主歌词行数完全一致（渲染层按行索引取），因此每行都占位（无翻译填空串）。
        // 官方罗马音只进 `officialRomanizedLines`，不碰 `lines`（行数与顺序都不变）⇒ 翻译索引依然有效。
        let translation = translations.contains { !$0.isEmpty }
            ? LyricsTranslationDto(
                languageCode: preferredTranslationLanguageCode(parsed) ?? languageCode ?? "zh",
                lines: translations
            )
            : nil

        // （歌词进播放器的时候也没有额外的歌词结构）：
        // 把**副唱行数**也打出来 —— 这一行以后就能直接回答"这首歌到底有没有 x-bg、
        // 数据有没有走到渲染层"，不用再靠猜（Starboy 那份 TTML 里有 16 处 `x-bg`）。
        let backgroundCount = lines.reduce(into: 0) { total, line in
            if line.backgroundVocal != nil { total += 1 }
        }
        writeDebugLog(
            "[\(logTag)] mapped \(lines.count) line(s), translation=\(translation == nil ? "none" : "yes"),"
                + " bg=\(backgroundCount), romanization=\(romanization)"
        )

        // ── 署名
        // （Q6 清点里的第 ① 条）：AMLL 的 README 明确希望下游**展示歌词作者**，
        // 而 `AmllSongItem.primaryAuthorUsername` 这一路**只进过日志** —— 显示出来的署名
        // 永远是裸的源名。这里的口径与 Spicy Lyrics 那条一致：
        // · `providerName`（短）留给听歌页歌手行 —— 仍是 "AMLL"（默认由 `CustomLyrics` 填源名）；
        // · `providerCredit`（长）进注入 payload 的 `providedBy` / 页脚 —— 带上作者。
        var credit = ""
        if let author = authorUsername?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            // ⚠️ 署名格式刻意固定成 "AMLL · @作者"（Apple Music 官方那条线不传作者 ⇒ 没有这一行）。
            credit = "AMLL · @\(author)"
            writeDebugLog("[\(logTag)] credited to community author @\(author)")
        }

        return LyricsDto(
            lines: lines,
            timeSynced: true,
            romanization: romanization,
            translation: translation,
            languageCode: languageCode,
            officialRomanizedLines: officialRomanizedLines,
            providerCredit: credit
        )
    }

    // MARK: - 词序列
    //
    // 主词序列（**不含**背景人声）。
    // 返回 nil 表示该行没有可用逐词数据（退回行级）。
    //
    // 背景人声（`ttm:role="x-bg"`）单独成行，不能合并成 `主词 (背景人声)` —— 理由是
    // 「渲染层是单列单行模型，表达不了行内子行」。现在渲染层用的 `SynchronizedLyricText`
    // 已经支持把副唱画成主歌下方的一小行，所以这里改为**分离**输出
    // （见 `backgroundVocalDto(for:)`）：
    // · 副唱与主词时间重叠 → 两者**同时**点亮，而不是顺序点亮
    // · 副唱里那些零时长 token（括号等）不再混进主词序列
    // —— 那正是「带括号的行整行降级为逐行」的根因
    private static func wordTokens(for line: AmllTtmlLine, logTag: String) -> [LyricsWordDto]? {
        var tokens: [LyricsWordDto] = []

        for syllable in line.syllables where !syllable.text.isEmpty {
            tokens.append(
                LyricsWordDto(
                    text: syllable.text,
                    startMs: syllable.startMs,
                    endMs: syllable.endMs
                )
            )
        }

        guard !tokens.isEmpty else { return nil }

        // 不变量自检：主词拼出来的文本必须与解析出的主词文本一致，否则宁可退回行级，
        // 也不要带着错位的词级数据去喂渲染层。
        let joined = tokens.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = line.primaryText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard joined == expected else {
            writeDebugLog(
                "[\(logTag)] content mismatch — tokens=\"\(joined.prefix(60))\" expected=\"\(expected.prefix(60))\" — dropping words for this line"
            )
            return nil
        }

        return tokens
    }

    /// 背景人声 → 独立 DTO。返回 nil 表示该行没有副唱。
    ///
    /// 原始音节直接顺序拼接（不额外插空格、不加括号）：解析层给出的音节文本里
    /// 已经包含词间空白，与主词序列的口径一致。
    ///
    /// （§A·24「副唱自己的译文」）：`translation` 一路带到渲染层 ——
    /// 解析层早就从 `x-bg` 内部的 `x-translation` 收下了（`AmllTtmlBackgroundVocal.translation`），
    /// 以前在这里丢掉 ⇒ 渲染层那行"副唱下面的小字译文"永远是空的。
    private static func backgroundVocalDto(
        for line: AmllTtmlLine
    ) -> LyricsBackgroundVocalDto? {
        guard let background = line.backgroundVocal else { return nil }

        let tokens = background.syllables
            .filter { !$0.text.isEmpty }
            .map {
                LyricsWordDto(
                    text: $0.text,
                    startMs: $0.startMs,
                    endMs: $0.endMs
                )
            }
        guard !tokens.isEmpty else { return nil }

        let dto = LyricsBackgroundVocalDto(
            syllables: tokens,
            isBeforePrimary: background.isBeforePrimary,
            translation: background.translation
        )
        return dto.isEmpty ? nil : dto
    }

    private static func isJapanese(parsed: AmllTtmlResult, languageCode: String?) -> Bool {
        if let language = parsed.language?.lowercased(), language.hasPrefix("ja") {
            return true
        }
        if languageCode == "ja" { return true }
        // 兜底：原文出现假名即认定日语（汉字归属有歧义，不作为依据）。
        return parsed.lines.contains { line in
            line.primaryText.unicodeScalars.contains { scalar in
                switch scalar.value {
                case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
                    return true
                default:
                    return false
                }
            }
        }
    }

    private static func preferredTranslationLanguageCode(_ parsed: AmllTtmlResult) -> String? {
        let languages = parsed.lines.compactMap { $0.translationLanguage }
        guard !languages.isEmpty else { return nil }

        let counts = languages.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        guard let dominant = counts.max(by: { $0.value < $1.value })?.key else { return nil }

        // 归一到短码：zh-Hans-CN → zh。
        let lowercased = dominant.lowercased()
        if lowercased.hasPrefix("zh") { return "zh" }
        if lowercased.hasPrefix("ja") { return "ja" }
        if lowercased.hasPrefix("ko") { return "ko" }
        if lowercased.hasPrefix("en") { return "en" }
        return dominant
    }
}
