import Foundation

/// ICU 日文音译的**可用性探针**（纯 Foundation，CI 跑；见 `.github/workflows/tests.yml`）。
///
/// ── 它回答什么问题
/// 我们想知道能不能把假名层交给系统 ICU 的 `ja_Hrkt_ja_Latn_BGN`（BGN/PCGN 改良 Hepburn）。
/// 规则本身很好：`ん` 后接 b/p/m → `m`、后接元音/y → `n'`、`を` → `o`、促音按行双写、
/// `aー` → `ā`，还先做 `Halfwidth-Fullwidth` 与 NFC 归一。
///
/// ── 2026-11-08 的实测结论（第一次跑 CI 得到的）
/// **这条路不可用。** 三个 id 都能创建出 transform 对象（`applyingTransform` 不返回 nil），
/// 但对假名样本**原样返回输入** —— 典型的 ICU 精简构建：标识符能解析、规则数据没编进去，
/// 执行时退化成恒等变换。
///
/// 对比之下 `toLatin` 是**真的在工作**（`こんにちは` → `kon'nichiha`）：它走的是
/// Any-Latin 那条通用链，不依赖日文专用规则。所以本探针现在把 `toLatin` 也一起打出来 ——
/// 它是"假名层要不要换引擎"唯一还值得看的候选。
///
/// ── 为什么它不该红
/// 探针的产物是**信息**。第一次写的时候把三条规则写成了断言，结果 ICU 缺数据时 CI 直接红，
/// 而"ICU 缺数据"本身就是要报告的结论之一 —— 让结论把构建打红是本末倒置。
/// 现在只有一件事会失败：连 `toLatin` 都不工作（那说明测试环境坏了，继续读日志没意义）。
///
/// ⚠️ 即使哪天 BGN 可用了，它也不能直接替换现有假名表：规则字符集里没有小写元音
/// `ぁぃぅぇぉ/ァィゥェォ`（`パーティー` 会漏出 `ィ`），而且输出是 macron 风格
/// （`kōhī`），与仓库现在的 ASCII 双写（`koohii`）不是一套。

var failures = 0

/// 一次探测的结果。**`identity` 是关键状态**：id 解析得出来、但什么都没做。
enum ProbeOutcome {
    case missing
    case identity
    case transformed(String)

    var label: String {
        switch self {
        case .missing: return "MISSING "
        case .identity: return "IDENTITY"
        case .transformed: return "WORKS   "
        }
    }

    var output: String? {
        if case let .transformed(text) = self { return text }
        return nil
    }
}

func probe(_ identifier: String, _ text: String) -> ProbeOutcome {
    let transform = StringTransform(rawValue: identifier)
    guard let output = text.applyingTransform(transform, reverse: false) else { return .missing }
    return output == text ? .identity : .transformed(output)
}

/// 固定样本：每条都对应一个我们关心的规则。
let samples: [(text: String, note: String)] = [
    ("こんにちは", "は 作助词 → wa?"),
    ("を", "wo 还是 o"),
    ("しんよう", "ん 后接元音 → n'?"),
    ("しんぶん", "ん 后接 b → m?"),
    ("ずっと", "促音"),
    ("コーヒー", "ー → ō?"),
    ("とうきょう", "おう → ō?"),
    ("パーティー", "外来音（已知会漏 ィ）"),
    ("シェア", "外来音（已知会漏 ェ）"),
    ("ヴァイオリン", "外来音（已知会漏 ァ）")
]

// MARK: - 0. 基线：toLatin 必须可用（否则是环境问题，不是能力问题）

print("== baseline")
let baseline = probe(StringTransform.toLatin.rawValue, "こんにちは")
if case let .transformed(output) = baseline {
    print("     toLatin(こんにちは) = \(output)")
} else {
    failures += 1
    print("  FAIL toLatin is \(baseline.label) — the test environment itself is broken")
}

// MARK: - 1. 候选 id 的实际状态（不是"能不能创建"，是"转不转"）

print("== candidate identifiers (probed on かな)")
let identifiers = [
    "ja_Hrkt_ja_Latn_BGN",
    "Hiragana-Latin",
    "Katakana-Hiragana",
    "Hiragana-Katakana"
]
var outcomes: [String: ProbeOutcome] = [:]
for identifier in identifiers {
    // `Katakana-Hiragana` 要喂片假名才看得出来，其余喂平假名。
    let sample = identifier == "Katakana-Hiragana" ? "カナ" : "かな"
    let outcome = probe(identifier, sample)
    outcomes[identifier] = outcome
    print("     \(outcome.label) \(identifier)")
    if case let .transformed(output) = outcome {
        print("              \(sample) → \(output)")
    }
}

// MARK: - 2. toLatin 的行为表（现在唯一还在工作的那条）

print("== toLatin behaviour (the only engine that actually transforms)")
for sample in samples {
    let outcome = probe(StringTransform.toLatin.rawValue, sample.text)
    switch outcome {
    case .missing: print("     \(sample.text)  → <missing>")
    case .identity: print("     \(sample.text)  → <unchanged>")
    case let .transformed(output): print("     \(sample.text)  → \(output)")
    }
}

// MARK: - 3. 如果 BGN 真的能用，把它的规则行为打出来（只报告，不断言）

let bgn = outcomes["ja_Hrkt_ja_Latn_BGN"] ?? .missing
if case .transformed = bgn {
    print("== BGN behaviour (available on this ICU build)")
    for sample in samples {
        if case let .transformed(output) = probe("ja_Hrkt_ja_Latn_BGN", sample.text) {
            print("     \(sample.text)  → \(output)")
        }
    }
}

// MARK: - 结论

print("== verdict")
switch bgn {
case .missing:
    print("     ICU Japanese transliteration: MISSING — do not route kana through ICU.")
case .identity:
    print("     ICU Japanese transliteration: UNAVAILABLE (identity transform, stub ICU data).")
    print("     ⇒ the hand-written kana table stays the only path.")
case .transformed:
    print("     ICU Japanese transliteration: AVAILABLE — usable as a reference/fallback,")
    print("     but it lacks ぁぃぅぇぉ and emits macrons, so it cannot replace the table as-is.")
}

print("")
if failures == 0 {
    print("JapaneseRomanizationProbe: probe complete (informational)")
} else {
    print("JapaneseRomanizationProbe: \(failures) environment failure(s)")
    exit(1)
}
