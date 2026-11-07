import Foundation

/// ICU 日文音译的**可用性探针**（纯 Foundation，CI 跑；见 `.github/workflows/tests.yml`）。
///
/// ── 它回答什么问题
/// 我们想用系统 ICU 里的 `ja_Hrkt_ja_Latn_BGN`（BGN/PCGN 改良 Hepburn）来替代/校验
/// `LyricsDto.swift` 里手写的假名表。规则本身是好的：`ん` 后接 b/p/m → `m`、后接元音/y → `n'`、
/// `を` → `o`、促音按行双写、`aー` → `ā`，还先做 `Halfwidth-Fullwidth` 与 NFC 归一。
///
/// 但**这条 transform 在 iOS 的系统 ICU 数据里到底在不在**，没有文档保证 ——
/// `StringTransform(rawValue:)` 是公开 API，能不能解析出这条规则是另一回事。
/// 本机（Windows）没有 Swift 工具链、也没有 iOS 设备，所以这个问题的**唯一**低成本答案
/// 就在这里：CI 的 runner 是 macOS，自带完整 ICU，跑一遍就知道。
///
/// ── 为什么它不会"红"
/// 探针的产物是**信息**，不是断言：某个 ID 不可用时打印 `MISSING`，不失败。
/// 唯一会失败的是"连 `toLatin` 都不工作" —— 那说明测试环境本身坏了，
/// 继续往下读日志没有意义。
///
/// ⚠️ 这条 transform **不能**直接替换现有假名表，两个已知限制（探针会把它们打出来）：
/// · 规则字符集里没有小写元音 `ぁぃぅぇぉ/ァィゥェォ` ⇒ `パーティー` 会漏出 `ィ`；
/// · 输出是 macron 风格（`kōhī`），与仓库现在的 ASCII 双写（`koohii`）不是一套。
/// 所以它现在的定位是**参照实现 + 兜底**，不是主路径。

var failures = 0

func note(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)")
    }
}

func probe(_ identifier: String, _ text: String) -> String? {
    let transform = StringTransform(rawValue: identifier)
    guard let output = text.applyingTransform(transform, reverse: false) else { return nil }
    return output
}

// MARK: - 0. 基线：toLatin 必须可用（否则是环境问题，不是能力问题）

print("== baseline")
let baseline = probe(StringTransform.toLatin.rawValue, "こんにちは")
note(baseline != nil, "StringTransform.toLatin works (baseline)")
if let baseline {
    print("     toLatin(こんにちは) = \(baseline)")
}

// MARK: - 1. 候选 ID 是否解析得出来

print("== candidate identifiers")
// `ja_Hrkt_ja_Latn_BGN` 是 ICU 数据里那条规则文件的真名；
// `Hiragana-Latin` 是历史上常见的别名写法，两个都试。
let identifiers = [
    "ja_Hrkt_ja_Latn_BGN",
    "Hiragana-Latin",
    "Katakana-Hiragana",
    "Hiragana-Katakana"
]
var availability: [String: Bool] = [:]
for identifier in identifiers {
    let resolved = probe(identifier, "かな") != nil
    availability[identifier] = resolved
    print("     \(resolved ? "OK     " : "MISSING") \(identifier)")
}

// MARK: - 2. 用固定样本把它的行为打出来（供人工对照）

print("== behaviour (kana-only samples)")
let samples = [
    "こんにちは",   // は 作助词 → wa?
    "を",           // wo 还是 o
    "しんよう",     // ん 后接元音 → n' ?
    "きんえん",     // 同上
    "しんぶん",     // ん 后接 b → m ?
    "ずっと",       // 促音
    "がっこう",     // 促音
    "コーヒー",     // 長音 → ō ?
    "とうきょう",   // おう → ō ?
    "パーティー",   // 外来音（已知会漏 ィ）
    "シェア",       // 外来音（已知会漏 ェ）
    "ヴァイオリン"  // 外来音（已知会漏 ァ）
]
for sample in samples {
    let bgn = probe("ja_Hrkt_ja_Latn_BGN", sample)
        ?? probe("Hiragana-Latin", sample)
        ?? "<unavailable>"
    print("     \(sample)  →  \(bgn)")
}

// MARK: - 3. 如果可用，钉住它文档化的两条规则

if let bgnAvailable = availability["ja_Hrkt_ja_Latn_BGN"], bgnAvailable {
    print("== documented rules (BGN available)")
    if let n = probe("ja_Hrkt_ja_Latn_BGN", "しんよう") {
        note(n.contains("n'"), "ん before a vowel becomes n' (got \(n))")
    }
    if let w = probe("ja_Hrkt_ja_Latn_BGN", "を") {
        note(w == "o", "を romanises as o (got \(w))")
    }
    if let long = probe("ja_Hrkt_ja_Latn_BGN", "コーヒー") {
        note(long.contains("ō"), "ー extends the previous vowel as a macron (got \(long))")
    }
} else {
    print("== documented rules — skipped (transform unavailable on this ICU build)")
}

// MARK: - 结果

print("")
if failures == 0 {
    print("JapaneseRomanizationProbe: probe complete")
} else {
    print("JapaneseRomanizationProbe: \(failures) assertion(s) FAILED")
    exit(1)
}
