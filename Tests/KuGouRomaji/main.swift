import Foundation

/// `JapaneseRomajiRepair` 的断言程序（纯 Foundation，CI 跑；见 `.github/workflows/tests.yml`）。
///
/// 为什么必须钉这一份：它修的是酷狗官方罗马字里的原文残留，判据只有"组数不变 +
/// 无假名 / 无汉字 + 促音合成整词"三条，`swiftc` 在真机 build 之前不会编译它
/// （本仓库没有 Mac）。下面那些输入不是编的：它们是 KRC `[language:]` type 0 里逐字
/// 抄下来的组（`ずっと` 那组就是 `["zu ", "っ", "to  "]`；汉字那几条来自同一份的
/// `["ai ", "no ", "kalada ", "温", "to ", "酩", "酊"]` / `届`），另外几条是形状相近的
/// 合成用例。

var failures = 0

func require(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)")
    }
}

func repaired(_ groups: [String]) -> [String]? {
    JapaneseRomajiRepair.repairedWordGroups([groups])?.first
}

func joined(_ groups: [String]) -> String {
    groups.joined()
}

// MARK: - 真实样本：ずっと ずっと 手を伸ばしてた 嗚呼

// 日语原文 `ず<…>っ<…>と <…>ず<…>っ<…>と <…>手…`，词片 15 个、罗马字组 15 个。
let zuttoInput = [
    "zu ", "っ", "to  ", "zu ", "っ", "to  ",
    "te ", "wo ", "no ", "ba ", "xi ", "te ", "ta  ", "a ", "yo"
]
if let zuttoOut = repaired(zuttoInput) {
    require(zuttoOut.count == zuttoInput.count, "ずっと: the group count is unchanged")
    require(!zuttoOut.contains(where: JapaneseRomajiRepair.containsKana),
            "ずっと: no kana survives")
    require(joined(zuttoOut) == "zutto  zutto  te wo no ba xi te ta  a yo",
            "ずっと: the geminate joins the previous word (not `zu っto`, not `zu tto`)")
    // 逐词那一路：促音那一组自己拿着双写辅音，所以 っ 那一段时长里也有字可画。
    require(zuttoOut[0] == "zu" && zuttoOut[1] == "t" && zuttoOut[2] == "to  ",
            "ずっと: the doubled consonant lives in the っ group")
    require(repaired(zuttoOut) == zuttoOut, "ずっと: repairing twice changes nothing")
} else {
    failures += 1
    print("  FAIL ずっと: repairedWordGroups returned nil")
}

// MARK: - 真实样本：エコーは仄か 声を探すの

// `エ<…>コ<…>ー<…>は…`：长音符自成一个词片。
let ekoInput = ["e ", "ko ", "ー", "ha ", "hono ", "ka  ", "koe ", "wo ", "saga ", "su ", "no"]
if let ekoOut = repaired(ekoInput) {
    require(ekoOut.count == ekoInput.count, "エコー: the group count is unchanged")
    require(!ekoOut.contains(where: JapaneseRomajiRepair.containsKana),
            "エコー: no kana survives")
    require(joined(ekoOut) == "e koo ha hono ka  koe wo saga su no",
            "エコー: the long vowel extends the previous syllable")
    require(ekoOut[2].isEmpty, "エコー: the ー group itself carries no text")
} else {
    failures += 1
    print("  FAIL エコー: repairedWordGroups returned nil")
}

// MARK: - 真实样本：ループして（长音在词中间）

if let loopOut = repaired(["li ", "ー", "pu ", "xi ", "te"]) {
    require(joined(loopOut) == "lii pu xi te", "ループ: the long vowel extends `li`")
    require(!loopOut.contains(where: JapaneseRomajiRepair.containsKana),
            "ループ: no kana survives")
} else {
    failures += 1
    print("  FAIL ループ: repairedWordGroups returned nil")
}

// MARK: - 真实样本：そっと（促音在上一组之外的第二种写法）

if let sottoOut = repaired(["so ", "っ", "to  ", "so ", "っ", "to  ", "te ", "la ", "xi ", "te "]) {
    require(joined(sottoOut) == "sotto  sotto  te la xi te ",
            "そっと: both occurrences join")
    require(sottoOut.count == 10, "そっと: the group count is unchanged")
} else {
    failures += 1
    print("  FAIL そっと: repairedWordGroups returned nil")
}

// MARK: - 真实样本：不含假名 / 汉字的组必须逐字不动

// 同一首的标题行。它本来就干净，修复必须完全不动它（连尾随空格都不动）。
let cleanRow = ["su ", "pi ", "ka  ", "- ", "lo ", "ku ", "de ", "na ", "xi"]
require(repaired(cleanRow) == cleanRow, "a row with neither kana nor Han is returned untouched")

// MARK: - 真实样本：汉字残留也要清掉

// 同一份 KRC 的 `["ai ", "no ", "kalada ", "温", "to ", "酩", "酊"]`（体温 / 酩酊）：
// 汉字转不出来，但更不能留在罗马字行里 —— 丢掉，组槽位保留。
let hanRow = ["ai ", "no ", "kalada ", "温", "to ", "酩", "酊"]
if let hanOut = repaired(hanRow) {
    require(hanOut.count == hanRow.count, "Han: the group count is unchanged")
    require(!hanOut.contains(where: { JapaneseRomajiRepair.containsHan($0) }),
            "Han: no Han survives")
    require(joined(hanOut) == "ai no kalada to ", "Han: the unmappable characters are dropped")
    require(hanOut[3].isEmpty && hanOut[5].isEmpty && hanOut[6].isEmpty,
            "Han: a dropped group keeps its slot with no text")
} else {
    failures += 1
    print("  FAIL Han: repairedWordGroups returned nil")
}

// 单个汉字自成一组（`届`）：组还在、文本清空。
let hanOnlyRow = ["届"]
require(repaired(hanOnlyRow) == [""], "a Han-only group keeps its slot with no text")
require(JapaneseRomajiRepair.containsHan("届"), "届 is reported as Han")
require(!JapaneseRomajiRepair.containsHan("zutto"), "latin is not Han")

// 汉字夹在假名中间（`温` / `も` / `り`）：汉字那一组清空，假名照常转写。
let mixedHanRow = ["温", "も", "り"]
if let mixedHanOut = repaired(mixedHanRow) {
    require(mixedHanOut.count == mixedHanRow.count, "the mixed Han/kana row keeps its group count")
    require(joined(mixedHanOut) == "mori", "kana around a dropped Han still romanises")
} else {
    failures += 1
    print("  FAIL mixed Han/kana: repairedWordGroups returned nil")
}

// 汉字与假名同在一组：汉字丢掉，假名留在同一组里转写。
require(joined(repaired(["届か", "nu"]) ?? []) == "kanu",
        "kana after a dropped Han is romanised in place")

// 叠字符 々 / 〆：不是汉字（U+3005 属 Lm），但同样不能留在罗马字行里。
require(repaired(["hi ", "々"])?.joined() == "hi ",
        "the iteration mark 々 is dropped, not rendered")
require(repaired(["し", "〆"])?.joined() == "shi",
        "the 〆 mark is dropped as well")

// 片假名中点 `・` 是标点、不是假名 —— 按 Unicode 块号整段当假名会把它误删。
let dotRow = ["ku ", "re ", "i ", "ji ", "・", "ta ", "u ", "n"]
require(repaired(dotRow) == dotRow, "the katakana middle dot is not kana and is kept")
require(!JapaneseRomajiRepair.containsKana("・"), "・ is not treated as kana")

// MARK: - 合成用例：整组假名与促音的各种形状

require(joined(repaired(["da ", "け", "no ", "a", "ru"]) ?? []) == "da keno aru",
        "a whole-kana group is romanised")
require(joined(repaired(["ma ", "っ", "chi"]) ?? []) == "matchi",
        "っ before ch doubles as t")
require(joined(repaired(["ma ", "っ", "shi"]) ?? []) == "masshi",
        "っ before sh doubles as s")
// 促音挂在上一组的组尾（`かっ`）：双写落到下一组，且两组合成一个词。
require(joined(repaired(["kaっ", "to"]) ?? []) == "katto",
        "a trailing っ inside a group doubles the next group")
// 促音后面是元音：没有可双写的辅音，但两个词不能被粘在一起。
require(joined(repaired(["zu ", "っ", "a "]) ?? []) == "zu a ",
        "っ before a vowel leaves the word boundary alone")
// 组内混合假名 + 拉丁。
require(joined(repaired(["っto", "ka"]) ?? []) == "ttoka",
        "a group mixing っ with latin keeps the doubling")
// 组内长音。
require(joined(repaired(["koー", "hi"]) ?? []) == "koohi",
        "a long-vowel mark inside a group extends the same group")
// 半角片假名：转不出来就丢掉，但绝不能留在结果里。
require(!(repaired(["ｶﾞ", "ki"]) ?? ["ｶﾞ"]).contains(where: JapaneseRomajiRepair.containsKana),
        "half-width katakana never survives")

// MARK: - 契约：整批返回 nil 只在修不干净时（这里必须给出非 nil）

require(JapaneseRomajiRepair.repairedWordGroups([zuttoInput, ekoInput, cleanRow]) != nil,
        "a batch of real rows repairs successfully")
require(JapaneseRomajiRepair.repairedWordGroups([]) != nil,
        "an empty batch is not an error")

// MARK: - 假名层（共享实现）：外来音 / ん / 促音 / 長音
//
// 这一组钉的是 `JapaneseKanaRomanization.swift`（2026-11-08 起全仓唯一的一份假名表）。
// 参考值不是编的：一半来自 ICU `toLatin` 的实测输出（`pātī` / `shea` / `shin'you` 证明
// 这些是标准读法），一半是同一套读音的 ASCII 写法（长音写双元音，与官方轨观感一致）。
//
// ⚠️ 这些用例**只能走整 token 那条路**：酷狗逐字档会把 `ティ` 拆成两个组，
// 组数不能变 ⇒ 修不了。见 `JapaneseRomajiRepair.romanizeKanaRun` 的说明。
let kanaCases: [(input: String, expected: String)] = [
    ("パーティー", "paatii"),   // ティ 是一个音节，不是 te + i
    ("シェア", "shea"),
    ("チェリー", "cherii"),
    ("ジェット", "jetto"),
    ("ヴァイオリン", "vaiorin"),
    ("ウィスパー", "wisupaa"),
    ("フィルム", "firumu"),
    ("ティーン", "tiin"),
    ("ディスク", "disuku"),
    ("クァルテット", "kwarutetto"),
    ("しんよう", "shin'you"),   // ん 后接元音 → 隔音符
    ("きんえん", "kin'en"),
    ("しんぶん", "shinbun"),    // 后接辅音不加
    ("ずっと", "zutto"),
    ("がっこう", "gakkou"),
    ("まっちゃ", "matcha"),
    ("コーヒー", "koohii"),     // 长音写双元音，不用 macron
    ("こんにちは", "konnichiha"),
    ("を", "wo")
]
for kana in kanaCases {
    var pending = false
    let got = japaneseKanaRomaji(kana.input, pendingGeminate: &pending)
    require(got == kana.expected, "kana: \(kana.input) → \(got) (expected \(kana.expected))")
}

// 未映射假名的两种策略：显示层保留、修复路径丢掉（契约不同，别混）。
var pendingKeep = false
require(japaneseKanaRomaji("ゐ", pendingGeminate: &pendingKeep) == "ゐ",
        "unmapped kana is kept by default")
var pendingDrop = false
require(japaneseKanaRomaji("ゐ", pendingGeminate: &pendingDrop, unmapped: .drop) == "",
        "unmapped kana is dropped on request")

// MARK: - 结果

if failures == 0 {
    print("JapaneseRomajiRepair: all assertions passed")
} else {
    print("JapaneseRomajiRepair: \(failures) assertion(s) FAILED")
    exit(1)
}

