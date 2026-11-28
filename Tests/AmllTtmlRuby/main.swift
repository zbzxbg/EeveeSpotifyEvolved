import Foundation

// MARK: - AMLL TTML 的 ruby 注音与实际 parser → mapper 回归
//
// 跑法（CI 里就是这条，见 `.github/workflows/tests.yml`）：
//   swiftc Sources/EeveeSpotify/Lyrics/Models/Amll/AmllTtmlDocument.swift \
//          Sources/EeveeSpotify/Lyrics/Models/Amll/AmllTtmlParser.swift \
//          Sources/EeveeSpotify/Lyrics/Models/Amll/AmllLyricsMapper.swift \
//          Sources/EeveeSpotify/Lyrics/Models/Amll/AmllRomanizationWords.swift \
//          Sources/EeveeSpotify/Lyrics/Models/LyricsError.swift \
//          Sources/EeveeSpotify/Lyrics/Models/LyricsWordDto.swift \
//          Sources/EeveeSpotify/Lyrics/Models/LyricsBackgroundVocalDto.swift \
//          Sources/EeveeSpotify/Lyrics/Models/LyricsLineDto.swift \
//          Sources/EeveeSpotify/Lyrics/Models/LyricsTranslationDto.swift \
//          Sources/EeveeSpotify/Lyrics/Models/LyricsRomanizationStatus.swift \
//          Sources/EeveeSpotify/Lyrics/Models/LyricsMatch.swift \
//          Sources/EeveeSpotify/Lyrics/Repositories/LyricsMarkers.swift \
//          Tests/AmllTtmlRuby/main.swift \
//          -o amll-ttml-ruby-tests
//   ./amll-ttml-ruby-tests
//
// 两种写法都要成立（细节见 `MEMORY_2026-10-16_EeveeSpotify-ng_AMLL-TTML-Gaps.md` §一·③）：
//
//   ① **AMLL 真正的写法** —— `tts:ruby` 属性（官方文档 https://amll.dev/guides/lyric/ttml
//      的「Ruby 注音」一节）：
//        <span tts:ruby="container">
//          <span tts:ruby="base">所</span>
//          <span tts:ruby="textContainer">
//            <span tts:ruby="text" begin="00:27.690" end="00:27.820">しょ</span>
//          </span>
//        </span>
//      正文（base）与注音**都没有 begin/end**，时间只挂在 `tts:ruby="text"` 上。
//      不特判的后果是**正文丢了**（容器被整段跳过），而 `plainText` 会把注音拼进来
//      ⇒ 屏幕上那一行变成「所しょ詮せん」。
//
//   ② HTML 风格 `<ruby>漢<rt>かん</rt></ruby>`（别的工具可能这么导出）—— `<rt>` 的读音
//      不能进正文。
//
// 顺带钉住"没有注音的行一个字节都不变"，免得跳过注音的判据写宽了、把正常文本也吃掉。

// 以下仅是其它平台依赖的测试外壳：实际 LyricsDto.swift 带 NaturalLanguage / Spotify
// 及显示层依赖，无法独立编译。保留 mapper 所需成员及其原始初始化顺序，不模拟映射逻辑。
// parser、mapper、LyricsLineDto / Word / BackgroundVocal / Translation、罗马化状态与
// AmllRomanizationWords 均编译生产文件；本地语言识别/日文分词不在这组断言的覆盖范围内。
struct LyricsDto {
    var lines: [LyricsLineDto]
    var timeSynced: Bool
    var romanization: LyricsRomanizationStatus
    var translation: LyricsTranslationDto? = nil
    var languageCode: String? = nil
    var officialRomanizedLines: [String] = []
    var officialRomanizedWordGroups: [[String]] = []
    var providerCredit: String = ""
}

func writeDebugLog(_ message: String) {}

extension Array where Element == String {
    var romanizationLanguageCode: String? { nil }
    var canBeRomanized: Bool { false }
}

extension String {
    var localized: String { self }

    func japaneseRomajiChunks() -> [(range: NSRange, romaji: String)] { [] }
}

var failures = 0

func require(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)")
    }
}

func requireEqual(_ actual: Int, _ expected: Int, _ message: String) {
    if actual == expected {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message) — got \(actual), expected \(expected)")
    }
}

func requireEqual(_ actual: String, _ expected: String, _ message: String) {
    if actual == expected {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message) — got \(actual), expected \(expected)")
    }
}

// MARK: - ① `tts:ruby`（AMLL 的真写法）

let rubyStyledTtml = """
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:tts="http://www.w3.org/ns/ttml#styling" xml:lang="ja">
  <body dur="30s">
    <div>
      <p begin="20s" end="22s">
        <span tts:ruby="container"><span tts:ruby="base">所</span><span tts:ruby="textContainer"><span tts:ruby="text" begin="20.1s" end="20.4s">しょ</span></span></span><span tts:ruby="container"><span tts:ruby="base">詮</span><span tts:ruby="textContainer"><span tts:ruby="text" begin="20.4s" end="21s">せん</span></span></span>
      </p>
    </div>
  </body>
</tt>
"""

do {
    let parsed = try AmllTtmlParser.parse(rubyStyledTtml)

    require(parsed.lines.count == 1, "tts:ruby — one lyric line parsed (got \(parsed.lines.count))")

    if parsed.lines.count == 1 {
        let line = parsed.lines[0]
        requireEqual(line.primaryText, "所詮", "tts:ruby — the line text is the base text, not the reading")
        requireEqual(line.plainText, "所詮", "tts:ruby — plain text excludes <rt>/tts:ruby=text")
        requireEqual(line.syllables.count, 2, "tts:ruby — two syllables, one per container")
        requireEqual(
            line.syllables.map(\.text).joined(),
            "所詮",
            "tts:ruby — syllable join matches the line text"
        )
        if line.syllables.count == 2 {
            requireEqual(line.syllables[0].startMs, 20100, "tts:ruby — first syllable starts at the annotation time")
            requireEqual(line.syllables[0].endMs, 20400, "tts:ruby — first syllable ends at the annotation time")
            requireEqual(line.syllables[1].startMs, 20400, "tts:ruby — second syllable starts at the second annotation")
            requireEqual(line.syllables[1].endMs, 21000, "tts:ruby — second syllable ends at the second annotation")
        }
    }

    let dto = AmllLyricsMapper.makeDto(parsed)
    requireEqual(dto.lines.count, 1, "tts:ruby — 实际 mapper 保留该行")
    if dto.lines.count == 1 {
        requireEqual(dto.lines[0].content, "所詮", "tts:ruby — DTO 正文没有注音")
        requireEqual(dto.lines[0].words?.count ?? 0, 2, "tts:ruby — DTO 保留两个计时词")
        requireEqual(dto.lines[0].words?.map(\.text).joined() ?? "", "所詮", "tts:ruby — DTO 词与正文一致")
    }
} catch {
    failures += 1
    print("  FAIL tts:ruby parsing threw \(error)")
}

// 注音**完全没有时间**时：不产生词条，正文仍然要留下（走 plainText 那条）。
let rubyUntimedTtml = """
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:tts="http://www.w3.org/ns/ttml#styling" xml:lang="ja">
  <body>
    <div>
      <p begin="1s" end="3s">
        <span tts:ruby="container"><span tts:ruby="base">愛</span><span tts:ruby="textContainer"><span tts:ruby="text">あい</span></span></span>
      </p>
    </div>
  </body>
</tt>
"""

do {
    let parsed = try AmllTtmlParser.parse(rubyUntimedTtml)
    require(parsed.lines.count == 1, "untimed ruby — the line survives (got \(parsed.lines.count))")
    if parsed.lines.count == 1 {
        requireEqual(parsed.lines[0].primaryText, "愛", "untimed ruby — the base text is kept")
        requireEqual(parsed.lines[0].syllables.count, 0, "untimed ruby — no syllable without a timestamp")
    }

    let dto = AmllLyricsMapper.makeDto(parsed)
    requireEqual(dto.lines.count, 1, "untimed ruby — 实际 mapper 保留该行")
    if dto.lines.count == 1 {
        requireEqual(dto.lines[0].content, "愛", "untimed ruby — DTO 保留完整正文")
        require(dto.lines[0].words == nil, "untimed ruby — DTO 没有伪造逐词数据")
    }
} catch {
    failures += 1
    print("  FAIL untimed ruby parsing threw \(error)")
}

// MARK: - ② HTML 风格 `<ruby>/<rt>`

let ttml = """
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:itunes="http://itunes.apple.com/lyric-sync" xml:lang="ja">
  <body dur="10s">
    <div>
      <p begin="1s" end="3s" itunes:key="L1">
        <span begin="1s" end="2s"><ruby>漢<rt>かん</rt></ruby></span><span begin="2s" end="3s">字</span>
      </p>
      <p begin="4s" end="6s" itunes:key="L2">
        <span begin="4s" end="6s">読みなし</span>
      </p>
    </div>
  </body>
</tt>
"""

do {
    let parsed = try AmllTtmlParser.parse(ttml)

    require(parsed.lines.count == 2, "html ruby — two lyric lines parsed (got \(parsed.lines.count))")

    if parsed.lines.count == 2 {
        let withRuby = parsed.lines[0]
        requireEqual(withRuby.primaryText, "漢字", "html ruby — the <rt> reading is not part of the line text")
        requireEqual(withRuby.plainText, "漢字", "html ruby — plain text also excludes <rt>")
        requireEqual(withRuby.syllables.map(\.text).joined(), "漢字", "html ruby — syllable join matches the line text")
        requireEqual(withRuby.syllables.count, 2, "html ruby — two timed syllables survive")

        let withoutRuby = parsed.lines[1]
        requireEqual(withoutRuby.primaryText, "読みなし", "a line without ruby is untouched")
    }

    let dto = AmllLyricsMapper.makeDto(parsed)
    requireEqual(dto.lines.count, 2, "html ruby — 实际 mapper 保留两行")
    if dto.lines.count == 2 {
        requireEqual(dto.lines[0].content, "漢字", "html ruby — DTO 正文没有 rt 注音")
        requireEqual(dto.lines[0].words?.count ?? 0, 2, "html ruby — DTO 的逐词高亮数据仍保留")
        requireEqual(dto.lines[1].content, "読みなし", "html ruby — 普通行经过 mapper 后仍不变")
    }
} catch {
    failures += 1
    print("  FAIL html ruby parsing threw \(error)")
}

// MARK: - ③ 副唱 DTO 的 `translation`（§A·24）

let background = LyricsBackgroundVocalDto(
    syllables: [
        LyricsWordDto(text: "秘密", startMs: 30_500, endMs: 31_500),
        LyricsWordDto(text: "だよ", startMs: 31_600, endMs: 32_500),
    ],
    isBeforePrimary: false,
    translation: "是秘密哦"
)
requireEqual(background.text, "秘密だよ", "bg dto — the text is the syllables joined")
requireEqual(
    background.translation ?? "",
    "是秘密哦",
    "bg dto — the background vocal's own translation survives the DTO"
)
requireEqual(
    LyricsBackgroundVocalDto(
        syllables: [LyricsWordDto(text: "x", startMs: 0)],
        isBeforePrimary: true
    ).translation ?? "",
    "",
    "bg dto — translation defaults to nil when absent"
)

// MARK: - ④ 实际 parser → mapper：完整正文、副唱与并行数组对齐

// 四行中恰好两行有两个主词，满足 mapper 的 50% 逐词覆盖率闸门。
// 这样混合正文的 words == nil 是该行覆盖不完整造成的，不是整首降级掩盖了错误。
let mapperTtml = """
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xml:lang="en">
  <body>
    <div>
      <p begin="1s" end="4s">I <span begin="1.5s" end="2s">love</span>... you!<span ttm:role="x-translation" xml:lang="zh-Hans">我爱……你！</span></p>
      <p begin="5s" end="7s"><span ttm:role="x-bg"><span begin="5.1s" end="6s">Only </span><span begin="6s" end="6.9s">harmony</span><span ttm:role="x-translation">只有和声</span></span><span ttm:role="x-translation" xml:lang="zh-Hans">副唱行译文</span></p>
      <p begin="8s" end="10s"><span begin="8s" end="9s">Hello</span> <span begin="9s" end="10s">world</span><span ttm:role="x-bg" begin="8.25s" end="9.5s">Ooh!<span ttm:role="x-translation">哦！</span></span><span ttm:role="x-translation" xml:lang="zh-Hans">你好世界</span></p>
      <p begin="11s" end="13s"><span begin="11s" end="12s">Good</span> <span begin="12s" end="13s">night</span></p>
    </div>
  </body>
</tt>
"""

do {
    var parsed = try AmllTtmlParser.parse(mapperTtml)
    requireEqual(parsed.lines.count, 4, "parser→mapper — 四行都被解析，包括纯副唱")
    if parsed.lines.count == 4 {
        requireEqual(parsed.lines[0].plainText, "I love... you!", "混合正文 — parser 保留首尾未计时文本与标点")
        requireEqual(parsed.lines[0].primaryText, "I love... you!", "混合正文 — primaryText 使用完整正文")
        requireEqual(parsed.lines[0].syllables.count, 0, "混合正文 — 不完整的计时音节被清空")
        requireEqual(parsed.lines[1].primaryText, "", "纯副唱 — parser 主正文为空")
        requireEqual(parsed.lines[1].syllables.count, 0, "纯副唱 — 副唱音节不混入主词")
        requireEqual(parsed.lines[1].backgroundVocal?.text ?? "", "Only harmony", "纯副唱 — parser 保留副唱")
        requireEqual(parsed.lines[2].syllables.count, 2, "普通两词 — parser 保留 Hello world 逐词")
        requireEqual(parsed.lines[2].backgroundVocal?.syllables.count ?? 0, 1, "副唱容器计时 — parser 形成单 token")
    }

    let dto = AmllLyricsMapper.makeDto(parsed)
    requireEqual(dto.lines.count, 4, "parser→mapper — DTO 仍有四行，纯副唱未丢弃")
    require(dto.timeSynced, "parser→mapper — DTO 保持同步歌词")
    require(dto.translation?.lines == ["我爱……你！", "副唱行译文", "你好世界", ""], "parser→mapper — 译文按行对齐，缺译文留空")
    requireEqual(dto.translation?.languageCode ?? "", "zh", "parser→mapper — 使用真实译文 DTO 保存语言")
    if dto.lines.count == 4 {
        requireEqual(dto.lines[0].content, "I love... you!", "混合正文 — mapper 完整保留 I、love、尾文与标点")
        require(dto.lines[0].words == nil, "混合正文 — mapper 仅放弃不完整逐词数据")
        require(dto.lines[0].backgroundVocal == nil, "混合正文 — 没有其它行的副唱")

        let pureBackground = dto.lines[1]
        requireEqual(pureBackground.content, "", "纯副唱 — DTO 主正文仍为空")
        require(pureBackground.words == nil, "纯副唱 — DTO 不生成主词")
        requireEqual(pureBackground.backgroundVocal?.text ?? "", "Only harmony", "纯副唱 — DTO 副唱完整保留")
        requireEqual(pureBackground.backgroundVocal?.syllables.count ?? 0, 2, "纯副唱 — DTO 副唱保留两个计时词")
        requireEqual(pureBackground.backgroundVocal?.translation ?? "", "只有和声", "纯副唱 — 自己的译文与主行译文分开")
        require(!pureBackground.isBlankForDisplay, "纯副唱 — 真实 LyricsLineDto 不把它视为空行")

        let ordinary = dto.lines[2]
        requireEqual(ordinary.content, "Hello world", "普通两词 — mapper 不改变正文与词间空格")
        requireEqual(ordinary.words?.count ?? 0, 2, "普通两词 — DTO 仍有逐词数据，覆盖率闸门确实打开")
        require(ordinary.words?.map(\.text) == ["Hello ", "world"], "普通两词 — DTO 词拼回完整正文")
        require(ordinary.words?.map(\.startMs) == [8000, 9000], "普通两词 — 开始时间保持不变")
        require(ordinary.words?.map(\.endMs) == [9000, 10000], "普通两词 — 结束时间保持不变")
        requireEqual(ordinary.backgroundVocal?.text ?? "", "Ooh!", "副唱容器计时 — DTO 保留正文")
        requireEqual(ordinary.backgroundVocal?.syllables.count ?? 0, 1, "副唱容器计时 — DTO 保留单 token")
        require(ordinary.backgroundVocal?.syllables.first?.startMs == 8250, "副唱容器计时 — 使用自己的 begin 而非主行时间")
        require(ordinary.backgroundVocal?.syllables.first?.endMs == 9500, "副唱容器计时 — 使用自己的 end 而非主行时间")
        requireEqual(ordinary.backgroundVocal?.translation ?? "", "哦！", "副唱容器计时 — 自己的译文保留")
        requireEqual(dto.lines[3].words?.count ?? 0, 2, "普通第二行 — 逐词数据保留，保证 50% 覆盖率")
        require(dto.lines[3].backgroundVocal == nil, "普通第二行 — 副唱保持 nil")
    }

    // parser 会先剔除空行，故手工插入中间结构来实际触发 mapper 的 skip 分支。
    parsed.lines.insert(
        AmllTtmlLine(
            key: nil,
            offsetMs: 0,
            endMs: 500,
            syllables: [],
            plainText: " \n ",
            translation: "被跳过的行不应占译文位置",
            translationLanguage: "zh-Hans",
            romanization: nil,
            backgroundVocal: nil,
            agent: nil
        ),
        at: 0
    )
    let afterBlank = AmllLyricsMapper.makeDto(parsed)
    requireEqual(afterBlank.lines.count, 4, "首空行 — mapper 确实跳过手工插入的空行")
    require(afterBlank.lines.map(\.content) == dto.lines.map(\.content), "首空行 — 主正文顺序不变")
    require(afterBlank.lines.map(\.offsetMs) == dto.lines.map(\.offsetMs), "首空行 — 行开始时间不串位")
    require(afterBlank.lines.map(\.endOffsetMs) == dto.lines.map(\.endOffsetMs), "首空行 — 行结束时间不串位")
    require(afterBlank.lines.map { $0.words?.map(\.text) } == dto.lines.map { $0.words?.map(\.text) }, "首空行 — words 的内容与 nil 占位不串位")
    require(afterBlank.lines.map { $0.words?.map(\.startMs) } == dto.lines.map { $0.words?.map(\.startMs) }, "首空行 — words 开始时间不串位")
    require(afterBlank.lines.map { $0.words?.map(\.endMs) } == dto.lines.map { $0.words?.map(\.endMs) }, "首空行 — words 结束时间不串位")
    require(afterBlank.lines.map { $0.backgroundVocal?.text } == dto.lines.map { $0.backgroundVocal?.text }, "首空行 — 副唱内容与 nil 占位不串位")
    require(afterBlank.lines.map { $0.backgroundVocal?.syllables.map(\.startMs) } == dto.lines.map { $0.backgroundVocal?.syllables.map(\.startMs) }, "首空行 — 副唱开始时间不串位")
    require(afterBlank.lines.map { $0.backgroundVocal?.syllables.map(\.endMs) } == dto.lines.map { $0.backgroundVocal?.syllables.map(\.endMs) }, "首空行 — 副唱结束时间不串位")
    require(afterBlank.lines.map { $0.backgroundVocal?.translation } == dto.lines.map { $0.backgroundVocal?.translation }, "首空行 — 副唱自己的译文不串位")
    require(afterBlank.lines.map { $0.backgroundVocal?.isBeforePrimary } == dto.lines.map { $0.backgroundVocal?.isBeforePrimary }, "首空行 — 副唱位置不串位")
    require(afterBlank.translation?.lines == dto.translation?.lines, "首空行 — 译文与缺失占位不串位")
    require(afterBlank.translation?.languageCode == dto.translation?.languageCode, "首空行 — 译文语言不变")
} catch {
    failures += 1
    print("  FAIL parser→mapper — 解析抛错 \(error)")
}

if failures == 0 {
    print("AmllTtmlRuby: all assertions passed")
} else {
    print("AmllTtmlRuby: \(failures) failure(s)")
    exit(1)
}
