import Foundation

// MARK: - SpicyLyrics 官方 v1 API 的 JSON → SLObjPackValue 映射
//
// 为什么要有这个测试：`SpicyLyricsRepository` 从内部 `/query`（SLObjPack 打包格式）
// 搬到了官方 `GET /v1/lyrics/<trackId>`（**普通 JSON**），中间的桥就是
// `SLObjPackValue.fromJSON`（`Sources/EeveeSpotify/Lyrics/Repositories/SLObjPack.swift`）。
// 而 `SpicyLyricsRepository` 本身带 Orion / UIKit 依赖，进不了这里 —— 所以把**最容易错、
// 又完全自洽**的这一步单独钉住。
//
// 钉的是一件事：**布尔与数字不能互相污染**。
//   · JSON 的 `true/false` 在 Darwin 上是 `__NSCFBoolean`，也是 NSNumber —— 不区分就会把
//     `IsPartOfWord` 读成数字，逐词断句全错；
//   · 反过来，`StartTime: 1` 这种**整数值**若被判成布尔，`doubleValue` 拿到 nil，
//     那一行就丢了时间轴。
//
// 跑法（CI 里就是这条）：
//   swiftc Sources/EeveeSpotify/Lyrics/Repositories/SLObjPack.swift \
//          Tests/SpicyLyricsJsonMapping/main.swift -o spicy-lyrics-json-mapping-tests

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError("FAIL: \(message)")
    }
}

private func isNull(_ value: SLObjPackValue?) -> Bool {
    guard let value = value else { return false }
    if case .null = value { return true }
    return false
}

/// 从真机响应里裁的一小段：外层 `Body`，Body 里 `Type` / `Content`，
/// 每条 Content 是 `{Type, OppositeAligned, Lead:{Text|Syllables}}`，可带 `Background`。
private let fixture = """
{
  "Body": {
    "Type": "Syllable",
    "StartTime": 19.794,
    "source": "apple_music",
    "HasTransliterations": false,
    "UploadAttribution": null,
    "Content": [
      {
        "Type": "Vocal",
        "OppositeAligned": false,
        "Lead": {
          "Text": "We're no strangers to love",
          "StartTime": 19.794,
          "EndTime": 23.048,
          "Syllables": [
            {"Text": "We're", "IsPartOfWord": false, "StartTime": 19.794, "EndTime": 20.086},
            {"Text": "no", "IsPartOfWord": true, "StartTime": 20.086, "EndTime": 20.336}
          ]
        },
        "Background": []
      },
      {"Type": "Interlude", "Lead": {"StartTime": 1}}
    ]
  },
  "Status": 200,
  "Type": "object"
}
"""

// MARK: - 真实响应形状

let json = try! JSONSerialization.jsonObject(with: Data(fixture.utf8)) as! [String: Any]
let root = SLObjPackValue.fromJSON(json["Body"] as! [String: Any])

require(root["Type"]?.stringValue == "Syllable", "Body.Type 必须是 Syllable")
require(root["source"]?.stringValue == "apple_music", "source 要能读出来（署名/排查用）")

// 布尔就得是布尔，而且**不能**同时是数字。
require(root["HasTransliterations"]?.boolValue == false, "HasTransliterations=false 要读成 .bool")
require(root["HasTransliterations"]?.doubleValue == nil, "布尔不许被读成数字")

// 空数组 / null 两种"空"要分得开。
require(root["Content"]?[0]?["Background"]?.arrayValue?.isEmpty == true, "空数组要读成 .array([])")
require(isNull(root["UploadAttribution"]), "JSON null 要读成 .null")

// 逐词：`IsPartOfWord` 是布尔，时间戳是数字 —— 两条链都要能走通。
let syllables = root["Content"]?[0]?["Lead"]?["Syllables"]
require(syllables?.arrayValue?.count == 2, "Syllables 要能取到 2 条")
require(syllables?[0]?["Text"]?.stringValue == "We're", "第 1 个音节的 Text")
require(syllables?[0]?["IsPartOfWord"]?.boolValue == false, "IsPartOfWord=false（新词）")
require(syllables?[1]?["IsPartOfWord"]?.boolValue == true, "IsPartOfWord=true（续接上一个词）")
require(syllables?[0]?["StartTime"]?.doubleValue == 19.794, "音节开始时间")
require(syllables?[1]?["EndTime"]?.doubleValue == 20.336, "音节结束时间")

// ★ 整数值的坑：`"StartTime": 1` 必须还是数字。
require(
    root["Content"]?[1]?["Lead"]?["StartTime"]?.doubleValue == 1,
    "整数值 1 要读成 .number（否则这一行会丢时间轴）"
)
require(
    root["Content"]?[1]?["Lead"]?["StartTime"]?.boolValue == nil,
    "整数值 1 不许被读成布尔"
)

// MARK: - 直接喂 NSNumber 的两个方向

let numberOne = SLObjPackValue.fromJSON(NSNumber(value: 1))
require(numberOne.doubleValue == 1, "NSNumber(1) → .number")
require(numberOne.boolValue == nil, "NSNumber(1) 不许同时是布尔")

let boolTrue = SLObjPackValue.fromJSON(NSNumber(value: true))
require(boolTrue.boolValue == true, "NSNumber(true) → .bool")
require(boolTrue.doubleValue == nil, "NSNumber(true) 不许同时是数字")

let decimal = SLObjPackValue.fromJSON(NSNumber(value: 1.5))
require(decimal.doubleValue == 1.5, "小数 → .number")

// MARK: - 音节拼接规则（`SpicySyllableText`）：`IsPartOfWord` 是**前瞻**的
//
// 判断第 i 个音节前要不要空格，看的是**第 i-1 个**音节那一位。
// 下面四条都是 2026-10-13 从官方 v1 API 取回的真实数据形状；右边那列是
// 「看自己那一位」的错读法会拼出来的东西 —— 实测 7 首曲目 423 行里 153 行受影响。

/// 造音节：直接吃 JSON，与线上路径（JSONSerialization → `fromJSON`）逐字一致。
///
/// ⚠️ 名字**不叫** `syllables` —— 上面已经有一个同名的局部量（`let syllables = …`），
/// 顶层同名函数/变量是否算重声明要看编译器心情，不冒这个险。
private func syllableValues(_ json: String) -> [SLObjPackValue] {
    let raw = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [Any]
    return raw.map { SLObjPackValue.fromJSON($0) }
}

let longEnough = syllableValues(
    #"[{"Text":"long","IsPartOfWord":false},{"Text":"e","IsPartOfWord":true},{"Text":"nough","IsPartOfWord":false}]"#
)
require(
    SpicySyllableText.joined(longEnough) == "long enough",
    "前瞻规则：long|e|nough → long enough（错读法会给 longe nough）"
)

let feelin = syllableValues(
    #"[{"Text":"how","IsPartOfWord":false},{"Text":"I'm","IsPartOfWord":false},{"Text":"feel","IsPartOfWord":true},{"Text":"in'","IsPartOfWord":false}]"#
)
require(
    SpicySyllableText.joined(feelin) == "how I'm feelin'",
    "前瞻规则：how|I'm|feel|in' → how I'm feelin'（错读法会给 I'mfeel in'）"
)

let ooh = syllableValues(#"[{"Text":"Ooh-","IsPartOfWord":true},{"Text":"ooh,","IsPartOfWord":false}]"#)
require(
    SpicySyllableText.joined(ooh) == "Ooh-ooh,",
    "前瞻规则：Ooh-|ooh, → Ooh-ooh,（错读法会给 Ooh- ooh,）"
)

// 每个词都标 false ⇒ 词与词之间照常留空格（Apple Music 源就是这个形状）。
let strangers = syllableValues(
    #"[{"Text":"We're","IsPartOfWord":false},{"Text":"no","IsPartOfWord":false},{"Text":"strangers","IsPartOfWord":false}]"#
)
require(
    SpicySyllableText.joined(strangers) == "We're no strangers",
    "全 false 时要按词留空格"
)

// 逐字高亮那一份必须与整行**逐字一致**（`LyricLinesAdapter` 依赖这条不变量：
// 行文本用 `content`，音节时间轴用 words，两者对不上就会整行漂移）。
require(
    SpicySyllableText.words(feelin).map(\.text).joined() == SpicySyllableText.joined(feelin),
    "words 拼回来必须等于 joined（同一套前瞻判据）"
)
require(
    SpicySyllableText.words(feelin).map(\.text) == ["how", " I'm", " feel", "in'"],
    "words 的前导空格要落在「新词」上"
)
require(
    SpicySyllableText.words(longEnough).map(\.text) == ["long", " e", "nough"],
    "words：e 是新词的开头（前一个 flag 为 false）"
)

// 空白音节不参与高亮（但仍要推进前瞻状态）。
//
// ⚠️ 这里**不**断言空白音节前后的空格个数：那取决于上游数据里到底有没有独立的空白
// 音节、以及它与前瞻标志怎么组合，我们没有实测样本 -> 只钉住"空白不进高亮列表"。
let withBlank = syllableValues(
    #"[{"Text":"never","IsPartOfWord":false},{"Text":" ","IsPartOfWord":true},{"Text":"gonna","IsPartOfWord":false}]"#
)
let blankWords = SpicySyllableText.words(withBlank)
require(blankWords.count == 2, "空白音节不进高亮列表")
require(blankWords.first?.text == "never", "第一个词不带前导空格")
require(blankWords.last?.text.hasSuffix("gonna") == true, "第二个词是 gonna")
require(
    SpicySyllableText.joined(withBlank).contains("never") && SpicySyllableText.joined(withBlank).contains("gonna"),
    "空白音节不该把实词吞掉"
)

// MARK: - 署名规则（Spicy Lyrics 服务条款 §6）
//
// "条款合规"里最容易悄悄改坏的一块：哪个 `source` 要署谁、URL 取哪个字段。
// 形状取自真实响应（`Body.UploadAttribution.Uploader` / `Maker`）。
// ⚠️ 这一段**故意**只测 Foundation-only 的那两个文件：展示用的角色名（`.localized`）
// 在 `LyricsContributor+Display.swift` 里，带 UIKit 依赖，进不了这里。

let communityAttribution = SLObjPackValue.fromJSON([
    "Maker": [
        "username": "budget_tiger_shark.ts",
        "url": "https://spicylyrics.org/uid/816650334255579137",
    ] as [String: Any],
    "Uploader": [
        "username": "spikerko",
        "url": "https://spicylyrics.org/uid/790942393255329803",
    ] as [String: Any],
] as [String: Any])

let community = SpicyLyricsAttribution.contributors(attribution: communityAttribution)
require(community.count == 2, "社区同步要给出 maker + uploader 两条")
require(community[0].role == .maker, "顺序：先 maker（与上游一致）")
require(community[0].name == "budget_tiger_shark.ts", "maker 名字")
require(
    community[0].url?.absoluteString == "https://spicylyrics.org/uid/816650334255579137",
    "maker 链接要原样取出来（条款 §6 要求用它当链接目标）"
)
require(community[1].role == .uploader && community[1].name == "spikerko", "uploader 名字")
require(community[1].url?.host == "spicylyrics.org", "uploader 链接")

// 商业源（apple_music / spotify）根本没有这个节点 ⇒ 一条都不许编。
require(
    SpicyLyricsAttribution.contributors(attribution: nil).isEmpty,
    "没有 UploadAttribution 时不许编造贡献者"
)

// username 一定有，url 可以缺。
let makerOnly = SpicyLyricsAttribution.contributors(
    attribution: SLObjPackValue.fromJSON([
        "Maker": ["username": "someone"] as [String: Any],
    ] as [String: Any])
)
require(makerOnly.count == 1 && makerOnly[0].name == "someone", "只有 username 也要能署名")
require(makerOnly[0].url == nil, "没有 url 就是 nil（不给假链接）")

// 非 http(s) 的 url 一律丢掉 —— 它会被 `UIApplication.open` 直接打开。
let dangerous = SpicyLyricsAttribution.contributors(
    attribution: SLObjPackValue.fromJSON([
        "Uploader": ["username": "someone", "url": "javascript:alert(1)"] as [String: Any],
    ] as [String: Any])
)
require(dangerous.count == 1, "危险的 url 不该连名字一起丢掉")
require(dangerous[0].url == nil, "非 http(s) 的 url 必须丢掉")

// provider 本身（协议里"永远要写出回答的 provider"那一半）。
require(SpicyLyricsAttribution.providerName == "Spicy Lyrics", "provider 名")
require(SpicyLyricsAttribution.providerURL?.host == "spicylyrics.org", "provider 站点")

print("SpicyLyricsJsonMapping tests passed")