import Foundation

// MARK: - TTML 的歌手声明与对唱分边（`ttm:agent`）
//
// 跑法（CI 里就是这条，见 `.github/workflows/tests.yml`）：
//   swiftc Sources/EeveeSpotify/Lyrics/Models/Amll/AmllTtmlDocument.swift \
//          Sources/EeveeSpotify/Lyrics/Models/Amll/AmllTtmlParser.swift \
//          Sources/EeveeSpotify/Lyrics/Models/LyricsError.swift \
//          Sources/EeveeSpotify/Lyrics/Models/LyricsWordDto.swift \
//          Sources/EeveeSpotify/Lyrics/Models/LyricsBackgroundVocalDto.swift \
//          Sources/EeveeSpotify/Lyrics/Models/LyricsMatch.swift \
//          Sources/EeveeSpotify/Lyrics/Repositories/LyricsMarkers.swift \
//          Tests/LyricsDuet/main.swift -o lyrics-duet-tests
//
// 这一层钉住的是**数据**，不是渲染：
//   ① 行上的 `ttm:agent` 只是引用，名字与"个人 / 合唱"在 `<ttm:agent>` 声明表里 ——
//      只读行属性的话拿到的是 `v1` / `v2` 这种 id，渲染层就没法知道"换人了"；
//   ② 分边规则：**恰好两位个人歌手、且没有合唱 agent** 时，第二位才是"另一边"；
//      三位以上或带合唱 agent 一律不分边（三个人把后两位都推右边只会让每行乱跳）。
//
// 渲染侧的判据（`alignment == .flipped` + 设置开关）在 `AppleMusicLyricsPage`，
// 需要 SwiftUI，进不了这条链；这里只管"数据给对了没有"。

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

// MARK: - ① 两位个人歌手 → 第二位分到另一边

let duetTtml = """
<?xml version="1.0" encoding="UTF-8"?>
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xml:lang="en">
  <head>
    <metadata>
      <ttm:agent xml:id="v1" type="person">
        <ttm:name type="full">Alice</ttm:name>
      </ttm:agent>
      <ttm:agent xml:id="v2" type="person">
        <ttm:name type="full">Bob</ttm:name>
      </ttm:agent>
    </metadata>
  </head>
  <body dur="00:00:12.000">
    <div>
      <p begin="00:00:01.000" end="00:00:03.500" ttm:agent="v1">She opens the song</p>
      <p begin="00:00:04.000" end="00:00:06.500" ttm:agent="v2">He answers from the other side</p>
      <p begin="00:00:07.000" end="00:00:09.500" ttm:agent="v1">She closes the verse</p>
    </div>
  </body>
</tt>
"""

do {
    let parsed = try AmllTtmlParser.parse(duetTtml)

    requireEqual(parsed.agents.count, 2, "two agents are declared")
    requireEqual(parsed.agents["v1"]?.displayName ?? "", "Alice", "first agent keeps its declared name")
    requireEqual(parsed.agents["v2"]?.displayName ?? "", "Bob", "second agent keeps its declared name")
    require(parsed.agents["v1"]?.isGroup == false, "a person agent is not a group")
    require(parsed.agents["v1"]?.isFlipped == false, "first voice stays on the leading side")
    require(parsed.agents["v2"]?.isFlipped == true, "second voice moves to the other side")

    requireEqual(parsed.lines.count, 3, "three lyric lines are parsed")
    requireEqual(
        parsed.lines.map { $0.agent ?? "" }.joined(separator: ","),
        "v1,v2,v1",
        "each line keeps the agent id it was tagged with"
    )
    requireEqual(
        parsed.lines.first?.primaryText ?? "",
        "She opens the song",
        "line text is not disturbed by the agent attribute"
    )
} catch {
    failures += 1
    print("  FAIL duet TTML parsing threw \(error)")
}

// MARK: - ② 同一份文件里还有合唱 agent → 谁都不分边

let duetWithChorusTtml = """
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xml:lang="en">
  <head>
    <metadata>
      <ttm:agent xml:id="v1" type="person"><ttm:name type="full">Alice</ttm:name></ttm:agent>
      <ttm:agent xml:id="v2" type="person"><ttm:name type="full">Bob</ttm:name></ttm:agent>
      <ttm:agent xml:id="g1" type="group"><ttm:name type="full">Both of them</ttm:name></ttm:agent>
    </metadata>
  </head>
  <body>
    <div>
      <p begin="00:00:01.000" end="00:00:03.000" ttm:agent="v1">She sings</p>
      <p begin="00:00:03.500" end="00:00:05.500" ttm:agent="v2">He sings</p>
      <p begin="00:00:06.000" end="00:00:08.000" ttm:agent="g1">They sing together</p>
    </div>
  </body>
</tt>
"""

do {
    let parsed = try AmllTtmlParser.parse(duetWithChorusTtml)
    requireEqual(parsed.agents.count, 3, "person + person + group are all listed")
    require(parsed.agents["g1"]?.isGroup == true, "the group agent is marked as a group")
    require(
        parsed.agents.values.allSatisfy { !$0.isFlipped },
        "a chorus in the file disables the two-sided layout for the whole song"
    )
} catch {
    failures += 1
    print("  FAIL duet-with-chorus TTML parsing threw \(error)")
}

// MARK: - ③ 三位个人歌手 → 不分边

let trioTtml = """
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xml:lang="en">
  <head>
    <metadata>
      <ttm:agent xml:id="v1" type="person"><ttm:name type="full">A</ttm:name></ttm:agent>
      <ttm:agent xml:id="v2" type="person"><ttm:name type="full">B</ttm:name></ttm:agent>
      <ttm:agent xml:id="v3" type="person"><ttm:name type="full">C</ttm:name></ttm:agent>
    </metadata>
  </head>
  <body>
    <div>
      <p begin="00:00:01.000" end="00:00:03.000" ttm:agent="v1">One</p>
      <p begin="00:00:03.500" end="00:00:05.500" ttm:agent="v2">Two</p>
      <p begin="00:00:06.000" end="00:00:08.000" ttm:agent="v3">Three</p>
    </div>
  </body>
</tt>
"""

do {
    let parsed = try AmllTtmlParser.parse(trioTtml)
    requireEqual(parsed.agents.count, 3, "three persons are declared")
    require(
        parsed.agents.values.allSatisfy { !$0.isFlipped },
        "three or more voices never use the two-sided layout"
    )
} catch {
    failures += 1
    print("  FAIL trio TTML parsing threw \(error)")
}

// MARK: - ④ 没有声明表（行上只有 id）→ 不崩、也不假装分边

let undeclaredTtml = """
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xml:lang="en">
  <body>
    <div>
      <p begin="00:00:01.000" end="00:00:03.000" ttm:agent="v1">First line</p>
      <p begin="00:00:03.500" end="00:00:05.000" ttm:agent="v2">Second line</p>
    </div>
  </body>
</tt>
"""

do {
    let parsed = try AmllTtmlParser.parse(undeclaredTtml)
    requireEqual(parsed.agents.count, 0, "no declaration means an empty agent table")
    requireEqual(parsed.lines.count, 2, "the lines are still parsed")
    requireEqual(
        parsed.lines.map { $0.agent ?? "" }.joined(separator: ","),
        "v1,v2",
        "unknown agent ids are kept on the line but resolve to nothing"
    )
    require(parsed.lines.allSatisfy { parsed.agents[$0.agent ?? ""] == nil }, "no line resolves to an agent")
} catch {
    failures += 1
    print("  FAIL undeclared-agent TTML parsing threw \(error)")
}

// MARK: - ⑤ 没有 agent 的普通文件不受影响

let plainTtml = """
<tt xmlns="http://www.w3.org/ns/ttml" xml:lang="en">
  <body>
    <div>
      <p begin="00:00:01.000" end="00:00:03.000">Just a line</p>
    </div>
  </body>
</tt>
"""

do {
    let parsed = try AmllTtmlParser.parse(plainTtml)
    requireEqual(parsed.agents.count, 0, "a file without agents has no agent table")
    requireEqual(parsed.lines.count, 1, "a file without agents still parses")
    require(parsed.lines[0].agent == nil, "lines without ttm:agent carry no agent id")
} catch {
    failures += 1
    print("  FAIL plain TTML parsing threw \(error)")
}

// MARK: - ⑥ 行 DTO 的形状：歌手挂在行上，空白行判据不受影响

var duetLine = LyricsLineDto(content: "He answers", offsetMs: 4000)
duetLine.agent = LyricsAgentDto(
    identifier: "v2",
    displayName: "Bob",
    isGroup: false,
    isFlipped: true
)

requireEqual(duetLine.agent?.identifier ?? "", "v2", "the line keeps its singer id")
require(duetLine.agent?.isFlipped == true, "the flip flag survives the DTO")
require(!duetLine.isBlankForDisplay, "a line with text is not blank because of its singer")
require(
    LyricsLineDto(content: "  ").agent == nil,
    "lines from sources without singers carry no agent"
)

if failures == 0 {
    print("LyricsDuet: all assertions passed")
} else {
    print("LyricsDuet: \(failures) failure(s)")
    exit(1)
}
