import Foundation

// MARK: - Apple Music **官方** TTML 的兼容性（「实验 → 启用Apple Music官方 TTML 歌词」）
//
// 跑法（CI 里就是这条，见 `.github/workflows/tests.yml`）：
//   swiftc Sources/EeveeSpotify/Lyrics/Models/Amll/AmllTtmlDocument.swift \
//          Sources/EeveeSpotify/Lyrics/Models/Amll/AmllTtmlParser.swift \
//          Sources/EeveeSpotify/Lyrics/Models/LyricsError.swift \
//          Sources/EeveeSpotify/Lyrics/Models/LyricsWordDto.swift \
//          Sources/EeveeSpotify/Lyrics/Models/LyricsBackgroundVocalDto.swift \
//          Sources/EeveeSpotify/Lyrics/Repositories/LyricsMarkers.swift \
//          Tests/AmllTtmlApple/main.swift -o amll-ttml-apple-tests
//
// 这一路**不新增解析器**：Apple 的 TTML 与 AMLL 的 TTML 是同一个格式家族，
// 复用 `AmllTtmlParser`。本测试钉住三处**苹果特有、而我们曾经会踩空**的写法：
//
//   ① `<p>` 上**不带 begin/end**，时间只挂在 `<span>` 上（苹果的 `syllable-lyrics` 里
//      很常见）。以前的行判据是 `guard let startMs = parseTimeMs(node.attribute("begin"))`
//      ⇒ 那种文件会被整首丢光（表现为"实验打开了却永远没词"）。现在退回首个 span 的 begin。
//   ② 译文侧挂的**第二种写法**：`for` 在 `<translation>` 容器上、正文直接是子文本
//      （`<translation xml:lang="ja" for="L2">さよなら</translation>`）。
//      以前只认 `<text for="L1">…</text>` ⇒ 这种文件译文整首丢失。
//   ③ 背景人声 `ttm:role="x-bg"` 不能进主行文本，要作为副唱单独带出来。
//
// 顺带钉住"逐行（Line）文件照旧能解析"，免得上面两处回退把普通文件带偏。

func writeDebugLog(_ message: String) {}

extension String {
    var localized: String { self }
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
        print("  FAIL \(message) — got \"\(actual)\", expected \"\(expected)\"")
    }
}

// MARK: - ① + ② + ③ 苹果的 syllable-lyrics（`<p>` 没有 begin/end）

let appleWordTtml = """
<?xml version="1.0" encoding="UTF-8"?>
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:itunes="http://itunes.apple.com/lyric-sync" xml:lang="en" itunes:timing="Word">
  <head>
    <metadata>
      <iTunesMetadata>
        <translations type="subtitle">
          <translation xml:lang="zh-Hans"><text for="L1">你好，世界</text></translation>
          <translation xml:lang="ja" for="L2">さよなら</translation>
        </translations>
      </iTunesMetadata>
    </metadata>
  </head>
  <body dur="3:00.000">
    <div begin="0:12.345" end="0:15.678">
      <p itunes:key="L1">
        <span begin="0:12.345" end="0:12.800">Hello</span> <span begin="0:12.800" end="0:13.200">world</span>
      </p>
      <p itunes:key="L2">
        <span begin="0:13.200" end="0:13.900">goodbye</span>
        <span ttm:role="x-bg"><span begin="0:13.900" end="0:14.400">(ooh)</span></span>
      </p>
    </div>
  </body>
</tt>
"""

do {
    let parsed = try AmllTtmlParser.parse(appleWordTtml)

    require(parsed.lines.count == 2, "apple word TTML — two lines parsed (got \(parsed.lines.count))")
    requireEqual(parsed.language ?? "", "en", "apple word TTML — xml:lang survives")
    requireEqual(parsed.declaredDurationMs ?? -1, 180_000, "apple word TTML — body dur parsed")

    if parsed.lines.count == 2 {
        let first = parsed.lines[0]

        // ① `<p>` 没有 begin/end ⇒ 时间从 span 上反推。
        requireEqual(
            first.offsetMs,
            12_345,
            "p without begin — offset falls back to the first timed span"
        )
        requireEqual(
            first.endMs ?? -1,
            13_200,
            "p without end — end falls back to the last timed span"
        )
        requireEqual(first.primaryText, "Hello world", "word spans join into the line text")
        requireEqual(
            first.syllables.map(\.text).joined(),
            "Hello world",
            "word-level syllables keep the inter-word space"
        )
        require(first.syllables.count == 2, "word-level syllables counted (got \(first.syllables.count))")

        // ② `<text for>` 这种最常见写法。
        requireEqual(first.translation ?? "", "你好，世界", "translation from <text for>")
        requireEqual(first.translationLanguage ?? "", "zh-Hans", "translation language kept")

        let second = parsed.lines[1]
        requireEqual(second.offsetMs, 13_200, "second line offset from its first span")
        requireEqual(second.primaryText, "goodbye", "x-bg text is not part of the main line")

        // ② 的第二种写法：`for` 挂在 `<translation>` 容器上。
        requireEqual(
            second.translation ?? "",
            "さよなら",
            "translation whose `for` sits on the container itself"
        )
        requireEqual(second.translationLanguage ?? "", "ja", "container-level translation language kept")

        // ③ 副唱单独带出来，且是"行内副唱"（不在主词之前）。
        requireEqual(
            second.backgroundVocal?.text ?? "",
            "(ooh)",
            "background vocal captured separately"
        )
        require(second.backgroundVocal?.isBeforePrimary == false, "background vocal is after the main words")
    }

    requireEqual(parsed.lastLineEndMs ?? -1, 13_900, "last line end = the maximum span end")
} catch {
    failures += 1
    print("  FAIL apple word TTML parsing threw \(error)")
}

// MARK: - 逐行（Line）文件：`<p begin/end>` + 直接文本，照旧要能解析

let appleLineTtml = """
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://itunes.apple.com/lyric-sync" xml:lang="en" itunes:timing="Line">
  <body dur="0:40.000">
    <div>
      <p begin="0:01.000" end="0:03.000" itunes:key="L1">Just a line</p>
      <p begin="0:04.000" end="0:06.000" itunes:key="L2">Another line</p>
    </div>
  </body>
</tt>
"""

do {
    let parsed = try AmllTtmlParser.parse(appleLineTtml)
    require(parsed.lines.count == 2, "apple line TTML — two lines parsed (got \(parsed.lines.count))")

    if parsed.lines.count == 2 {
        requireEqual(parsed.lines[0].primaryText, "Just a line", "line text kept")
        requireEqual(parsed.lines[0].offsetMs, 1_000, "line-level offset")
        requireEqual(parsed.lines[0].endMs ?? -1, 3_000, "line-level end")
        require(parsed.lines[0].syllables.isEmpty, "a line without timed spans has no syllables")
    }
} catch {
    failures += 1
    print("  FAIL apple line TTML parsing threw \(error)")
}

// MARK: - 译文语言：同一行挂多轨译文时按设置挑
//
// AMLL 的译文只能从**文件自带的那几轨**里挑（mxm 那条是向服务端要 `selected_language`）：
// mxm 那条是**向服务端要**（`selected_language`），AMLL 只能在**文件自带的那几轨**里挑。
// 所以这一组钉三件事：
// ① 不指定语言时行为不变（还是 zh-Hans → 中文 → 英文 → 其他）；
// ② 指定 `en` 就取英文那一轨；
// ③ 指定文件里**没有**的语言（`ja`）时退回 ①，不能变成空译文。

let multiLanguageTtml = """
<?xml version="1.0" encoding="UTF-8"?>
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://itunes.apple.com/lyric-sync" xml:lang="ja">
  <head>
    <metadata>
      <iTunesMetadata>
        <translations type="subtitle">
          <translation xml:lang="zh-Hans"><text for="L1">你好</text></translation>
          <translation xml:lang="en"><text for="L1">Hello</text></translation>
          <translation xml:lang="ko"><text for="L1">안녕</text></translation>
        </translations>
      </iTunesMetadata>
    </metadata>
  </head>
  <body>
    <div>
      <p itunes:key="L1" begin="0:00.000" end="0:02.000">こんにちは</p>
    </div>
  </body>
</tt>
"""

do {
    let auto = try AmllTtmlParser.parse(multiLanguageTtml)
    requireEqual(
        auto.lines.first?.translation ?? "",
        "你好",
        "no language preference — Simplified Chinese still wins"
    )
    requireEqual(auto.lines.first?.translationLanguage ?? "", "zh-Hans", "auto pick keeps its language")

    let english = try AmllTtmlParser.parse(multiLanguageTtml, translationLanguage: "en")
    requireEqual(english.lines.first?.translation ?? "", "Hello", "preferring `en` picks the English track")
    requireEqual(english.lines.first?.translationLanguage ?? "", "en", "picked track reports `en`")

    // 短码 `zh` 要能命中 `zh-Hans`（前缀匹配，见 `AmllTtmlParser.languageCodeMatches`）。
    let chinese = try AmllTtmlParser.parse(multiLanguageTtml, translationLanguage: "zh")
    requireEqual(chinese.lines.first?.translation ?? "", "你好", "a short code `zh` matches `zh-Hans`")

    // 文件里没有的语言 ⇒ 退回自动优先级，不能变成空。
    let missing = try AmllTtmlParser.parse(multiLanguageTtml, translationLanguage: "ja")
    requireEqual(
        missing.lines.first?.translation ?? "",
        "你好",
        "a language the file does not carry falls back to the automatic order"
    )

    // 空串 / 空白 = 自动（设置里清空输入框就是这条）。
    let blank = try AmllTtmlParser.parse(multiLanguageTtml, translationLanguage: "   ")
    requireEqual(blank.lines.first?.translation ?? "", "你好", "a blank preference means automatic")
} catch {
    failures += 1
    print("  FAIL multi-language translation parsing threw \(error)")
}

// MARK: - 没有时间轴的 `<p>` 依旧被丢掉（不伪造时间）

let untimedTtml = """
<tt xmlns="http://www.w3.org/ns/ttml">
  <body>
    <div>
      <p>no timing at all</p>
    </div>
  </body>
</tt>
"""

do {
    let parsed = try AmllTtmlParser.parse(untimedTtml)
    failures += 1
    print("  FAIL an untimed-only TTML should throw noSuchSong, but produced \(parsed.lines.count) line(s)")
} catch {
    print("  ok   an untimed-only TTML still throws (no fabricated timing)")
}

// MARK: - 侧挂辅助轨的混合计时正文也必须完整

let mixedSidecarTtml = """
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://itunes.apple.com/lyric-sync">
  <head><metadata><iTunesMetadata>
    <translation xml:lang="zh-Hans"><text for="L1"><span>你好，<span begin="1s" end="2s">世界</span></span></text></translation>
    <transliteration><text for="L1"><span>Hello <span begin="1s" end="2s">world</span></span>!</text></transliteration>
  </iTunesMetadata></metadata></head>
  <body><div><p itunes:key="L1" begin="1s" end="2s">Hello world</p></div></body>
</tt>
"""
do {
    let parsed = try AmllTtmlParser.parse(mixedSidecarTtml)
    requireEqual(parsed.lines.first?.translation ?? "", "你好，世界", "混合计时侧挂译文完整保留")
    requireEqual(parsed.lines.first?.romanization ?? "", "Hello world!", "混合计时侧挂音译完整保留")
} catch {
    failures += 1
    print("  FAIL mixed sidecar parsing threw \(error)")
}

// MARK: - 主词必须完整；不完整的逐词计时退回行级，包装 span 递归收集

let primaryTextCases: [(
    name: String,
    paragraph: String,
    text: String,
    startMs: Int,
    endMs: Int,
    syllables: [(text: String, startMs: Int, endMs: Int)]
)] = [
    (
        "直接正文在计时 span 前",
        "<p begin=\"0s\" end=\"4s\">Hello <span begin=\"1s\" end=\"2s\">world</span></p>",
        "Hello world", 0, 4_000, []
    ),
    (
        "直接正文在计时 span 后",
        "<p begin=\"0s\" end=\"4s\"><span begin=\"1s\" end=\"2s\">Hello</span> world</p>",
        "Hello world", 0, 4_000, []
    ),
    (
        "两个计时 span 间有正文",
        "<p begin=\"0s\" end=\"4s\"><span begin=\"1s\" end=\"2s\">Hello</span> dear <span begin=\"2s\" end=\"3s\">world</span></p>",
        "Hello dear world", 0, 4_000, []
    ),
    (
        "无时间 span 的正文不能丢失",
        "<p begin=\"0s\" end=\"4s\"><span>Hello </span><span begin=\"1s\" end=\"2s\">world</span></p>",
        "Hello world", 0, 4_000, []
    ),
    (
        "缺 end 的 span 使逐词计时整体降级",
        "<p begin=\"0s\" end=\"4s\"><span begin=\"1s\" end=\"2s\">Hello</span> <span begin=\"2s\">world</span></p>",
        "Hello world", 0, 4_000, []
    ),
    (
        "无时间包装 span 内完整计时",
        "<p begin=\"0s\" end=\"4s\"><span><span begin=\"1s\" end=\"2s\">Hello</span> <span begin=\"2s\" end=\"3s\">world</span></span></p>",
        "Hello world", 0, 4_000, [("Hello ", 1_000, 2_000), ("world", 2_000, 3_000)]
    ),
    (
        "多层包装且 p 无时间时递归反推行时间",
        "<p><span><span><span begin=\"1s\" end=\"2s\">Hello</span> <span begin=\"2s\" end=\"3s\">world</span></span></span></p>",
        "Hello world", 1_000, 3_000, [("Hello ", 1_000, 2_000), ("world", 2_000, 3_000)]
    ),
    (
        "包装 span 内有无时间正文时整体降级",
        "<p begin=\"0s\" end=\"4s\"><span>Hello <span><span begin=\"1s\" end=\"2s\">world</span></span></span></p>",
        "Hello world", 0, 4_000, []
    ),
    (
        "包装节点之间的空格并入前一个嵌套音节",
        "<p begin=\"0s\" end=\"4s\"><span><span begin=\"1s\" end=\"2s\">Hello</span></span> <span><span begin=\"2s\" end=\"3s\">world</span></span></p>",
        "Hello world", 0, 4_000, [("Hello ", 1_000, 2_000), ("world", 2_000, 3_000)]
    ),
    (
        "无 p 时间且计时覆盖不完整时保留反推时间与完整正文",
        "<p>Hello <span begin=\"1s\" end=\"2s\">world</span></p>",
        "Hello world", 1_000, 2_000, []
    ),
    (
        "CDATA 行级正文保留特殊字符",
        "<p begin=\"0s\" end=\"4s\"><![CDATA[Rock & <roll>]]></p>",
        "Rock & <roll>", 0, 4_000, []
    ),
    (
        "计时 span 中 CDATA 与普通文本按顺序拼接",
        "<p begin=\"0s\" end=\"4s\"><span begin=\"1s\" end=\"2s\">风<![CDATA[ & <雨>]]>!</span></p>",
        "风 & <雨>!", 0, 4_000, [("风 & <雨>!", 1_000, 2_000)]
    ),
    (
        "计时 span 间的 CDATA 正文不能被当作空白",
        "<p begin=\"0s\" end=\"4s\"><span begin=\"1s\" end=\"2s\">Hello</span><![CDATA[ & ]]><span begin=\"2s\" end=\"3s\">world</span></p>",
        "Hello & world", 0, 4_000, []
    )
]

for test in primaryTextCases {
    let xml = """
    <tt xmlns="http://www.w3.org/ns/ttml"><body><div>\(test.paragraph)</div></body></tt>
    """
    do {
        let parsed = try AmllTtmlParser.parse(xml)
        requireEqual(parsed.lines.count, 1, "\(test.name) — 仅保留一行")
        guard let line = parsed.lines.first else { continue }
        requireEqual(line.primaryText, test.text, "\(test.name) — 主词完整")
        requireEqual(line.plainText, test.text, "\(test.name) — plainText 完整")
        requireEqual(line.offsetMs, test.startMs, "\(test.name) — 行开始时间")
        requireEqual(line.endMs ?? -1, test.endMs, "\(test.name) — 行结束时间")
        requireEqual(parsed.lastLineEndMs ?? -1, test.endMs, "\(test.name) — 文档末行时间")
        requireEqual(line.syllables.count, test.syllables.count, "\(test.name) — 音节数量或整体降级")
        require(line.syllables.map(\.text) == test.syllables.map { $0.text }, "\(test.name) — 音节正文与空格")
        require(line.syllables.map(\.startMs) == test.syllables.map { $0.startMs }, "\(test.name) — 音节开始时间")
        require(line.syllables.map(\.endMs) == test.syllables.map { $0.endMs }, "\(test.name) — 音节结束时间")
    } catch {
        failures += 1
        print("  FAIL \(test.name) — XML 解析抛错 \(error)")
    }
}

// MARK: - 副唱纯行保留；容器计时与不完整副唱的整体时间降级

let backgroundVocalCases: [(
    name: String,
    paragraph: String,
    primaryText: String,
    text: String,
    startMs: Int,
    endMs: Int,
    primarySyllables: [(text: String, startMs: Int, endMs: Int)],
    backgroundSyllables: [(text: String, startMs: Int, endMs: Int)]
)] = [
    (
        "纯副唱行从子 span 反推时间",
        "<p><span ttm:role=\"x-bg\"><span begin=\"1s\" end=\"2s\">(ooh)</span></span></p>",
        "", "(ooh)", 1_000, 2_000, [], [("(ooh)", 1_000, 2_000)]
    ),
    (
        "纯副唱行由 x-bg 容器提供时间",
        "<p><span ttm:role=\"x-bg\" begin=\"1s\" end=\"3s\">(ooh)</span></p>",
        "", "(ooh)", 1_000, 3_000, [], [("(ooh)", 1_000, 3_000)]
    ),
    (
        "无独立时间的纯副唱使用父 p 时间",
        "<p begin=\"0s\" end=\"4s\"><span ttm:role=\"x-bg\">(ooh)</span></p>",
        "", "(ooh)", 0, 4_000, [], [("(ooh)", 0, 4_000)]
    ),
    (
        "有主词时 x-bg 容器直接正文形成单个音节",
        "<p begin=\"0s\" end=\"4s\"><span begin=\"1s\" end=\"2s\">Hello</span><span ttm:role=\"x-bg\" begin=\"2s\" end=\"4s\">(ooh)</span></p>",
        "Hello", "(ooh)", 0, 4_000, [("Hello", 1_000, 2_000)], [("(ooh)", 2_000, 4_000)]
    ),
    (
        "副唱混合正文计时不完整时使用容器整体时间",
        "<p begin=\"0s\" end=\"4s\"><span begin=\"1s\" end=\"2s\">Hello</span><span ttm:role=\"x-bg\" begin=\"2s\" end=\"4s\">Oh <span begin=\"2.5s\" end=\"3s\">yeah</span><span ttm:role=\"x-translation\">副唱译文</span><span ttm:role=\"x-roman\">oh yeah</span></span></p>",
        "Hello", "Oh yeah", 0, 4_000, [("Hello", 1_000, 2_000)], [("Oh yeah", 2_000, 4_000)]
    ),
    (
        "副唱混合正文计时不完整时使用父 p 整体时间",
        "<p begin=\"0s\" end=\"4s\"><span begin=\"1s\" end=\"2s\">Hello</span><span ttm:role=\"x-bg\">Oh <span begin=\"2s\" end=\"3s\">yeah</span></span></p>",
        "Hello", "Oh yeah", 0, 4_000, [("Hello", 1_000, 2_000)], [("Oh yeah", 0, 4_000)]
    ),
    (
        "副唱缺 end 的 span 使用父 p 整体时间",
        "<p begin=\"0s\" end=\"4s\"><span begin=\"1s\" end=\"2s\">Hello</span><span ttm:role=\"x-bg\"><span begin=\"2s\" end=\"3s\">Oh</span> <span begin=\"3s\">yeah</span></span></p>",
        "Hello", "Oh yeah", 0, 4_000, [("Hello", 1_000, 2_000)], [("Oh yeah", 0, 4_000)]
    ),
    (
        "副唱无时间包装内完整音节继续逐词",
        "<p begin=\"0s\" end=\"4s\"><span begin=\"1s\" end=\"2s\">Hello</span><span ttm:role=\"x-bg\"><span><span begin=\"2s\" end=\"3s\">Oh</span> <span begin=\"3s\" end=\"4s\">yeah</span></span></span></p>",
        "Hello", "Oh yeah", 0, 4_000, [("Hello", 1_000, 2_000)], [("Oh ", 2_000, 3_000), ("yeah", 3_000, 4_000)]
    ),
    (
        "副唱 CDATA 保留且不混入主词",
        "<p begin=\"0s\" end=\"4s\"><span begin=\"1s\" end=\"2s\">Hello</span><span ttm:role=\"x-bg\" begin=\"2s\" end=\"4s\"><![CDATA[Oh & <yeah>]]></span></p>",
        "Hello", "Oh & <yeah>", 0, 4_000, [("Hello", 1_000, 2_000)], [("Oh & <yeah>", 2_000, 4_000)]
    )
]

for test in backgroundVocalCases {
    let xml = """
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div>\(test.paragraph)</div></body></tt>
    """
    do {
        let parsed = try AmllTtmlParser.parse(xml)
        requireEqual(parsed.lines.count, 1, "\(test.name) — 副唱行未被丢弃")
        guard let line = parsed.lines.first else { continue }
        requireEqual(line.primaryText, test.primaryText, "\(test.name) — 副唱不进入主词")
        requireEqual(line.plainText, test.primaryText, "\(test.name) — 副唱不进入 plainText")
        requireEqual(line.offsetMs, test.startMs, "\(test.name) — 行开始时间")
        requireEqual(line.endMs ?? -1, test.endMs, "\(test.name) — 行结束时间")
        requireEqual(parsed.lastLineEndMs ?? -1, test.endMs, "\(test.name) — 文档末行时间")
        requireEqual(line.syllables.count, test.primarySyllables.count, "\(test.name) — 主词音节数量")
        require(line.syllables.map(\.text) == test.primarySyllables.map { $0.text }, "\(test.name) — 主词音节正文")
        require(line.syllables.map(\.startMs) == test.primarySyllables.map { $0.startMs }, "\(test.name) — 主词音节开始时间")
        require(line.syllables.map(\.endMs) == test.primarySyllables.map { $0.endMs }, "\(test.name) — 主词音节结束时间")
        require(line.backgroundVocal != nil, "\(test.name) — 副唱存在")
        guard let background = line.backgroundVocal else { continue }
        requireEqual(background.text, test.text, "\(test.name) — 副唱正文完整且排除辅助角色")
        requireEqual(background.syllables.count, test.backgroundSyllables.count, "\(test.name) — 副唱音节数量")
        require(background.syllables.map(\.text) == test.backgroundSyllables.map { $0.text }, "\(test.name) — 副唱音节正文")
        require(background.syllables.map(\.startMs) == test.backgroundSyllables.map { $0.startMs }, "\(test.name) — 副唱音节开始时间")
        require(background.syllables.map(\.endMs) == test.backgroundSyllables.map { $0.endMs }, "\(test.name) — 副唱音节结束时间")
    } catch {
        failures += 1
        print("  FAIL \(test.name) — XML 解析抛错 \(error)")
    }
}

// MARK: - ruby 的辅助角色必须在 ruby 特判之前过滤

for role in ["x-translation", "x-roman", "x-bg"] {
    let xml = """
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:tts="http://www.w3.org/ns/ttml#styling">
      <body><div><p begin="0s" end="4s"><span tts:ruby="container"><span tts:ruby="base">歌</span><span tts:ruby="textContainer"><span tts:ruby="text" begin="1s" end="2s">うた</span></span></span><span ttm:role="\(role)" tts:ruby="container" begin="2s" end="3s"><span tts:ruby="base">辅助</span><span tts:ruby="textContainer"><span tts:ruby="text" begin="2.2s" end="2.8s">ふじょ</span></span></span></p></div></body>
    </tt>
    """
    do {
        let parsed = try AmllTtmlParser.parse(xml)
        requireEqual(parsed.lines.count, 1, "ruby \(role) — 仅保留一行")
        guard let line = parsed.lines.first else { continue }
        requireEqual(line.primaryText, "歌", "ruby \(role) — 辅助正文与注音不进入主词")
        requireEqual(line.plainText, "歌", "ruby \(role) — plainText 只含 base")
        requireEqual(line.offsetMs, 0, "ruby \(role) — 父 p 开始时间保留")
        requireEqual(line.endMs ?? -1, 4_000, "ruby \(role) — 父 p 结束时间保留")
        requireEqual(line.syllables.count, 1, "ruby \(role) — 辅助 ruby 不形成主词音节")
        requireEqual(line.syllables.map(\.text).joined(), "歌", "ruby \(role) — 音节正文只含 base")
        if let syllable = line.syllables.first {
            requireEqual(syllable.startMs, 1_000, "ruby \(role) — 主词时间来自注音开始")
            requireEqual(syllable.endMs, 2_000, "ruby \(role) — 主词时间来自注音结束")
        }
        switch role {
        case "x-translation":
            requireEqual(line.translation ?? "", "辅助", "ruby 译文仍单独保留 base")
        case "x-roman":
            requireEqual(line.romanization ?? "", "辅助", "ruby 罗马音仍单独保留 base")
        default:
            requireEqual(line.backgroundVocal?.text ?? "", "辅助", "ruby 副唱仍单独保留 base")
            requireEqual(line.backgroundVocal?.syllables.count ?? -1, 1, "ruby 副唱容器形成单个音节")
            if let syllable = line.backgroundVocal?.syllables.first {
                requireEqual(syllable.text, "辅助", "ruby 副唱音节不含注音")
                requireEqual(syllable.startMs, 2_000, "ruby 副唱容器开始时间")
                requireEqual(syllable.endMs, 3_000, "ruby 副唱容器结束时间")
            }
        }
    } catch {
        failures += 1
        print("  FAIL ruby \(role) — XML 解析抛错 \(error)")
    }
}

// MARK: - 时间格式兼容性、非负边界与 Int32 毫秒上限；同时走原始 XML

let validTimeCases: [(raw: String, milliseconds: Int)] = [
    ("0", 0),
    ("0s", 0),
    ("0ms", 0),
    ("00:00.000", 0),
    ("0:00:00.000", 0),
    ("12.345", 12_345),
    ("12.3s", 12_300),
    ("500ms", 500),
    ("500.5ms", 501),
    (".5", 500),
    (".5s", 500),
    (".5ms", 1),
    ("1.", 1_000),
    ("0.0004s", 0),
    ("0.0005s", 1),
    ("34.010s", 34_010),
    ("1:02.189", 62_189),
    ("1:02:03.456", 3_723_456),
    (" 12.345s ", 12_345),
    ("2147483647ms", Int(Int32.max)),
    ("2147483.647s", Int(Int32.max)),
    ("2147483.647", Int(Int32.max)),
    ("35791:23.647", Int(Int32.max)),
    ("596:31:23.647", Int(Int32.max))
]

for test in validTimeCases {
    requireEqual(AmllTtmlParser.parseTimeMs(test.raw) ?? -1, test.milliseconds, "合法时间 \(test.raw) — 直接解析")
    let xml = """
    <tt xmlns="http://www.w3.org/ns/ttml"><body dur="\(test.raw)"><div><p begin="\(test.raw)" end="\(test.raw)"><span begin="\(test.raw)" end="\(test.raw)">Boundary</span></p></div></body></tt>
    """
    do {
        let parsed = try AmllTtmlParser.parse(xml)
        requireEqual(parsed.lines.count, 1, "合法时间 \(test.raw) — 原始 XML 保留一行")
        requireEqual(parsed.declaredDurationMs ?? -1, test.milliseconds, "合法时间 \(test.raw) — body dur")
        requireEqual(parsed.lastLineEndMs ?? -1, test.milliseconds, "合法时间 \(test.raw) — 文档末行时间")
        guard let line = parsed.lines.first else { continue }
        requireEqual(line.primaryText, "Boundary", "合法时间 \(test.raw) — 主词保留")
        requireEqual(line.offsetMs, test.milliseconds, "合法时间 \(test.raw) — p begin")
        requireEqual(line.endMs ?? -1, test.milliseconds, "合法时间 \(test.raw) — p end")
        requireEqual(line.syllables.count, 1, "合法时间 \(test.raw) — 零长度音节仍合法")
        if let syllable = line.syllables.first {
            requireEqual(syllable.text, "Boundary", "合法时间 \(test.raw) — 音节正文")
            requireEqual(syllable.startMs, test.milliseconds, "合法时间 \(test.raw) — span begin")
            requireEqual(syllable.endMs, test.milliseconds, "合法时间 \(test.raw) — span end")
        }
    } catch {
        failures += 1
        print("  FAIL 合法时间 \(test.raw) — XML 解析抛错 \(error)")
    }
}

require(AmllTtmlParser.parseTimeMs(nil) == nil, "缺失时间返回 nil")

let invalidTimeCases = [
    "", "   ",
    "-1", "-1s", "-1ms", "-0.0001s", "-0.1ms",
    "-1:00", "1:-01", "-1:00:00", "1:-01:00", "1:00:-01",
    "invalid:01:02", "NaN:01:02", "Infinity:01:02",
    ":01", "01:", "1::02", ":01:02", "1:02:", "::", "1:2:3:4",
    "1.5:00:00", "1.5:00", "1:0.5:00", "1:60", "1:60:00", "1:00:60",
    "1 :02", "1: 02", "1s:02", "1:00:02s", "1.2.3s",
    "NaN", "nan", "NaNs", "NaNms", "inf", "infinity", "Infinitys", "infms",
    "1:NaN", "1:Infinity", "1:00:NaN", "1:00:Infinity",
    "2147483648ms", "2147483647.5ms", "2147483.648s", "2147483.648", "35791:23.648", "596:31:23.648",
    String(repeating: "9", count: 400) + "ms",
    "999999999999999999999999999999999999999999999999999999999999999999ms",
    "999999999999999999999999999999999999999999999999999999999999999999s",
    "999999999999999999999999999999999999999999999999999999999999999999:00:00",
    "1e3", "1e3s", "1e3ms", "1e309s", "0x10", "1m", "ms", "s"
]

for raw in invalidTimeCases {
    require(AmllTtmlParser.parseTimeMs(raw) == nil, "非法时间 \(raw) — 返回 nil 而非溢出或伪造时间")
    let xml = """
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://itunes.apple.com/lyric-sync">
      <body dur="\(raw)"><div>
        <p itunes:key="bad-begin" begin="\(raw)" end="1s">Invalid start</p>
        <p itunes:key="bad-end" begin="0s" end="\(raw)">Invalid end</p>
        <p itunes:key="bad-span-begin" begin="0s" end="1s"><span begin="\(raw)" end="1s">Invalid span start</span></p>
        <p itunes:key="bad-span-end" begin="0s" end="1s"><span begin="0s" end="\(raw)">Invalid span end</span></p>
        <p itunes:key="valid" begin="0s" end="1s">Valid line</p>
      </div></body>
    </tt>
    """
    do {
        let parsed = try AmllTtmlParser.parse(xml)
        requireEqual(parsed.lines.count, 3, "非法时间 \(raw) — 显式非法 p 时间的行被丢弃")
        require(parsed.declaredDurationMs == nil, "非法时间 \(raw) — body dur 不伪造时间")
        requireEqual(parsed.lastLineEndMs ?? -1, 1_000, "非法时间 \(raw) — 文档末行时间不受污染")
        require(!parsed.lines.contains { $0.key == "bad-begin" }, "非法时间 \(raw) — p begin 无效时丢弃")
        require(!parsed.lines.contains { $0.key == "bad-end" }, "非法时间 \(raw) — 显式非法 p end 不能当成缺失时间")
        require(parsed.lines.contains { $0.key == "valid" && $0.primaryText == "Valid line" }, "非法时间 \(raw) — 合法行不受影响")
        for test in [("bad-span-begin", "Invalid span start"), ("bad-span-end", "Invalid span end")] {
            require(parsed.lines.contains { $0.key == test.0 }, "非法时间 \(raw) — \(test.0) 保留行")
            guard let line = parsed.lines.first(where: { $0.key == test.0 }) else { continue }
            requireEqual(line.primaryText, test.1, "非法时间 \(raw) — \(test.0) 主词完整")
            requireEqual(line.plainText, test.1, "非法时间 \(raw) — \(test.0) plainText 完整")
            requireEqual(line.offsetMs, 0, "非法时间 \(raw) — \(test.0) 使用 p begin")
            requireEqual(line.endMs ?? -1, 1_000, "非法时间 \(raw) — \(test.0) 使用 p end")
            require(line.syllables.isEmpty, "非法时间 \(raw) — \(test.0) 退回行级而非保留非法音节")
        }
    } catch {
        failures += 1
        print("  FAIL 非法时间 \(raw) — XML 解析抛错 \(error)")
    }
}

if failures == 0 {
    print("AmllTtmlApple: all assertions passed")
} else {
    print("AmllTtmlApple: \(failures) failure(s)")
    exit(1)
}
