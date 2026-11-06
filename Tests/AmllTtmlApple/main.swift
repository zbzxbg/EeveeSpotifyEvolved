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

if failures == 0 {
    print("AmllTtmlApple: all assertions passed")
} else {
    print("AmllTtmlApple: \(failures) failure(s)")
    exit(1)
}
