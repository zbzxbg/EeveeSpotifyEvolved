import Foundation

/// `japaneseTokenRomaji` 的断言程序（纯 Foundation，CI 跑；见 `.github/workflows/tests.yml`）。
///
/// 为什么需要它：显示层那条路（`toJapaneseRomaji` / `japaneseRomajiChunks`）依赖
/// `CFStringTokenizer`，在 CI 里跑不了 —— 本仓库没有 Mac，也就没有第二个地方能在
/// 打包之前验证"罗马字那一行到底长什么样"。这个文件把**拿到转写之后**那一段纯函数
/// 抠出来钉住：ICU 给什么字符串是系统的自由，我们把它改成什么，是自己的契约。
///
/// 下面每一条的 `original` / `transcription` 都不是编的：它们逐字抄自真机 `[RomajiDump]`
/// 的 `i.tok` 行（`原文→转写`），也就是 `CFStringTokenizer` 在这台设备上的真实输出。
/// 合成用例只能验证设想中的形状，真实 dump 才能暴露它实际吐什么。

var failures = 0

func require(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)")
    }
}

/// 一步：进 = 上一个 token 留下的促音状态。
func romaji(_ original: String, _ transcription: String?, pending: inout Bool) -> String {
    japaneseTokenRomaji(original, transcription: transcription, pendingGeminate: &pending)
}

// MARK: - 纯拉丁 token 必须原样透传

// `jump around` 里的 `around`：ICU 的 ja 分词器按片假名给了 `araundo`。
// 曾经整行变成 `jump araundo`。
var p1 = false
require(romaji("around", "araundo", pending: &p1) == "around",
        "latin: around keeps its spelling (ICU would say araundo)")
require(!p1, "latin: a latin token clears the pending geminate")

// `ain't` 被切成 `ain` + `'` + `t`，`'t` 那颗的转写是 `ton` ⇒ 曾经拼成 `ain'ton`。
var p2 = false
require(romaji("'t", "ton", pending: &p2) == "'t", "latin: 't is not romanized to ton")

var p3 = false
require(romaji("attention", nil, pending: &p3) == "attention",
        "latin: a token with no transcription passes through")

// 分类判据：有汉字/假名才算日文 token。
require(japaneseTokenKind("around") == .latin, "kind: around is latin")
require(japaneseTokenKind("東京") == .japanese, "kind: 東京 is japanese")
require(japaneseTokenKind("しんよう") == .kana, "kind: しんよう is kana")
require(japaneseTokenKind("々") == .japanese, "kind: the iteration mark is japanese")

// MARK: - づ 的 ICU 写法是 dz

// 続く → 曾经 `tsudzuku`。本仓库与官方轨都写 `zu`。
var p4 = false
require(romaji("続く", "tsudzuku", pending: &p4) == "tsuzuku", "dz: 続く → tsuzuku")
var p5 = false
require(romaji("続けて", "sudzukete", pending: &p5) == "suzukete", "dz: 続けて → suzukete")

// MARK: - 汉字 token 末尾的 っ

// `食らっちゃいな`：tokenizer 切 `食らっ` + `ちゃい` + `な`，`食らっ` 的转写是 `kuratsu`。
// 曾经整行 `kuratsuchai na`，官方轨是 `kura'tcha i na`。
var p6 = false
let kuratsu = romaji("食らっ", "kuratsu", pending: &p6)
require(kuratsu == "kura", "geminate: 食らっ drops the tsu (got \(kuratsu))")
require(p6, "geminate: 食らっ hands the っ to the next token")
require(romaji("ちゃい", nil, pending: &p6) == "tchai",
        "geminate: the next token doubles its consonant (kura + tchai)")
require(!p6, "geminate: the pending flag is consumed")

// 同一 token 内的促音仍然走假名那条路（`ずっと` 的 っ 不出这个 token）。
var p7 = false
require(romaji("ずっと", nil, pending: &p7) == "zutto", "geminate: ずっと → zutto")

// MARK: - 汉字读音覆盖表（`japaneseWordOverrides`）

var p8 = false
require(romaji("私", "watakushi", pending: &p8) == "watashi", "override: 私 → watashi")

// 官方轨把 `騙る` 写成 `damaru`，本地是 `kataru` —— **本地才对**（騙る＝かたる）。
// 这条钉的是"别照官方轨把它写进覆盖表"。
var p9 = false
require(romaji("騙る", "kataru", pending: &p9) == "kataru",
        "override: 騙る stays kataru (the official track is wrong here)")

// MARK: - 拿不到日语读音时保留原文（拼音回退）

var p10 = false
require(romaji("東京", "běijīng", pending: &p10) == "東京",
        "fallback: a pinyin transcription keeps the original")
var p11 = false
require(romaji("東京", nil, pending: &p11) == "東京", "fallback: no transcription keeps the original")

// MARK: - 转写里的助词后缀（`私は` 这种 tokenizer 没拆出来的）

var p12 = false
require(romaji("私は", "watashiha", pending: &p12) == "watashi wa",
        "particle: 私は → watashi wa")

// MARK: - 假名那条路仍然照旧（这些用例在 KuGouRomaji 里也有，这里钉的是"同一个入口"）

var p13 = false
require(romaji("しんよう", nil, pending: &p13) == "shin'you", "kana: ん before a vowel takes an apostrophe")
var p14 = false
require(romaji("パーティー", nil, pending: &p14) == "paatii", "kana: パーティー keeps the loanword syllable")
var p15 = false
require(romaji("コンプリート", nil, pending: &p15) == "konpuriito", "kana: ー repeats the previous vowel")

// MARK: - 结果

if failures == 0 {
    print("JapaneseTokenRomaji: all assertions passed")
} else {
    print("JapaneseTokenRomaji: \(failures) assertion(s) FAILED")
    exit(1)
}
