import Foundation

/// 假名 → 罗马字：**全仓唯一的一份**。
///
/// 为什么单独一个文件：这段逻辑有两个调用方 —— 显示层的 `toJapaneseRomaji`
/// （`LyricsDto.swift`）和酷狗官方罗马字修复（`JapaneseRomajiRepair.swift`）。以前各写一份
/// （连假名表都抄了两遍，注释里写着"两处改动必须同步"），改一处忘另一处就是
/// "官方那行对、本地那行错"。现在只有这里一份，两个调用方只差一个策略参数。
///
/// ── 为什么不交给系统 ICU
/// 2026-11-08 的 CI 实测（`Tests/JapaneseRomanizationProbe`）：
/// · `ja_Hrkt_ja_Latn_BGN` 能解析、但**恒等变换**（精简构建，规则数据没编进去）；
/// · `Hiragana-Latin` / `toLatin` 确实在转，但 `toLatin` 对汉字给的是**拼音**、输出是
///   macron 风格（`kōhī`），而且 ICU 数据在 macOS 与 iOS 上不一定一致 ——
///   一个注入 tweak 不能把显示效果押在"这台设备的 ICU 恰好有规则"上。
/// 所以这张表是唯一路径，外来音也只能自己补。
///
/// ── 约定
/// · 键为**平假名**码点；片假名由 `japaneseHiraganaScalar` 减 0x60 归一后查同一张表。
/// · 输出是 ASCII：长音写双元音（`koohii`），不用 macron —— 与官方轨、既有测试同一套观感。
/// · 促音双写、拗音、外来音（`ファ` `ティ` `ウィ` `ヴァ` `シェ` …）、`ん` 的隔音符都在这里。

/// 表里没有的假名怎么处理。
enum JapaneseKanaUnmapped {
    /// 原样保留（显示层：宁可露出一个假名，也不要凭空吞掉歌词）。
    case keep
    /// 丢掉（酷狗修复：契约要求"结果里不许有假名"，宁可少一个字）。
    case drop
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

/// 外来音（合拗音）：这些组合**拼不出来** —— `テ` + `ィ` 逐字是 `tei`，正确是 `ti`。
///
/// 键是 `前一个假名的平假名码点 << 16 | 后一个小假名的平假名码点`。
/// 片假名（`ファ` `ティ` `ヴァ` …）走 `japaneseHiraganaScalar` 归一后命中同一张表。
///
/// ⚠️ 只收"读音不是逐字拼接"的组合；普通拗音（`きゃ` `しょ`）仍由 `japaneseSyllableRomaji`
/// 里那条 stem 规则生成，不在这张表里重复一遍。
let japaneseKanaCombos: [UInt32: String] = {
    var map: [UInt32: String] = [:]

    func add(_ first: Character, _ second: Character, _ romaji: String) {
        guard let a = String(first).unicodeScalars.first?.value,
              let b = String(second).unicodeScalars.first?.value else { return }
        map[(a << 16) | b] = romaji
    }

    // ふぁ ふぃ ふぇ ふぉ / ふゅ
    add("ふ", "ぁ", "fa"); add("ふ", "ぃ", "fi")
    add("ふ", "ぇ", "fe"); add("ふ", "ぉ", "fo")
    add("ふ", "ゅ", "fyu")
    // うぃ うぇ うぉ（ウィ / ウェ / ウォ）
    add("う", "ぃ", "wi"); add("う", "ぇ", "we"); add("う", "ぉ", "wo")
    // てぃ てゅ / でぃ でゅ
    add("て", "ぃ", "ti"); add("て", "ゅ", "tyu")
    add("で", "ぃ", "di"); add("で", "ゅ", "dyu")
    // とぅ どぅ
    add("と", "ぅ", "tu"); add("ど", "ぅ", "du")
    // つぁ つぃ つぇ つぉ
    add("つ", "ぁ", "tsa"); add("つ", "ぃ", "tsi")
    add("つ", "ぇ", "tse"); add("つ", "ぉ", "tso")
    // しぇ じぇ ちぇ
    add("し", "ぇ", "she"); add("じ", "ぇ", "je"); add("ち", "ぇ", "che")
    // ゔぁ ゔぃ ゔぇ ゔぉ / ゔゅ
    add("ゔ", "ぁ", "va"); add("ゔ", "ぃ", "vi")
    add("ゔ", "ぇ", "ve"); add("ゔ", "ぉ", "vo")
    add("ゔ", "ゅ", "vyu")
    // くぁ ぐぁ 系（クァルテット / グァム）
    add("く", "ぁ", "kwa"); add("く", "ぃ", "kwi")
    add("く", "ぇ", "kwe"); add("く", "ぉ", "kwo")
    add("ぐ", "ぁ", "gwa"); add("ぐ", "ぃ", "gwi")
    add("ぐ", "ぇ", "gwe"); add("ぐ", "ぉ", "gwo")
    // すぃ ずぃ
    add("す", "ぃ", "si"); add("ず", "ぃ", "zi")
    // きぇ ぎぇ にぇ ひぇ びぇ ぴぇ みぇ りぇ
    add("き", "ぇ", "kye"); add("ぎ", "ぇ", "gye")
    add("に", "ぇ", "nye"); add("ひ", "ぇ", "hye")
    add("び", "ぇ", "bye"); add("ぴ", "ぇ", "pye")
    add("み", "ぇ", "mye"); add("り", "ぇ", "rye")
    // いぇ
    add("い", "ぇ", "ye")

    return map
}()

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

/// 促音：把下一音节的辅音双写（`to` → `tto`、`chi` → `tchi`、`shi` → `sshi`）。
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

/// 一个"音节"（含拗音 / 外来音）的读音，以及它吃掉的字符数。`nil` = 表里没有。
func japaneseSyllableRomaji(
    _ scalars: [Unicode.Scalar],
    at index: Int
) -> (romaji: String, length: Int)? {
    guard index < scalars.count,
          let hiragana = japaneseHiraganaScalar(scalars[index].value) else { return nil }

    // ん：后接元音 / y 时要加隔音符（`しんよう` → `shin'you`、`きんえん` → `kin'en`）。
    // 后接辅音（`しんぶん`）或另一个 ん 时不加。
    if hiragana == 0x3093 {
        let apostrophe = japaneseNeedsApostropheAfterN(scalars, at: index + 1)
        return (apostrophe ? "n'" : "n", 1)
    }

    // 外来音：优先于逐字拼（`ティ` 不是 `tei`）。
    if index + 1 < scalars.count,
       let next = japaneseHiraganaScalar(scalars[index + 1].value),
       let combo = japaneseKanaCombos[(hiragana << 16) | next] {
        return (combo, 2)
    }

    guard let base = japaneseKanaMap[hiragana] else { return nil }

    // 拗音：i 段 + 小 ゃ/ゅ/ょ。`しゃ/ちゃ/じゃ` 走 stem，其余补 y。
    if base.count >= 2, base.hasSuffix("i"),
       index + 1 < scalars.count,
       let next = japaneseHiraganaScalar(scalars[index + 1].value),
       let vowel = japaneseSmallYouonVowel(next) {
        let stem = String(base.dropLast())
        if stem.hasSuffix("sh") || stem.hasSuffix("ch") || stem.hasSuffix("j") {
            return (stem + vowel, 2)
        }
        return (stem + "y" + vowel, 2)
    }

    return (base, 1)
}

/// `ん` 后面那个音节是不是以元音 / y 开头（是就要隔音符）。
private func japaneseNeedsApostropheAfterN(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
    guard index < scalars.count,
          let hiragana = japaneseHiraganaScalar(scalars[index].value) else { return false }
    var romaji = japaneseKanaMap[hiragana] ?? ""
    if index + 1 < scalars.count,
       let next = japaneseHiraganaScalar(scalars[index + 1].value),
       let combo = japaneseKanaCombos[(hiragana << 16) | next] {
        romaji = combo
    }
    guard let first = romaji.first else { return false }
    return "aeiouy".contains(first)
}

/// 一段假名的逐字罗马化。促音状态可以带进带出（跨 token 的促音靠它传递）。
///
/// - Parameters:
///   - pendingGeminate: 进 = 上一段末尾有个没消化的 `っ`；出 = 本段末尾有没有。
///   - prior: 本段之前已经产出的罗马字（长音 `ー` 落在段首时，要接前一段的元音）。
///   - unmapped: 表里没有的假名是保留还是丢掉。
func japaneseKanaRomaji(
    _ text: String,
    pendingGeminate: inout Bool,
    prior: String = "",
    unmapped: JapaneseKanaUnmapped = .keep
) -> String {
    let scalars = Array(text.unicodeScalars)
    var result = ""
    var pending = pendingGeminate
    var index = 0

    while index < scalars.count {
        let value = scalars[index].value

        // 长音 ー：重复前一个元音（只写 ASCII，避免 macron 之类的怪字符）。
        if value == 0x30FC {
            let source = result.isEmpty ? prior : result
            if let last = source.last, "aeiou".contains(last) {
                result.append(last)
            }
            index += 1
            continue
        }

        // 促音 っ/ッ：先记下，等下一个音节双写辅音。
        if value == 0x3063 || value == 0x30C3 {
            pending = true
            index += 1
            continue
        }

        guard let syllable = japaneseSyllableRomaji(scalars, at: index) else {
            // 表里没有的假名（半角假名 / ゐ ゑ 等）：按调用方的契约保留或丢掉。
            if case .keep = unmapped, let scalar = UnicodeScalar(value) {
                result += String(scalar)
            }
            index += 1
            continue
        }

        var romaji = syllable.romaji
        if pending {
            romaji = japaneseGeminated(romaji)
            pending = false
        }
        result += romaji
        index += syllable.length
    }

    pendingGeminate = pending
    return result
}

/// 整段都是假名（平/片，含半角以外的基本区）吗。
func japaneseIsPureKana(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    return text.unicodeScalars.allSatisfy {
        (0x3040...0x309F).contains($0.value) || (0x30A0...0x30FF).contains($0.value)
    }
}
