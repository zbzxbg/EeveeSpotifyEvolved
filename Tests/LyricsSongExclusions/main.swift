import Foundation

// MARK: - 按歌排除源（`LyricsSongSourceExclusions`）
//
// 跑法（CI 里就是这条，见 `.github/workflows/tests.yml`）：
//   swiftc Sources/EeveeSpotify/Lyrics/Models/Settings/LyricsSource.swift \
//          Sources/EeveeSpotify/Lyrics/Models/Settings/LyricsSourceOrder.swift \
//          Sources/EeveeSpotify/Lyrics/Models/Settings/LyricsSongSourceExclusions.swift \
//          Sources/EeveeSpotify/Shared/Models/Extensions/Locale+Extension.swift \
//          Tests/LyricsSongExclusions/main.swift -o lyrics-song-exclusions-tests
//
// 钉住四件事：
//   ① 解码要自愈：未知键 / 重复项 / 不能作为排除项的源（`imported`、自动优选那类）一律丢掉，
//      空列表整条不存 —— 脏数据不该让某首歌变成"整首取不到词"；
//   ② 编码是往返的（写进去的再读回来一模一样）；
//   ③ 过滤只摘掉被排除的源，链的**相对顺序**不变；
//   ④ 全被排除时**忽略排除表**（返回原链）—— 让一首歌彻底没词，比用了一个不喜欢的源更糟。

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

func requireEqual(_ actual: [LyricsSource], _ expected: [LyricsSource], _ message: String) {
    if actual == expected {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message) — got \(actual.map(\.offsetStorageKey)), expected \(expected.map(\.offsetStorageKey))")
    }
}

func requireEqual(_ actual: String?, _ expected: String?, _ message: String) {
    if actual == expected {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message) — got \(actual ?? "nil"), expected \(expected ?? "nil")")
    }
}

func requireEqual(
    _ actual: [String: [LyricsSource]],
    _ expected: [String: [LyricsSource]],
    _ message: String
) {
    if actual == expected {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message) — got \(actual), expected \(expected)")
    }
}

// MARK: - ① 解码自愈

let dirtyJSON = """
{
  "trackA": ["qqmusic", "kugou"],
  "trackB": ["nope", "imported", "multiLevel", "spotify"],
  "trackC": [],
  "  ": ["netease"],
  "trackD": ["netease", "netease", "unknownKey"]
}
"""

let decoded = LyricsSongSourceExclusions.decode(dirtyJSON)

requireEqual(decoded.count, 2, "only the two usable tracks survive decoding")
requireEqual(decoded["trackA"] ?? [], [.kugou, .qqMusic], "a normal entry keeps its sources (sorted by storage key)")
require(decoded["trackB"] == nil, "an entry with only unstorable sources is dropped")
require(decoded["trackC"] == nil, "an empty list is dropped")
require(decoded[""] == nil, "a blank track id is dropped")
requireEqual(decoded["trackD"] ?? [], [.netease], "duplicates and unknown keys are dropped")

require(LyricsSongSourceExclusions.decode(nil).isEmpty, "no stored text decodes to an empty map")
require(LyricsSongSourceExclusions.decode("not json").isEmpty, "garbage decodes to an empty map")

// MARK: - ② 编码往返

let roundTrip: [String: [LyricsSource]] = [
    "trackA": [.kugou, .qqMusic],
    "trackD": [.netease],
]
let encoded = LyricsSongSourceExclusions.encode(roundTrip)
require(encoded != nil, "a non-empty map encodes")
requireEqual(LyricsSongSourceExclusions.decode(encoded), roundTrip, "encode → decode round-trips")
require(LyricsSongSourceExclusions.encode([:]) == nil, "an empty map encodes to nil (nothing to store)")

// MARK: - ③ 过滤保持链的顺序

let chain: [LyricsSource] = [.amllTtml, .netease, .qqMusic, .kugou, .genius]

requireEqual(
    LyricsSongSourceExclusions.resolve(chain: chain, excluding: []),
    chain,
    "an empty exclusion set leaves the chain untouched"
)
requireEqual(
    LyricsSongSourceExclusions.resolve(chain: chain, excluding: [.qqMusic, .genius]),
    [.amllTtml, .netease, .kugou],
    "excluded sources are removed and the relative order is kept"
)

// MARK: - ④ 全被排除时忽略整份排除表

requireEqual(
    LyricsSongSourceExclusions.resolve(chain: chain, excluding: Set(chain)),
    chain,
    "excluding every source falls back to the untouched chain"
)
requireEqual(
    LyricsSongSourceExclusions.resolve(chain: [] , excluding: [.netease]),
    [],
    "an empty chain stays empty"
)

// MARK: - 短 id（设置页"未知歌曲"那一行用）

requireEqual(
    LyricsSongSourceExclusions.shortened("4uLU6hMCjMI75M1A2tKUQC"),
    "4uLU…KUQC",
    "a long id is shortened for display"
)
requireEqual(
    LyricsSongSourceExclusions.shortened("short"),
    "short",
    "a short id is left alone"
)
requireEqual(
    LyricsSongSourceExclusions.shortened("  padded  "),
    "padded",
    "the id is trimmed before display"
)

if failures == 0 {
    print("LyricsSongExclusions: all assertions passed")
} else {
    print("LyricsSongExclusions: \(failures) failure(s)")
    exit(1)
}
