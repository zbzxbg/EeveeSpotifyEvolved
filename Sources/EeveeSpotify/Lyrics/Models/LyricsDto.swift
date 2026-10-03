import Foundation
import NaturalLanguage

/// 整首歌语言占比阈值：CJK 语言占比高于此值才按该语言统一罗马化。
private let romajiLanguageThreshold: Double = 0.5

struct LyricsDto {
    var lines: [LyricsLineDto]
    var timeSynced: Bool
    var romanization: LyricsRomanizationStatus
    var translation: LyricsTranslationDto? = nil
    var languageCode: String? = nil

    /// ★ 2026-10-11：**源明确说过"这一首是纯音乐"**。
    ///
    /// 为什么必须单开一个字段（而不是"行是空的"就当纯音乐）：
    /// 两份仓库注释都为此写过同一句话 —— *"不把上游『空歌词 → 纯音乐占位』的 bug 带过来"*
    /// （`NeteaseLyricsRepository` 的 `No usable lyrics` 分支、`GeniusLyricsRepository` 的
    /// `noSuchSong` 分支）。"查无此歌"与"这是纯音乐"在数据上**长得一样**（都是空行），
    /// 但对用户是两句话：**「未找到歌词」** vs **「此歌曲为纯音乐。」**
    ///
    /// 置位的地方只有两处，都是**源自己的可信分类**：
    ///   · 网易云 lrc 里带「纯音乐」（`NeteaseLyricsRepository`）；
    ///   · LRCLIB 的 `song.instrumental == true`（`LrclibLyricsRepository`）。
    var isInstrumental: Bool = false

    /// ★ 2026-10-12：**源给的官方罗马字**（网易的 `romalrc`），与 `lines` **同序、同长**。
    ///
    /// 为什么单开一个字段、而不再像以前那样直接改写 `lines[i].content`：
    /// 用户 2026-10-12 的判据是「罗马字要在**原文上方**，不许替换原文」。
    /// 官方那份罗马字的质量比本地转换好（分写是源自己做过的），所以**留着**，
    /// 但它只能当"上方那一行" —— 也就是 `romanizedContentsForDisplay()` 的**首选**来源；
    /// 主歌词始终是 `lines[i].content`（原文）。
    ///
    /// 空数组 ⇒ 显示层照旧自己算（`romanizedForWordByWordIfEnabled()`），与改动前一致。
    /// ⚠️ 长度必须等于 `lines.count`（显示层按下标配对）；对不上的那份**不许**用。
    var officialRomanizedLines: [String] = []
    /// 这份歌词**实际**是谁给的（形如 `"PetitLyrics"`）。
    ///
    /// ★ 2026-10-11：**不再带 `(EeveeSpotify)` 后缀**（用户：「这个就不需要写 eveespotify
    /// 的水印了」）。这串会同时进我们自己的页脚 / 歌手那一行、以及注入 payload 的 `providedBy`。
    ///
    /// 由 `CustomLyrics.storeLyricsDto(_:source:)` 在拿到数据的同一刻写入，
    /// 也就是"提供者"与"正在渲染的那份 dto"永远同源。以前提供者是另一个全局
    /// （`currentLyricsProvider`），在取词函数的**末尾**才写，而 dto 是中途就写好的，
    /// 于是出现两种可见错误：
    ///   · 旧 overlay 在 `rebuild()` 里读到的还是上一首的提供者（永远慢一拍）；
    ///   · Genius 兜底成功时，标签写的是"用户设的那个源"而不是真正给词的 Genius。
    ///
    /// 有默认值，所以各 repository 既有的
    /// `LyricsDto(lines:timeSynced:romanization:…)` 构造方式不受影响。
    var providerName: String = ""
    
    func toSpotifyLyricsData(
        source: String,
        useInstrumentalPlaceholder: Bool = true
    ) -> LyricsData {
        // ── 不再给"没有时间轴的源"合成时间轴（2026-09-27 删除）──────────────────
        //
        // 这里曾经把 Genius 这类纯文本源（`timeSynced: false`）按曲目时长铺一层估算的
        // 行级时间轴，理由是"9.1.x 把无时间轴的 payload 判为不可用"。
        //
        // 真机 A/B 结论（2026-09-27，用户关掉「补全歌词时间轴」跑了一整场）：
        // 观感"差不多或略好一点"；而且**给本来没有时间轴的源伪造时间轴本身就不合语义**
        // —— Genius 的页面就没有行时间，估算出来的 offset 只会让整首都不准
        // （`SyntheticLyricTiming` 自己写着"位置不保证准确"）。
        // 所以这条兜底整体删除：源给什么就是什么，`timeSynchronized` 如实反映
        // "有没有真实 offset"。
        //
        // ⚠️ 唯一的例外是**占位文案**（`makeUnavailableLyrics`）—— 那里仍然补时间轴。
        // 那不是"某个源的时间轴"，而是"未找到歌词"这一行能不能显示出来的前提。

        // 有效行 = 原始行，或（空歌词 + 纯音乐占位时）那三行占位文案。
        let effectiveLines: [LyricsLineDto]
        if lines.isEmpty {
            effectiveLines = useInstrumentalPlaceholder
                ? [
                    LyricsLineDto(content: "song_is_instrumental".localized),
                    LyricsLineDto(content: "let_the_music_play".localized),
                    LyricsLineDto(content: "")
                ]
                : []
        } else {
            effectiveLines = lines
        }

        var lyricsData = LyricsData.with {
            // 有行、且每行都带 offset → 就是"同步歌词"，如实告诉 Spotify。
            $0.timeSynchronized = effectiveLines.contains { ($0.offsetMs ?? 0) > 0 }
            $0.restriction = .unrestricted
            // ★ 2026-10-11（用户）：「这个就不需要写 eveespotify 的水印了」。
            //
            // 以前这里写 `"\(source) (EeveeSpotify)"`，而 **Spotify 原生歌词页 / 卡片底部那一行
            // 是直接照 payload 的 `providedBy` 显示的** ⇒ 屏幕上就是那个水印。
            // 现在只写**源名**（`"NetEase"`）—— "词是哪来的"这条信息还在，品牌不写了。
            $0.providedBy = "\(source)"
        }
        
        if effectiveLines.isEmpty {
            // 没有行可画（且未启用纯音乐占位）—— 保持空 payload。
        }
        else {
            let sortedLines = effectiveLines.sorted { 
                ($0.offsetMs ?? 0) < ($1.offsetMs ?? 0)
            }
            // ★ 2026-10-11（用户）：**注入给 Spotify 的正文一律保持原文，不再罗马化**。
            //
            // 用户原话：「开启歌词内的日语歌词罗马化后，是直接把原日文替换了，不是在原文的
            // 上面展示罗马字」。以前这里在 `canRomanize` 时把每行交给
            // `romanizedIfEnabled(languageHint:songLanguage:)`，于是 Spotify 原生歌词页 /
            // 卡片拿到的正文就是罗马字 —— 日文原文在原生那页上等于被删掉了，而罗马字本该
            // 由**我们自己的渲染层**画在原文**上方**（`LyricLinesAdapter` 的
            // `LyricLine.romanization` → `SynchronizedLyricText` 上方那一行）。
            //
            // 现在的口径（用户定的）：原生那页回到原文，罗马字只由我们这层画。
            // 数据来源没有变少：`LyricsDto` 里仍是无损原文，显示层照旧自己算罗马字
            // （`romanizedForWordByWordIfEnabled()` / `romanizedContentsForDisplay()`）。
            //
            // ⚠️ 随之删掉的是这里的整首歌语言占比检测（`dominantCJKLanguageAbove`）：
            // 它此前**只**用于给罗马化选语言，留着就是一段没有消费者的计算。
            lyricsData.lines = sortedLines.map { line in
                LyricsLine.with {
                    // 统一行首大写：无论来源/设置，行首第一个字母都大写；
                    // 仍会跳过「「 " ・ 空格」等装饰/隐形前缀，只大写其后的第一个字母。
                    // （这不是罗马化：日文/中文正文里没有可大写的拉丁字母时它是恒等变换，
                    //   而 `romanizedForWordByWordIfEnabled()` 对罗马字自己也会做同一步。）
                    $0.content = line.content.capitalizingFirstLetterIfAlphabetic()
                    $0.offsetMs = Int32(line.offsetMs ?? 0)
                }
            }
        }
        
        // 谁在画，谁负责译文（2026-09-25 定的口径）。
        //
        //   · **有逐词数据** → 我们自己画（AM 页 / 旧层卡拉OK）→ **不把译文交给 Spotify**。
        //     原因：Spotify 只要看到注入数据里有 translation，就会在「歌词」标题栏亮起
        //     它自己的翻译按钮（和分享/展开并排那个）。而我们那两套渲染器都不靠它显示译文
        //     （卡拉OK层自己画译文行），按钮点下去什么都不会变，纯属误导。
        //   · **没有逐词数据**（只有逐行 / 连时间轴都没有）→ 我们一层都不挂，
        //     整首交给 Spotify 原生那页/那张卡 → **把译文交给它**，让它自己的翻译按钮
        //     （真机对照图里的 文A）来管译文。这样原生页/原生卡的译文行为与官方歌词一致。
        //
        // ⚠️ 以前这里是 `!isBetterWordByWordLyricsEnabled`（看开关），
        // 于是"AM 开着 + 这首歌只有逐行"这种最常见的组合反而不给译文 ——
        // 原生卡上连翻译按钮都不出现（真机对照图 2 与图 3 的差别就是这个）。
        // 判据必须与 `WordByWordHost.attach` 的挂载判据一致：它挂了说明我们在画，
        // 它没挂说明是原生在画。
        //
        // 注意：这只影响**注入给 Spotify 的那份 protobuf**。`currentLyricsDto`
        // 里的 translation 仍然保留，所以旧层与老系统照常显示自己的译文。
        let suppliesTranslation = !hasUsableWordLevelData(self)

        if let translation = translation, suppliesTranslation {
            lyricsData.translation = LyricsTranslation.with {
                $0.languageCode = translation.languageCode
                $0.lines = translation.lines
            }
        }
        
        return lyricsData
    }
}

// MARK: - Per-line Language Routing

/// 按指定语言对单行做罗马化（查对应 user 开关；开关关则原样返回）。
private func romanizeLine(_ line: String, as language: NLLanguage) -> String {
    switch language {
    case .japanese:
        guard UserDefaults.standard.bool(forKey: "ngzhwm_japaneseRomanization") else { return line }
        return line.toJapaneseRomaji().capitalizingFirstLetterIfAlphabetic()
    case .simplifiedChinese, .traditionalChinese:
        guard UserDefaults.standard.bool(forKey: "ngzhwm_chineseRomanization") else { return line }
        return line.toChinesePinyin().capitalizingFirstLetterIfAlphabetic()
    case .korean:
        guard UserDefaults.standard.bool(forKey: "ngzhwm_koreanRomanization") else { return line }
        return line.toKoreanRomaja().capitalizingFirstLetterIfAlphabetic()
    default:
        return line
    }
}

extension String {
    /// 优先用整首歌占比检测出的语言（songLanguage，所有源统一），
    /// 否则回退到逐行识别（hint 前缀 → 含假名 → dominantLanguage）。
    func romanizedIfEnabled(languageHint: String? = nil, songLanguage: NLLanguage? = nil) -> String {
        if let songLanguage {
            return romanizeLine(self, as: songLanguage)
        }

        let normalizedHint = languageHint?.lowercased()
        let language: NLLanguage?

        if normalizedHint?.hasPrefix("ja") == true {
            language = .japanese
        } else if normalizedHint?.hasPrefix("ko") == true {
            language = .korean
        } else if normalizedHint?.hasPrefix("zh") == true {
            language = .simplifiedChinese
        } else if unicodeScalars.contains(where: { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
                return true
            default:
                return false
            }
        }) {
            language = .japanese
        } else {
            language = NLLanguageRecognizer.dominantLanguage(for: self)
        }

        guard let language else {
            return self
        }

        return romanizeLine(self, as: language)
    }
}

// MARK: - Japanese Romanization

/// 假名（平/片）→ 罗马字映射表。键为平假名码点；
/// 片假名在转换前归一为平假名（减 0x60），只有 ー/ヴ 等例外单独处理。
private let japaneseKanaMap: [UInt32: String] = [
    0x3042: "a", 0x3044: "i", 0x3046: "u", 0x3048: "e", 0x304A: "o",
    0x304B: "ka", 0x304D: "ki", 0x304F: "ku", 0x3051: "ke", 0x3053: "ko",
    0x304C: "ga", 0x304E: "gi", 0x3050: "gu", 0x3052: "ge", 0x3054: "go",
    0x3055: "sa", 0x3057: "shi", 0x3059: "su", 0x305B: "se", 0x305D: "so",
    0x3056: "za", 0x3058: "ji", 0x305A: "zu", 0x305C: "ze", 0x305E: "zo",
    0x305F: "ta", 0x3061: "chi", 0x3064: "tsu", 0x3066: "te", 0x3068: "to",
    0x3060: "da", 0x3062: "ji", 0x3065: "zu", 0x3067: "de", 0x3069: "do",
    0x306A: "na", 0x306B: "ni", 0x306C: "nu", 0x306D: "ne", 0x306E: "no",
    0x306F: "ha", 0x3072: "hi", 0x3075: "fu", 0x3078: "he", 0x307B: "ho",
    0x3070: "ba", 0x3073: "bi", 0x3076: "bu", 0x3079: "be", 0x307C: "bo",
    0x3071: "pa", 0x3074: "pi", 0x3077: "pu", 0x307A: "pe", 0x307D: "po",
    0x307E: "ma", 0x307F: "mi", 0x3080: "mu", 0x3081: "me", 0x3082: "mo",
    0x3084: "ya", 0x3086: "yu", 0x3088: "yo",
    0x3089: "ra", 0x308A: "ri", 0x308B: "ru", 0x308C: "re", 0x308D: "ro",
    0x308F: "wa", 0x3092: "wo", 0x3093: "n",
    0x3041: "a", 0x3043: "i", 0x3045: "u", 0x3047: "e", 0x3049: "o",
    0x3083: "ya", 0x3085: "yu", 0x3087: "yo", 0x308E: "wa", 0x3094: "vu"
]

/// 分写：这些 token（助词等）前面加空格。
private let japaneseParticles: Set<String> = [
    "は", "が", "を", "に", "へ", "と", "で", "も", "の", "や", "か",
    "から", "まで", "より", "だけ", "しか", "など", "ほど", "こそ", "でも",
    "って", "ね", "よ", "な", "ぞ", "ぜ", "わ", "さ", "けど", "けれど", "けれども"
]

/// 助词的特殊读音：は→wa、へ→e（を 的 wo 已在映射表里）。
private let japaneseParticleOverrides: [String: String] = [
    "は": "wa", "へ": "e"
]

/// 连写：这些活用后缀前面不加空格（黏到前一个词上）。
private let japaneseInflectionSuffixes: Set<String> = [
    "た", "て", "ない", "なく", "なかっ", "なけれ",
    "ます", "ました", "ません",
    "し", "せ", "たい", "たく", "そう", "よう", "う", "ず", "ぬ", "ば",
    "だっ", "ちゃっ", "じゃっ", "つつ", "ながら", "らしい", "みたい", "ほしい",
    "る", "れる", "られる", "せる", "させる"
]

/// 这些字符后面不再额外加空格（标点/括号等自带分隔）。
private let japaneseSpaceSeparators: Set<Character> = [
    "、", "。", "！", "？", "!", "?", ",", "，", ".", "．", "…",
    "「", "『", "（", "(", "【", "[", "」", "』", "）", ")", "】", "]",
    "・", "：", ":", "；", ";", "ー", "♪"
]

/// 片假名码点 → 平假名码点；非假名返回 nil。
private func japaneseHiraganaScalar(_ value: UInt32) -> UInt32? {
    if (0x3041...0x3096).contains(value) { return value }
    if (0x30A1...0x30F6).contains(value) { return value - 0x60 }
    return nil
}

/// 小假名 ゃゅょ 对应的元音（拗音用）。
private func japaneseSmallYouonVowel(_ hira: UInt32) -> String? {
    switch hira {
    case 0x3083: return "a"
    case 0x3085: return "u"
    case 0x3087: return "o"
    default: return nil
    }
}

/// 促音：把下一音节的辅音双写。
private func japaneseGeminated(_ romaji: String) -> String {
    guard let first = romaji.first else { return romaji }
    if romaji.hasPrefix("ch") { return "t" + romaji }
    if romaji.hasPrefix("sh") { return "s" + romaji }
    if romaji.hasPrefix("ts") { return "t" + romaji }
    if first.isLetter, !"aeiou".contains(first) {
        return String(first) + romaji
    }
    return romaji
}

/// 纯假名 token 的逐字罗马化。跨 token 的促音状态通过 pendingGeminate 传递。
private func japaneseKanaRomaji(_ text: String, pendingGeminate: inout Bool) -> String {
    let scalars = Array(text.unicodeScalars)
    var result = ""
    var i = 0

    while i < scalars.count {
        let value = scalars[i].value

        // 长音 ー：重复前一个元音（保持 ASCII，避免 macron 等怪字符）
        if value == 0x30FC {
            if let last = result.last, "aeiou".contains(last) {
                result.append(last)
            }
            i += 1
            continue
        }

        // 促音 っ/ッ：先记录，等下一个音节双写辅音
        if value == 0x3063 || value == 0x30C3 {
            pendingGeminate = true
            i += 1
            continue
        }

        guard let hira = japaneseHiraganaScalar(value),
              let base = japaneseKanaMap[hira] else {
            // 无法转写的字符（ゝ 等）原样保留
            result += String(UnicodeScalar(value)!)
            i += 1
            continue
        }

        var romaji = base

        // 拗音：i 段假名 + 小 ゃ/ゅ/ょ
        if base.count >= 2, base.hasSuffix("i"),
           i + 1 < scalars.count,
           let nextHira = japaneseHiraganaScalar(scalars[i + 1].value),
           let vowel = japaneseSmallYouonVowel(nextHira) {
            let stem = String(base.dropLast())
            if stem.hasSuffix("sh") || stem.hasSuffix("ch") || stem.hasSuffix("j") {
                romaji = stem + vowel
            } else {
                romaji = stem + "y" + vowel
            }
            i += 2
        } else {
            i += 1
        }

        if pendingGeminate {
            romaji = japaneseGeminated(romaji)
            pendingGeminate = false
        }

        result += romaji
    }

    return result
}

private func japaneseIsPureKana(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    return text.unicodeScalars.allSatisfy {
        (0x3040...0x309F).contains($0.value) || (0x30A0...0x30FF).contains($0.value)
    }
}

private func japaneseContainsPinyinMarker(_ text: String) -> Bool {
    for ch in text {
        if "áéíóúàèìòùǎěǐǒǔǖǘǚǜüńňǹḿ\u{0301}\u{0300}\u{030C}".contains(ch) {
            return true
        }
    }
    return false
}

/// 清洗 CFStringTokenizer 对含汉字 token 的转写：去掉促音产生的 "~"、
/// 把 "~tsu + 辅音" 修正为辅音双写、折叠内部空格。
private func japaneseSanitizeTranscription(_ text: String, original: String) -> String {
    var s = text
        .replacingOccurrences(of: "～", with: "~")
        .replacingOccurrences(of: "〜", with: "~")

    s = s.replacingOccurrences(of: "~tsu\\s*(ch)", with: "tch", options: .regularExpression)
    s = s.replacingOccurrences(of: "~tsu\\s*([kstnhmrgyzwbdpfjvc])", with: "$1$1", options: .regularExpression)
    s = s.replacingOccurrences(of: "~", with: "")

    // 附着在名词 token 末尾的助词：「私は」这类 tokenizer 没拆出来的 は/へ，
    // 转写以 ha/he 结尾时改读 wa/e，并保留助词前的空格。
    var particleSuffix: String? = nil
    if original.hasSuffix("は"), s.hasSuffix("ha") {
        s = String(s.dropLast(2)) + "wa"
        particleSuffix = "wa"
    } else if original.hasSuffix("へ"), s.hasSuffix("he") {
        s = String(s.dropLast(2)) + "e"
        particleSuffix = "e"
    }

    s = s.replacingOccurrences(of: " ", with: "")

    if let suffix = particleSuffix, s.hasSuffix(suffix) {
        s = String(s.dropLast(suffix.count)) + " " + suffix
    }

    return s
}

/// 归一化 token 之间的间隙：把全角空格（U+3000）等 Unicode 空白折叠成
/// 单个半角空格，标点等非空白字符原样保留。NetEase / Genius 的日文歌词里
/// 常把词间空格写成全角空格，直接透传会让罗马化输出出现“过宽”的空格。
private func japaneseNormalizedGap(_ gap: String) -> String {
    var result = ""
    var pendingSpace = false
    for ch in gap {
        if ch.isWhitespace || ch.isNewline {
            if !pendingSpace {
                result.append(" ")
                pendingSpace = true
            }
        } else {
            result.append(ch)
            pendingSpace = false
        }
    }
    return result
}

extension String {
    /// 把日语（假名+汉字）转为罗马字：
    /// - 假名部分用映射表逐字转换（正确处理促音/拗音/长音/拨音，无怪符号）；
    /// - 汉字部分用 CFStringTokenizer 取读音，遇到拼音回退时保留原文；
    /// - 分写按语法：助词前加空格，活用后缀黏连。
    func toJapaneseRomaji() -> String {
        guard !isEmpty else { return self }

        let cfText = self as CFString
        let length = CFStringGetLength(cfText)
        let locale = NSLocale(localeIdentifier: "ja") as CFLocale

        let options: CFOptionFlags = kCFStringTokenizerUnitWordBoundary
            | kCFStringTokenizerAttributeLatinTranscription

        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, cfText, CFRangeMake(0, length), options, locale
        )

        func substring(_ range: CFRange) -> String {
            guard range.length > 0,
                  let cf = CFStringCreateWithSubstring(kCFAllocatorDefault, cfText, range)
            else { return "" }
            return cf as String
        }

        var result = ""
        var cursor: CFIndex = 0
        var pendingGeminate = false
        var hasToken = false

        func appendGap(upTo location: CFIndex) {
            guard location > cursor else { return }
            result += japaneseNormalizedGap(substring(CFRangeMake(cursor, location - cursor)))
            cursor = location
        }

        func needsSpaceBeforeToken() -> Bool {
            guard hasToken, let last = result.last else { return false }
            if last.isWhitespace || last.isNewline { return false }
            if japaneseSpaceSeparators.contains(last) { return false }
            return true
        }

        func appendToken(_ romaji: String, original: String) {
            guard !romaji.isEmpty else { return }
            let glue = japaneseInflectionSuffixes.contains(original)
            if needsSpaceBeforeToken(), !glue {
                result += " "
            }
            result += romaji
            hasToken = true
        }

        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while !tokenType.isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            appendGap(upTo: range.location)

            let original = substring(range)

            // CFStringTokenizer 会把全角空格（U+3000）等空白当成独立 token 返回；
            // 空白本身无需罗马化，直接跳过，词间空格统一交给 appendToken 的语法分写。
            if original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cursor = range.location + range.length
                tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
                continue
            }

            var romaji: String
            if japaneseIsPureKana(original) {
                romaji = japaneseKanaRomaji(original, pendingGeminate: &pendingGeminate)
            } else {
                pendingGeminate = false
                if let transcription = CFStringTokenizerCopyCurrentTokenAttribute(
                    tokenizer, kCFStringTokenizerAttributeLatinTranscription
                ) as? String, !japaneseContainsPinyinMarker(transcription) {
                    romaji = japaneseSanitizeTranscription(transcription, original: original)
                } else {
                    romaji = original
                }
            }

            // 助词 は/へ 的特殊读音
            if japaneseParticles.contains(original) {
                romaji = japaneseParticleOverrides[original] ?? romaji
            }

            appendToken(romaji, original: original)

            cursor = range.location + range.length
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        appendGap(upTo: length)

        return result
    }

    /// 把行首第一个字母大写；「xxx」这类以开括号/引号/空白/零宽字符开头的行会跳过
    /// 这些装饰/隐形前缀，大写其后的第一个字母，其余字母保持原样。
    /// 其它非字母开头（省略号、数字、♪ 等）整行原样返回，避免误大写续行。
    func capitalizingFirstLetterIfAlphabetic() -> String {
        let leadingDecorations: Set<Character> = [
            // 开括号 / 引号 / 装饰符号
            "「", "『", "（", "(", "【", "[", "《", "〈", "〖", "〔", "〘", "«", "‹", "｢",
            "\"", "'", "`", "・", "･",
            // 空白与零宽/隐形字符
            " ", "\u{3000}", "\u{00A0}", "\u{2007}", "\u{202F}",
            "\u{200B}", "\u{FEFF}", "\u{200C}", "\u{200D}", "\u{2060}"
        ]
        var index = startIndex
        while index < endIndex, leadingDecorations.contains(self[index]) {
            index = self.index(after: index)
        }
        guard index < endIndex, self[index].isLetter else { return self }
        let afterLetter = self.index(after: index)
        return String(self[..<index])
            + String(self[index]).uppercased()
            + String(self[afterLetter...])
    }
}

// MARK: - 整行日文分词（供逐字对齐）

/// 整行日文分词的一个 chunk（token 或标点间隙）。
struct JapaneseRomajiChunk {
    var original: String
    var romaji: String
    var range: CFRange
    /// 在整行罗马字输出里，该 chunk 前面是否需要空格（与 toJapaneseRomaji 的规则一致）。
    var leadingSpace: Bool
}

extension String {
    /// 把整行日文按 CFStringTokenizer 分词，返回每个 token/间隙的（原文、罗马字、区间、前导空格）。
    /// 与 toJapaneseRomaji 共用同一套分词与助词逻辑，但保留逐 token 数据，供逐字对齐。
    func japaneseRomajiChunks() -> [JapaneseRomajiChunk] {
        guard !isEmpty else { return [] }
        let cfText = self as CFString
        let length = CFStringGetLength(cfText)
        let locale = NSLocale(localeIdentifier: "ja") as CFLocale
        let options: CFOptionFlags = kCFStringTokenizerUnitWordBoundary
            | kCFStringTokenizerAttributeLatinTranscription
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, cfText, CFRangeMake(0, length), options, locale
        )

        func substring(_ range: CFRange) -> String {
            guard range.length > 0,
                  let cf = CFStringCreateWithSubstring(kCFAllocatorDefault, cfText, range)
            else { return "" }
            return cf as String
        }

        var chunks: [JapaneseRomajiChunk] = []
        var cursor: CFIndex = 0
        var pendingGeminate = false
        var hasToken = false
        var lastOutputChar: Character?

        func addGap(_ range: CFRange) {
            guard range.length > 0 else { return }
            let gap = substring(range)
            let normalized = japaneseNormalizedGap(gap)
            chunks.append(JapaneseRomajiChunk(original: gap, romaji: normalized, range: range, leadingSpace: false))
            lastOutputChar = normalized.last
        }

        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while !tokenType.isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)

            addGap(CFRangeMake(cursor, range.location - cursor))

            let original = substring(range)

            // 同上：跳过 CFStringTokenizer 返回的纯空白 token（如全角空格 U+3000），
            // 避免空白以 token 形式进入 chunk 后被逐字对齐拼成多余空格。
            if original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cursor = range.location + range.length
                tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
                continue
            }

            var romaji: String
            if japaneseIsPureKana(original) {
                romaji = japaneseKanaRomaji(original, pendingGeminate: &pendingGeminate)
            } else {
                pendingGeminate = false
                if let transcription = CFStringTokenizerCopyCurrentTokenAttribute(
                    tokenizer, kCFStringTokenizerAttributeLatinTranscription
                ) as? String, !japaneseContainsPinyinMarker(transcription) {
                    romaji = japaneseSanitizeTranscription(transcription, original: original)
                } else {
                    romaji = original
                }
            }
            if japaneseParticles.contains(original) {
                romaji = japaneseParticleOverrides[original] ?? romaji
            }

            var leadingSpace = false
            if hasToken, let last = lastOutputChar,
               !last.isWhitespace, !last.isNewline,
               !japaneseSpaceSeparators.contains(last),
               !japaneseInflectionSuffixes.contains(original) {
                leadingSpace = true
            }

            if !romaji.isEmpty {
                chunks.append(JapaneseRomajiChunk(
                    original: original, romaji: romaji, range: range, leadingSpace: leadingSpace
                ))
                hasToken = true
                lastOutputChar = romaji.last
            }

            cursor = range.location + range.length
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        addGap(CFRangeMake(cursor, length - cursor))

        return chunks
    }
}

// MARK: - Chinese & Korean Romanization

extension String {
    /// 使用系统 ICU 转写引擎（Han-Latin）把中文（简/繁）转为带声调拼音。
    /// 中文不存在日语汉字那种多音字歧义问题（每行已经过 NLLanguageRecognizer
    /// 确认是中文），所以可以直接用系统的 .toLatin，不需要像日语那样自己分词。
    func toChinesePinyin() -> String {
        guard !isEmpty else { return self }
        return self.applyingTransform(.toLatin, reverse: false) ?? self
    }

    /// 使用系统 ICU 转写引擎把韩文谚文转为罗马字（Revised Romanization）。
    /// 谚文是表音文字，一个字符对应固定读音，没有多音字问题，
    /// 同样可以直接用系统的 .toLatin。
    func toKoreanRomaja() -> String {
        guard !isEmpty else { return self }
        return self.applyingTransform(.toLatin, reverse: false) ?? self
    }
}

// MARK: - 逐字 overlay 的罗马化

extension LyricsDto {
    /// 逐字歌词 + 对应语言罗马化开关都开启时，返回词/行文本罗马化的副本（供显示层取罗马字）。
    ///
    /// ⚠️ 2026-10-11 起：**这份副本只用来"取罗马字那一行"**，谁都不许把它当主歌词。
    ///   · `LyricLinesAdapter.toAppleMusicLyricLines` 只读它的 `content` 去和**原文**比，
    ///     不同才把罗马字挂到 `LyricLine.romanization`（画在原文上方）；
    ///   · `CustomLyrics.storeLyricsDto` 存的是**原样 dto**，不是这份副本 ——
    ///     以前存的是它，于是"原文"在渲染前就已经变成罗马字，用户看到的是
    ///     「直接替换原日文」而不是「原文上面一行罗马字」。
    ///   · 喂给 Spotify 原生那页的 payload（`toSpotifyLyricsData`）同样**不再**罗马化，
    ///     原生页回到原文（以前那句"toSpotifyLyricsData 自己会罗马化 content"已经作废）。
    func romanizedForWordByWordIfEnabled() -> LyricsDto {
        guard NgzhwmSettingsViewModel.isWordByWordLyricsEnabled,
              romanization == .canBeRomanized else { return self }

        // ── 首字母大写：**先做，且与罗马化开关无关** ──────────────────────────────
        //
        // ⚠️ 这里以前把大写和罗马化写在同一个循环里，并且上面那三个
        // `guard ...Romanization else { return self }` 会**整个函数提前返回** ——
        // 于是"用户把日语罗马化关掉"时，大写也一起被跳过，这一层显示的是
        // 网易云原始文本（全小写）。
        //
        // 而喂给 Spotify 的那份（`toSpotifyLyricsData` → `LyricsDto.swift` 第 72 行）
        // 是**无条件**做大写的。两边一对比就是用户看到的现象：
        // 原生那层首字母大写、我们这层小写，"首字母有不大写"。
        //
        // 大写本来就不属于"罗马化"：它是与原生一致的显示约定（`capitalizingFirst
        // LetterIfAlphabetic` 会跳过「」等装饰前缀与零宽字符）。所以拆出来先跑一遍，
        // 罗马化再在它之上按需进行 —— 两个开关互不牵连。
        var result = self
        for i in result.lines.indices {
            result.lines[i].content = result.lines[i].content.capitalizingFirstLetterIfAlphabetic()
        }

        let contentLines = result.lines.map(\.content)
        let language = contentLines.dominantCJKLanguageAbove(threshold: romajiLanguageThreshold)
        guard let language else {
            // 这首歌没有占主导的 CJK 语言 → 没有罗马化可做，但大写已经生效。
            return result
        }

        let romanize: (String) -> String
        let isJapanese: Bool
        switch language {
        case .japanese:
            guard UserDefaults.standard.bool(forKey: "ngzhwm_japaneseRomanization") else { return result }
            romanize = { $0.toJapaneseRomaji() }
            isJapanese = true
        case .simplifiedChinese, .traditionalChinese:
            guard UserDefaults.standard.bool(forKey: "ngzhwm_chineseRomanization") else { return result }
            romanize = { $0.toChinesePinyin() }
            isJapanese = false
        case .korean:
            guard UserDefaults.standard.bool(forKey: "ngzhwm_koreanRomanization") else { return result }
            romanize = { $0.toKoreanRomaja() }
            isJapanese = false
        default:
            return result
        }

        for i in result.lines.indices {
            let originalContent = result.lines[i].content
            // 整行罗马化 + 首字母大写（与原生行级一致）
            result.lines[i].content = romanize(originalContent)
                .capitalizingFirstLetterIfAlphabetic()

            guard let words = result.lines[i].words else { continue }

            // 日文：整行分词后对齐回计时词（上下文正确）；对齐失败回退逐词。
            // 中/韩：直接逐词（无上下文歧义）。
            var mapped: [LyricsWordDto]
            if isJapanese {
                mapped = Self.japaneseWordRomaji(lineContent: originalContent, words: words)
                if mapped.isEmpty {
                    mapped = Self.perWordRomaji(words: words, romanize: romanize)
                }
            } else {
                mapped = Self.perWordRomaji(words: words, romanize: romanize)
            }
            guard !mapped.isEmpty else { continue }

            // 词间空格：非首个词前补一个空格（罗马字词间需要空格）
            result.lines[i].words = mapped.enumerated().map { index, word in
                index == 0
                    ? word
                    : LyricsWordDto(text: " " + word.text, startMs: word.startMs, endMs: word.endMs)
            }
        }
        return result
    }

    /// 日文：整行 tokenize 后，把每个计时词对齐回它覆盖的 chunk，拼出上下文正确的罗马字。
    private static func japaneseWordRomaji(
        lineContent: String,
        words: [LyricsWordDto]
    ) -> [LyricsWordDto] {
        // 校验：词文本（含空格 token）拼接应等于行原文，否则放弃对齐
        let joined = words.reduce(into: "") { $0 += $1.text }
        guard joined == lineContent else { return [] }

        let chunks = lineContent.japaneseRomajiChunks()
        guard !chunks.isEmpty else { return [] }

        var chunkIndex = 0
        var position = 0
        var mapped: [LyricsWordDto] = []
        // 行首大写：跳过纯装饰词（如「、・），直到遇到含字母的词才真正大写，
        // 与非逐字 capitalizingFirstLetterIfAlphabetic 跳过装饰前缀的行为一致
        var hasCapitalized = false

        for word in words {
            let wLength = (word.text as NSString).length
            let wStart = position
            let wEnd = position + wLength
            position = wEnd

            let trimmed = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }  // 丢弃空格 token

            // 跳过已经结束的 chunk
            while chunkIndex < chunks.count,
                  chunks[chunkIndex].range.location + chunks[chunkIndex].range.length <= wStart {
                chunkIndex += 1
            }

            // 拼接覆盖 [wStart, wEnd) 的 chunks
            var romaji = ""
            while chunkIndex < chunks.count, chunks[chunkIndex].range.location < wEnd {
                let chunk = chunks[chunkIndex]
                if !romaji.isEmpty, chunk.leadingSpace {
                    romaji += " "
                }
                romaji += chunk.romaji
                chunkIndex += 1
            }

            // 去掉首尾空白：网易 yrc 把词间空格编码成前一词的尾随空格，
            // 会与上游给下一个词补的前导空格叠加成双空格；纯空白词（该词读音
            // 已被前一个词消耗、只剩间隙）直接丢弃。
            let stripped = romaji.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { continue }
            let text: String
            if !hasCapitalized {
                let candidate = stripped.capitalizingFirstLetterIfAlphabetic()
                hasCapitalized = candidate != stripped
                text = candidate
            } else {
                text = stripped
            }
            mapped.append(LyricsWordDto(text: text, startMs: word.startMs, endMs: word.endMs))
        }
        return mapped
    }

    /// 中/韩：逐词罗马化（无上下文歧义）；英文/标点/数字保持原样，首个词首字母大写。
    private static func perWordRomaji(
        words: [LyricsWordDto],
        romanize: (String) -> String
    ) -> [LyricsWordDto] {
        var mapped: [LyricsWordDto] = []
        var hasCapitalized = false
        for word in words {
            let trimmed = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let rom = Self.containsCJKText(trimmed) ? romanize(trimmed) : trimmed
            let text: String
            if !hasCapitalized {
                let candidate = rom.capitalizingFirstLetterIfAlphabetic()
                hasCapitalized = candidate != rom
                text = candidate
            } else {
                text = rom
            }
            mapped.append(LyricsWordDto(text: text, startMs: word.startMs, endMs: word.endMs))
        }
        return mapped
    }

    /// 是否含 CJK 文本（假名/汉字/韩文）；英文/标点/数字不含。
    private static func containsCJKText(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF,   // 平/片假名
                 0x3400...0x4DBF,   // CJK 扩展 A
                 0x4E00...0x9FFF,   // CJK 统一汉字
                 0xAC00...0xD7AF,   // 韩文谚文
                 0xF900...0xFAFF,   // CJK 兼容
                 0xFF66...0xFF9D:   // 半角片假名
                return true
            default:
                return false
            }
        }
    }
}
