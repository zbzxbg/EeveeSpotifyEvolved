import Foundation

/// 单个 token 的罗马字（汉字读音的清理 + 假名/拉丁分流），**全仓唯一的一份**。
///
/// 为什么从 `LyricsDto.swift` 拆出来：显示层那条路（`toJapaneseRomaji`）依赖
/// `CFStringTokenizer`，在 CI 里跑不了；但"拿到 ICU 的转写之后怎么改"这一段是纯函数，
/// 拆出来就能进 `swiftc 单个文件 + 测试 main` 那种组合（`Tests/JapaneseTokenRomaji`）。
/// `LyricsDto.swift` 本身拖着 protobuf / `UserDefaults`，进不了那条命令。
///
/// 拆之前这段逻辑在两个循环里**各写了一遍**（`toJapaneseRomaji` 与
/// `japaneseRomajiChunks`），和当初假名表被抄两份是同一类隐患：改一处忘另一处，
/// 屏幕上那行与逐字对齐那行就对不上。现在两个循环都调这里。
///
/// ── 为什么汉字读音只做三件事，不继续加词表
/// 汉字读音的错分两类。一类是**可枚举的系统性错误**：纯拉丁 token 被按片假名读
/// （`around` → `araundo`）、`づ` 被写成 `dz`（`続く` → `tsudzuku`）、汉字词末尾的 `っ`
/// 被读成 `tsu`（`食らっ` → `kuratsu`）—— 这三条都在本文件里修掉，与具体哪首歌无关。
/// 另一类是**多音词与分词歧义**：`刃` は/やいば/じん、`行` こう/ぎょう、`十色` といろ，
/// 同一个 token 在不同歌里读音不同。整 token 精确匹配的表救不了它们，硬写一个读音
/// 会把别的歌读坏（见 `japaneseWordOverrides` 里 `君` 那段）。剩下的交给官方 `romalrc`。
enum JapaneseTokenKind {
    /// 纯假名 ⇒ 走 `japaneseKanaRomaji`。
    case kana
    /// 含汉字/假名 ⇒ 用 ICU 的 Latin 转写，再清理。
    case japanese
    /// 纯拉丁/数字/符号（`around`、`'t`、`OK`）⇒ **原样透传**。
    case latin
}

/// ICU 的汉字转写带 macron（`chīsana`、`ā`），而整条链路写的是 ASCII 双元音。
///
/// 不归一的话同一行里会两种风格并存：假名段 `koohii`、汉字段 `chīsana`。
let japaneseMacronExpansions: [(String, String)] = [
    ("ā", "aa"), ("ī", "ii"), ("ū", "uu"), ("ē", "ee"), ("ō", "oo"),
    ("Ā", "Aa"), ("Ī", "Ii"), ("Ū", "Uu"), ("Ē", "Ee"), ("Ō", "Oo")
]

/// 半角 CJK 标点 → 全角。ICU 会把 `「」、。` 归一成 `｢｣､｡`（U+FF61–FF65），
/// 罗马字那一行要跟原文同一套宽度，否则 `｢ ... ､` 看起来像乱码。
let japaneseFullwidthPunctuation: [Character: Character] = [
    "｡": "。", "｢": "「", "｣": "」", "､": "、", "･": "・", "ｰ": "ー"
]

/// 汉字词的读音修正 —— `CFStringTokenizer` 的 Latin transcription 有几处给的是**书面语读音**，
/// 歌词里几乎不会那么念。
///
/// 目前只收 `私`：tokenizer 给 `watakushi`（正式场合的自称），而歌词里一律是 `watashi`。
///
/// **刻意不收「君」**：它有两个读音（`kimi` = 你、`kun` = 称呼后缀），
/// 而 tokenizer 是按 token 给的、看不到"前面是不是人名" —— 硬写成 `kimi` 会把
/// 「田中君」读成 `tanaka kimi`，比默认更差。多音词一律不进来。
/// `僕` / `俺` / `貴方` 也是同理：没有证据说 tokenizer 读错，就不动它。
///
/// 判据是**整 token 精确匹配**：`私立` 那种合成词 tokenizer 给的是一个 token，打不中；
/// `私たち` 会被切成 `私` + `たち`，于是 `watashi` + `tachi` —— 正是要的结果。
///
/// ⚠️ 加一条之前先看真实 dump（`[RomajiDump]`）：**同一个词在不同歌里读音不同**的，一律不加。
/// 也别照着官方 `romalrc` 抄 —— 它自己会错：`騙る` 被写成 `damaru`，而 `騙る` 是かたる
/// （`騙す` 才是だます），本地给 `kataru` 才是对的。
let japaneseWordOverrides: [String: String] = [
    "私": "watashi"
]

/// 这个 token 里有没有日文字符（汉字 / 假名 / 々 之类）。
///
/// 用来挡一类**真错**：ICU 的 ja 分词器把纯拉丁 token 也按片假名读出来，
/// 于是 `around` → `araundo`、`'t` → `ton`。
/// 这类 token 根本没有"读音"可转，原样透传才对。
func japaneseContainsJapaneseScript(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        switch scalar.value {
        case 0x3040...0x30FF,          // 平假名 / 片假名（含 ー、ゝ）
             0x3400...0x4DBF,          // 汉字扩展 A
             0x4E00...0x9FFF,          // 汉字
             0xF900...0xFAFF,          // 兼容汉字
             0xFF66...0xFF9D,          // 半角片假名
             0x3005, 0x3006,           // 々 〆
             0x31F0...0x31FF:          // 片假名语音扩展
            return true
        default:
            return false
        }
    }
}

/// 是不是拼音（ICU 对汉字给拼音时的声调标记）。
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

    // macron → ASCII 双元音：ICU 的汉字转写会带 `chīsana` / `ā`，与本仓库的
    // `koohii` 风格冲突。归一之后整行只有一套写法。
    for (macron, plain) in japaneseMacronExpansions {
        s = s.replacingOccurrences(of: macron, with: plain)
    }

    // `づ` / `ず` 的 ICU 写法是 `dz`（`続く` → `tsudzuku`、`続けて` → `sudzukete`），
    // 而本仓库与官方轨都写 `zu`。
    // 这条放在拉丁透传之后 ⇒ 不会误伤英文 token。
    s = s.replacingOccurrences(of: "dz", with: "z")
    s = s.replacingOccurrences(of: "Dz", with: "Z")

    // 半角 CJK 标点 → 全角（ICU 会把「」、。 吐成 ｢｣､｡）。
    s = String(s.map { japaneseFullwidthPunctuation[$0] ?? $0 })

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

/// 这个 token 该走哪条路。
func japaneseTokenKind(_ original: String) -> JapaneseTokenKind {
    if japaneseIsPureKana(original) { return .kana }
    if japaneseContainsJapaneseScript(original) { return .japanese }
    return .latin
}

/// 一个 token 的罗马字。`transcription` 是 `kCFStringTokenizerAttributeLatinTranscription`
/// 的原始输出（调用方只在需要时才取，纯拉丁 token 取都不用取）。
///
/// - Parameter pendingGeminate: 进 = 上一个 token 留下了没消化的促音；出 = 本 token 末尾有没有。
///   跨 token 的促音靠它传递（`食らっ` 的 `っ` 落在 `ちゃい` 上）。
func japaneseTokenRomaji(
    _ original: String,
    transcription: String?,
    pendingGeminate: inout Bool
) -> String {
    var romaji: String

    switch japaneseTokenKind(original) {
    case .kana:
        romaji = japaneseKanaRomaji(original, pendingGeminate: &pendingGeminate)

    case .latin:
        // `around` / `'t` / `OK`：ICU 会按片假名给 `araundo` / `ton`，原样透传才对。
        romaji = original
        pendingGeminate = false

    case .japanese:
        if let transcription, !japaneseContainsPinyinMarker(transcription) {
            romaji = japaneseSanitizeTranscription(transcription, original: original)
            // 上一个 token 是「以 っ 结尾的汉字词」（`食らっ`）：促音在这里落地。
            if pendingGeminate {
                romaji = japaneseGeminated(romaji)
                pendingGeminate = false
            }
            // 本 token 自己以 っ 结尾：ICU 给的是 `kuratsu`，把 `tsu` 摘掉、
            // 把促音传给下一个 token（`食らっ` + `ちゃい` → `kura` + `tchai`）。
            if original.hasSuffix("っ"), romaji.hasSuffix("tsu") {
                romaji = String(romaji.dropLast(3))
                pendingGeminate = true
            }
        } else {
            // 拿不到日语读音（拼音回退 / nil）：保留原文，但促音状态要断掉。
            romaji = original
            pendingGeminate = false
        }
    }

    if let override = japaneseWordOverrides[original] { romaji = override }

    return romaji
}
