import Foundation
import NaturalLanguage

/// 整首歌语言占比阈值：CJK 语言占比高于此值才按该语言统一罗马化。
let romajiLanguageThreshold: Double = 0.5

struct LyricsDto {
    var lines: [LyricsLineDto]
    var timeSynced: Bool
    var romanization: LyricsRomanizationStatus
    var translation: LyricsTranslationDto? = nil
    var languageCode: String? = nil

    /// **源明确说过"这一首是纯音乐"**。
    ///
    /// 为什么必须单开一个字段（而不是"行是空的"就当纯音乐）：
    /// 两份仓库注释都为此写过同一句话 —— *"不把上游『空歌词 → 纯音乐占位』的 bug 带过来"*
    /// （`NeteaseLyricsRepository` 的 `No usable lyrics` 分支、`GeniusLyricsRepository` 的
    /// `noSuchSong` 分支）。"查无此歌"与"这是纯音乐"在数据上**长得一样**（都是空行），
    /// 但对未找到歌词** vs **「此歌曲为纯音乐。」**
    ///
    /// 置位的地方只有两处，都是**源自己的可信分类**：
    /// · 网易云 lrc 里带「纯音乐」（`NeteaseLyricsRepository`）；
    /// · LRCLIB 的 `song.instrumental == true`（`LrclibLyricsRepository`）。
    var isInstrumental: Bool = false

    /// **源给的官方罗马字**（网易的 `romalrc`），与 `lines` **同序、同长**。
    ///
    /// 为什么单开一个字段、而不再像以前那样直接改写 `lines[i].content`：
    /// 罗马字要在**原文上方**，不许替换原文。
    /// 官方那份罗马字的质量比本地转换好（分写是源自己做过的），所以**留着**，
    /// 但它只能当"上方那一行" —— 也就是 `romanizedContentsForDisplay` 的**首选**来源；
    /// 主歌词始终是 `lines[i].content`（原文）。
    ///
    /// 空数组 ⇒ 显示层照旧自己算（`romanizedForWordByWordIfEnabled`），与改动前一致。
    /// ⚠️ 长度必须等于 `lines.count`（显示层按下标配对）；对不上的那份**不许**用。
    var officialRomanizedLines: [String] = []
    /// 这份歌词**实际**是谁给的（形如 `"PetitLyrics"`）。
    ///
    /// **不再带 `(EeveeSpotify)` 后缀**（这个就不需要写 eveespotify
    /// 的水印了）。这串会同时进我们自己的页脚 / 歌手那一行、以及注入 payload 的 `providedBy`。
    ///
    /// 由 `CustomLyrics.storeLyricsDto(_:source:)` 在拿到数据的同一刻写入，
    /// 也就是"提供者"与"正在渲染的那份 dto"永远同源。以前提供者是另一个全局
    /// （`currentLyricsProvider`），在取词函数的**末尾**才写，而 dto 是中途就写好的，
    /// 于是出现两种可见错误：
    /// · 旧 overlay 在 `rebuild` 里读到的还是上一首的提供者（永远慢一拍）；
    /// · Genius 兜底成功时，标签写的是"用户设的那个源"而不是真正给词的 Genius。
    ///
    /// 有默认值，所以各 repository 既有的
    /// `LyricsDto(lines:timeSynced:romanization:…)` 构造方式不受影响。
    var providerName: String = ""

    /// 完整署名（**含社区贡献者**），形如
    /// `"Spicy Lyrics · 制作者 X · 上传者 Y"`。空 ⇒ 退回 `providerName` / 源名。
    ///
    /// 为什么必须和 `providerName` 分开 —— Spicy Lyrics 的服务条款（§6）
    /// 要求"回答的 provider"与"社区同步的 uploader/maker"都要展示，而**展示位置不同**：
    /// · `providerName`（短）贴在听歌页**歌手那一行**（`NowPlayingLyricsPlate.providerSuffix`
    /// 会套一层全角括号），太长会把歌手名挤掉；
    /// · `providerCredit`（长）进**注入 payload 的 `providedBy`** —— 那是 Spotify 原生
    /// 歌词页/卡片底部那一行，有位置放得下。
    /// 两个都为空时才退回用户选的源名（`toSpotifyLyricsData(source:)`）。
    var providerCredit: String = ""

    /// 提供者自己的站点。只有能点的地方才用得上（现在是听歌页歌词区底沿那条署名）。
    var providerURL: URL? = nil

    /// 社区贡献者（Spicy Lyrics 的社区同步才有）。
    ///
    /// 与 `providerCredit` 的关系：`providerCredit` 是**纯文本**（进注入 payload 的
    /// `providedBy`，那一行点不动）；这个数组给**我们自己画的页面**用，
    /// 条款 §6 要求"用 contributor 的 `url` 当链接目标"就靠它。
    var providerContributors: [LyricsContributor] = []
    
    func toSpotifyLyricsData(
        source: String,
        useInstrumentalPlaceholder: Bool = true
    ) -> LyricsData {
        // ── 不再给"没有时间轴的源"合成时间轴删除）
        //
        // 这里曾经把 Genius 这类纯文本源（`timeSynced: false`）按曲目时长铺一层估算的
        // 行级时间轴，理由是"9.1.x 把无时间轴的 payload 判为不可用"。
        //
        // 真机 A/B 结论补全歌词时间轴跑了一整场）：
        // 观感"差不多或略好一点"；而且**给本来没有时间轴的源伪造时间轴本身就不合语义**
        // —— Genius 的页面就没有行时间，估算出来的 offset 只会让整首都不准
        // （`SyntheticLyricTiming` 自己写着"位置不保证准确"）。
        // 所以这条兜底整体删除：源给什么就是什么，`timeSynchronized` 如实反映
        // "有没有真实 offset"。
        //
        // ⚠️ 唯一的例外是**占位文案**（`makeUnavailableLyrics`）—— 那里仍然补时间轴。
        // 那不是"某个源的时间轴"，而是"未找到歌词"这一行能不能显示出来的前提。
        //
        // 有效行 = 原始行，或（空歌词 + 纯音乐占位时）那三行占位文案。
        //
        // **空白行不进 payload** —— Spotify 原生歌词页 / 卡片照 payload 的行
        // 逐行画，一行空内容在那里就是"一行空的"，与"漏了一句词"同形
        // （与用户在网易云 / Musixmatch 那两处拍板的间奏纪律同一条：
        // 空行照样占一行高度，该丢就丢）。
        // 判据与 `droppingBlankLinesForDisplay` **同一份**（`LyricsLineDto.isBlankForDisplay`）。
        //
        // ⚠️ 整份都是空白时**原样保留**：清成空数组会掉进下面 `lines.isEmpty` 那个
        // "纯音乐占位"分支，等于替源宣布"这首歌是纯音乐" —— 那正是 `isInstrumental`
        // 那段注释明令禁止的事（"查无此歌"与"这是纯音乐"必须分开）。
        // `blankFreeLineIndices` 给下面的译文层用：`lines` 与 `translation.lines`
        // 按下标一一对应，剔行必须**一起**剔。
        var blankFreeLineIndices: [Int]? = nil
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
            let keep = lines.indices.filter { !lines[$0].isBlankForDisplay }
            if keep.isEmpty || keep.count == lines.count {
                effectiveLines = lines
            } else {
                effectiveLines = keep.map { lines[$0] }
                blankFreeLineIndices = keep
            }
        }

        var lyricsData = LyricsData.with {
            // 有行、且每行都带 offset → 就是"同步歌词"，如实告诉 Spotify。
            $0.timeSynchronized = effectiveLines.contains { ($0.offsetMs ?? 0) > 0 }
            $0.restriction = .unrestricted
            // 「这个就不需要写 eveespotify 的水印了」。
            //
            // 以前这里写 `"\(source) (EeveeSpotify)"`，而 **Spotify 原生歌词页 / 卡片底部那一行
            // 是直接照 payload 的 `providedBy` 显示的** ⇒ 屏幕上就是那个水印。
            // 现在只写**源名**（`"NetEase"`）—— "词是哪来的"这条信息还在，品牌不写了。
            //
            // 有**完整署名**（含 Spicy Lyrics 社区同步的 uploader/maker）时
            // 优先用它 —— 条款 §6 要求这些人被署名，而原生那一行有位置。
            $0.providedBy = providerCredit.isEmpty ? "\(source)" : providerCredit
        }
        
        if effectiveLines.isEmpty {
            // 没有行可画（且未启用纯音乐占位）—— 保持空 payload。
        }
        else {
            let sortedLines = effectiveLines.sorted { 
                ($0.offsetMs ?? 0) < ($1.offsetMs ?? 0)
            }
            // **注入给 Spotify 的正文一律保持原文，不再罗马化**。
            //
            // 「开启歌词内的日语歌词罗马化后，是直接把原日文替换了，不是在原文的
            // 上面展示罗马字」。以前这里在 `canRomanize` 时把每行交给
            // `romanizedIfEnabled(languageHint:songLanguage:)`，于是 Spotify 原生歌词页 /
            // 卡片拿到的正文就是罗马字 —— 日文原文在原生那页上等于被删掉了，而罗马字本该
            // 由**我们自己的渲染层**画在原文**上方**（`LyricLinesAdapter` 的
            // `LyricLine.romanization` → `SynchronizedLyricText` 上方那一行）。
            //
            // 现在的口径（用户定的）：原生那页回到原文，罗马字只由我们这层画。
            // 数据来源没有变少：`LyricsDto` 里仍是无损原文，显示层照旧自己算罗马字
            // （`romanizedForWordByWordIfEnabled` / `romanizedContentsForDisplay`）。
            //
            // ⚠️ 随之删掉的是这里的整首歌语言占比检测（`dominantCJKLanguageAbove`）：
            // 它此前**只**用于给罗马化选语言，留着就是一段没有消费者的计算。
            lyricsData.lines = sortedLines.map { line in
                LyricsLine.with {
                    // 统一行首大写：无论来源/设置，行首第一个字母都大写；
                    // 仍会跳过「「 " ・ 空格」等装饰/隐形前缀，只大写其后的第一个字母。
                    // （这不是罗马化：日文/中文正文里没有可大写的拉丁字母时它是恒等变换，
                    // 而 `romanizedForWordByWordIfEnabled` 对罗马字自己也会做同一步。）
                    $0.content = line.content.capitalizingFirstLetterIfAlphabetic()
                    $0.offsetMs = Int32(line.offsetMs ?? 0)
                }
            }
        }
        
        // 谁在画，谁负责译文定的口径）。
        //
        // · **有逐词数据** → 我们自己画（AM 页 / 旧层卡拉OK）→ **不把译文交给 Spotify**。
        // 原因：Spotify 只要看到注入数据里有 translation，就会在「歌词」标题栏亮起
        // 它自己的翻译按钮（和分享/展开并排那个）。而我们那两套渲染器都不靠它显示译文
        // （卡拉OK层自己画译文行），按钮点下去什么都不会变，纯属误导。
        // · **没有逐词数据**（只有逐行 / 连时间轴都没有）→ 我们一层都不挂，
        // 整首交给 Spotify 原生那页/那张卡 → **把译文交给它**，让它自己的翻译按钮
        // （真机对照图里的 文A）来管译文。这样原生页/原生卡的译文行为与官方歌词一致。
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
            // 上面若剔过空白行，译文必须按**同一批下标**剔 ——
            // `lyricsData.lines` 与 `translation.lines` 是按下标一一对应的
            // （渲染层那一侧同理，见 `LyricLinesAdapter.toAppleMusicLyricLines`）。
            // 长度本来就没配对时不动它：那说明这份数据自己就没对齐，别替它猜。
            let translatedLines: [String]
            if let keep = blankFreeLineIndices, translation.lines.count == lines.count {
                translatedLines = keep.map { translation.lines[$0] }
            } else {
                translatedLines = translation.lines
            }
            lyricsData.translation = LyricsTranslation.with {
                $0.languageCode = translation.languageCode
                $0.lines = translatedLines
            }
        }
        
        return lyricsData
    }
}

// MARK: - Per-line Language Routing
//
// 按指定语言对单行做罗马化（查对应 user 开关；开关关则原样返回）。
func romanizeLine(_ line: String, as language: NLLanguage) -> String {
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

let japaneseKanaMap: [UInt32: String] = [
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
let japaneseParticles: Set<String> = [
    "は", "が", "を", "に", "へ", "と", "で", "も", "の", "や", "か",
    "から", "まで", "より", "だけ", "しか", "など", "ほど", "こそ", "でも",
    "って", "ね", "よ", "な", "ぞ", "ぜ", "わ", "さ", "けど", "けれど", "けれども"
]

/// 助词的特殊读音：は→wa、へ→e（を 的 wo 已在映射表里）。
let japaneseParticleOverrides: [String: String] = [
    "は": "wa", "へ": "e"
]

/// 连写：这些活用后缀前面不加空格（黏到前一个词上）。
let japaneseInflectionSuffixes: Set<String> = [
    "た", "て", "ない", "なく", "なかっ", "なけれ",
    "ます", "ました", "ません",
    "し", "せ", "たい", "たく", "そう", "よう", "う", "ず", "ぬ", "ば",
    "だっ", "ちゃっ", "じゃっ", "つつ", "ながら", "らしい", "みたい", "ほしい",
    "る", "れる", "られる", "せる", "させる"
]

/// 这些字符后面不再额外加空格（标点/括号等自带分隔）。
let japaneseSpaceSeparators: Set<Character> = [
    "、", "。", "！", "？", "!", "?", ",", "，", ".", "．", "…",
    "「", "『", "（", "(", "【", "[", "」", "』", "）", ")", "】", "]",
    "・", "：", ":", "；", ";", "ー", "♪"
]

/// 片假名码点 → 平假名码点；非假名返回 nil。
func japaneseHiraganaScalar(_ value: UInt32) -> UInt32? {
    if (0x3041...0x3096).contains(value) { return value }
    if (0x30A1...0x30F6).contains(value) { return value - 0x60 }
    return nil
}

/// 小假名 ゃゅょ 对应的元音（拗音用）。
func japaneseSmallYouonVowel(_ hira: UInt32) -> String? {
    switch hira {
    case 0x3083: return "a"
    case 0x3085: return "u"
    case 0x3087: return "o"
    default: return nil
    }
}

/// 促音：把下一音节的辅音双写。
func japaneseGeminated(_ romaji: String) -> String {
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
func japaneseKanaRomaji(_ text: String, pendingGeminate: inout Bool) -> String {
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

func japaneseIsPureKana(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    return text.unicodeScalars.allSatisfy {
        (0x3040...0x309F).contains($0.value) || (0x30A0...0x30FF).contains($0.value)
    }
}

func japaneseContainsPinyinMarker(_ text: String) -> Bool {
    for ch in text {
        if "áéíóúàèìòùǎěǐǒǔǖǘǚǜüńňǹḿ\u{0301}\u{0300}\u{030C}".contains(ch) {
            return true
        }
    }
    return false
}

/// 清洗 CFStringTokenizer 对含汉字 token 的转写：去掉促音产生的 "~"、
/// 把 "~tsu + 辅音" 修正为辅音双写、折叠内部空格。
func japaneseSanitizeTranscription(_ text: String, original: String) -> String {
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
func japaneseNormalizedGap(_ gap: String) -> String {
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

extension LyricsDto {

    /// **丢掉空白行**（判据：`LyricsLineDto.isBlankForDisplay`）。
    ///
    /// 为什么要有这一处：七个歌词仓库里**只有三个**自己筛过空行
    /// （`MusixmatchLyricsRepository` 的 `isMxmInterludeRow` 连带空行一起丢、
    /// `NeteaseLyricsRepository` 三条路各自 `.filter { !isInterludeRow(...) }`、
    /// `AmllTtmlParser` 的 `guard !line.primaryText.isEmpty`），
    /// `GeniusLyricsRepository` 只丢**首尾**空行（`LyricsMarkerFilter.mapLyricsLines`），
    /// 而 `PetitLyricsRepository` / `LrclibLyricsRepository` / `SpicyLyricsRepository`
    /// 是**原样**把上游的行搬进 dto 的。的现象就是
    /// 「PetitLyrics 返回的歌词里夹着空行」—— 与其在七个仓库里各写一遍，不如在 dto
    /// **落地**这一处筛一次（调用点见下面的 `capitalizingFirstLettersForDisplay`）。
    ///
    /// ⚠️ 与 `lines` **同序同长**的两份副本必须**一起**剔 —— 渲染层是按**原数组下标**
    /// 取译文与罗马字的（`LyricLinesAdapter.toAppleMusicLyricLines` 的
    /// `translationLines[index]`、`romanizedContentsForDisplay` 的
    /// `officialRomanizedLines[i]`），只删 `lines` 会让整份译文/罗马字错位一行。
    ///
    /// ⚠️ 只认**真正的空白**，`♪` 那类占位符不动（理由见 `LyricsLineDto.isBlankForDisplay`）。
    func droppingBlankLinesForDisplay() -> LyricsDto {
        let keep = lines.indices.filter { !lines[$0].isBlankForDisplay }
        // 没有空白行 ⇒ 原样返回（这是绝大多数歌的路径，别白拷一份数组）。
        guard keep.count != lines.count else { return self }

        var result = self
        result.lines = keep.map { lines[$0] }

        // 两份按下标对齐的副本：长度对不上就当它本来就没配对（渲染层同样会自己放弃）。
        if officialRomanizedLines.count == lines.count {
            result.officialRomanizedLines = keep.map { officialRomanizedLines[$0] }
        }
        if let translation, translation.lines.count == lines.count {
            result.translation = LyricsTranslationDto(
                languageCode: translation.languageCode,
                lines: keep.map { translation.lines[$0] }
            )
        }
        return result
    }

    /// 显示约定：**每行第一个字母大写**（`「` `"` `・` 空格 这类装饰前缀会被跳过，
    /// 规则见 `String.capitalizingFirstLetterIfAlphabetic`）——逐词行**连第一个含字母的词一起**，
    /// 这样逐词渲染与整行渲染长得一样。
    ///
    /// 「如果主歌词是英文这种字母，首字母或者「后面的首个字母是不是不会大写。
    /// 如果不会大写，改成大写」。
    ///
    /// 查过之后的**实情**：这条约定早就有，但只做在三个地方 ——
    /// ① 注入给 Spotify 的 payload（`toSpotifyLyricsData`）；
    /// ② 罗马字（`romanizeLine` 末尾那一句）；
    /// ③ 罗马化那份副本（`romanizedForWordByWordIfEnabled`，含词级 token）。
    /// **我们自己渲染层画的主歌词原文没做** ⇒ 同一首英文歌：Spotify 原生页首字母大写、
    /// 我们这层小写 —— 的就是这个。
    ///
    /// 现在补成"**DTO 落地时就统一**"：`CustomLyrics.storeLyricsDto` 调一次，之后
    /// 播放器那层 / 全屏页 / 旧 UIKit 层 / 静态歌词档读到的都是同一份。
    /// **幂等**：payload 与罗马字那两处会再做一次，结果不变（`…IfAlphabetic` 对已大写的串是恒等）。
    func capitalizingFirstLettersForDisplay() -> LyricsDto {
        // 先丢掉空白行，再统一大小写 —— 这一步是 dto 的**落地**入口
        // （`CustomLyrics.storeLyricsDto` 只在这里调一次），所以"筛空行"也挂在这里。
        // 两个动作都在本类型里，且都只动 dto 的**显示形态**，不碰任何仓库的取词逻辑。
        var result = droppingBlankLinesForDisplay()
        result.lines = result.lines.map { line in
            var line = line
            line.content = line.content.capitalizingFirstLetterIfAlphabetic()

            if let words = line.words, !words.isEmpty {
                var mapped: [LyricsWordDto] = []
                mapped.reserveCapacity(words.count)
                // 只大写**第一个含字母的 token**，然后就停。
                //
                // ⚠️ 判据是"这个 token 里有没有字母"，**不是**"这次调用有没有改动它" ——
                // 一个字都不能少（幂等性）：`「` 这类装饰常常是**独立 token**，
                // 若按"改动与否"判断，装饰 token 改不动 ⇒ 第二次跑时第一个词已是大写、
                // 也"改不动" ⇒ 会继续把**第二个**词也大写。按字母判断就没有这个洞。
                var hasPassedFirstLetter = false
                for word in words {
                    var word = word
                    if !hasPassedFirstLetter {
                        word.text = word.text.capitalizingFirstLetterIfAlphabetic()
                        if word.text.contains(where: { $0.isLetter }) {
                            hasPassedFirstLetter = true
                        }
                    }
                    mapped.append(word)
                }
                line.words = mapped
            }
            return line
        }
        return result
    }
}

// MARK: - 整行日文分词（供逐字对齐）
//
// 整行日文分词的一个 chunk（token 或标点间隙）。
struct JapaneseRomajiChunk {
    var original: String
    var romaji: String
    var range: CFRange
    /// 在整行罗马字输出里，该 chunk 前面是否需要空格（与 toJapaneseRomaji 的规则一致）。
    var leadingSpace: Bool
}

extension LyricsDto {
    /// 逐字歌词 + 对应语言罗马化开关都开启时，返回词/行文本罗马化的副本（供显示层取罗马字）。
    ///
    /// ⚠️起：**这份副本只用来"取罗马字那一行"**，谁都不许把它当主歌词。
    /// · `LyricLinesAdapter.toAppleMusicLyricLines` 只读它的 `content` 去和**原文**比，
    /// 不同才把罗马字挂到 `LyricLine.romanization`（画在原文上方）；
    /// · `CustomLyrics.storeLyricsDto` 存的是**原样 dto**，不是这份副本 ——
    /// 以前存的是它，于是"原文"在渲染前就已经变成罗马字，的是
    /// 「直接替换原日文」而不是「原文上面一行罗马字」。
    /// · 喂给 Spotify 原生那页的 payload（`toSpotifyLyricsData`）同样**不再**罗马化，
    /// 原生页回到原文（以前那句"toSpotifyLyricsData 自己会罗马化 content"已经作废）。
    func romanizedForWordByWordIfEnabled() -> LyricsDto {
        guard NgzhwmSettingsViewModel.isWordByWordLyricsEnabled,
              romanization == .canBeRomanized else { return self }

        // ── 首字母大写：**先做，且与罗马化开关无关**
        //
        // ⚠️ 这里以前把大写和罗马化写在同一个循环里，并且上面那三个
        // `guard ...Romanization else { return self }` 会**整个函数提前返回** ——
        // 于是"用户把日语罗马化关掉"时，大写也一起被跳过，这一层显示的是
        // 网易云原始文本（全小写）。
        //
        // 而喂给 Spotify 的那份（`toSpotifyLyricsData` → `LyricsDto.swift` 第 72 行）
        // 是**无条件**做大写的。两边一对比就是的现象：
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
    static func japaneseWordRomaji(
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
    static func perWordRomaji(
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
    static func containsCJKText(_ text: String) -> Bool {
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
