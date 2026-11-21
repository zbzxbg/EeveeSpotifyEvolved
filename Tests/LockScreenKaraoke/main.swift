import Foundation

// MARK: - 锁屏逐字的帧表（`LockScreenKaraoke`）
//
// 跑法（CI 里就是这条，见 `.github/workflows/tests.yml`）：
//   swiftc Sources/EeveeSpotify/Lyrics/Models/LyricsWordDto.swift \
//          Sources/EeveeSpotify/LockScreen/LockScreenKaraoke.swift \
//          Tests/LockScreenKaraoke/main.swift -o lockscreen-karaoke-tests
//
// 钉住的是"哪一刻亮到第几个字符"这张表 —— 锁屏那段短片就是按它编帧的：
//   ① 一个词一帧，时间相对行首，第一帧恒为 0；
//   ② 词拼起来和这一行字**不完全一样**就不做（否则字符数会错位、亮到别的字上）；
//   ③ 少于两个词、多于 64 个词、空行、时间倒退 —— 一律退回单帧。

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

func requireEqual(_ actual: [LockScreenKaraokeFrame], _ expected: [LockScreenKaraokeFrame], _ message: String) {
    if actual == expected {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message) — got \(actual), expected \(expected)")
    }
}

// MARK: - ① 三个词 → 三帧，时间相对行首

let words = [
    LyricsWordDto(text: "夜に", startMs: 10_000, endMs: 10_400),
    LyricsWordDto(text: "駆ける", startMs: 10_400, endMs: 10_900),
    LyricsWordDto(text: "君", startMs: 11_200, endMs: 11_500),
]

let frames = LockScreenKaraoke.frames(words: words, lineText: "夜に駆ける君")
require(frames != nil, "three timed words produce frames")
if let frames {
    requireEqual(frames.count, 3, "one frame per word")
    requireEqual(frames[0].offsetMs, 0, "the first frame sits at the start of the line")
    requireEqual(frames[0].revealedCharacters, 2, "the first word is lit at zero")
    requireEqual(frames[1].offsetMs, 400, "the second frame is offset from the line start")
    requireEqual(frames[1].revealedCharacters, 5, "reveal counts accumulate across words")
    requireEqual(frames[2].offsetMs, 1200, "the third frame keeps the source timing")
    requireEqual(frames[2].revealedCharacters, 6, "the last frame reveals the whole line")
}

// MARK: - ② 词与行文本对不上 → 不做逐字

require(
    LockScreenKaraoke.frames(words: words, lineText: "夜に駆ける") == nil,
    "a line text that does not match the words produces no frames"
)
require(
    LockScreenKaraoke.frames(
        words: [
            LyricsWordDto(text: "夜に", startMs: 0),
            LyricsWordDto(text: " 駆ける", startMs: 100),
        ],
        lineText: "夜に駆ける"
    ) == nil,
    "a leading space inside the words is a mismatch, not something to guess around"
)

// MARK: - ③ 边界：词数、空行、时间倒退

require(
    LockScreenKaraoke.frames(
        words: [LyricsWordDto(text: "夜に", startMs: 0)],
        lineText: "夜に"
    ) == nil,
    "a single word is not word-by-word"
)
require(
    LockScreenKaraoke.frames(words: words, lineText: "   ") == nil,
    "a blank line produces no frames"
)

let reversed = [
    LyricsWordDto(text: "a", startMs: 500),
    LyricsWordDto(text: "b", startMs: 100),
    LyricsWordDto(text: "c", startMs: 900),
]
if let reversedFrames = LockScreenKaraoke.frames(words: reversed, lineText: "abc") {
    var monotonic = true
    for index in 1..<reversedFrames.count where reversedFrames[index].offsetMs < reversedFrames[index - 1].offsetMs {
        monotonic = false
    }
    require(monotonic, "frame times never go backwards")
    requireEqual(
        reversedFrames[reversedFrames.count - 1].revealedCharacters,
        3,
        "the last frame still reveals the last character"
    )
} else {
    failures += 1
    print("  FAIL reversed word timings should still yield frames, or nil — never a crash")
}

let manyWords = (0..<80).map { LyricsWordDto(text: "字", startMs: $0 * 100) }
require(
    LockScreenKaraoke.frames(words: manyWords, lineText: String(repeating: "字", count: 80)) == nil,
    "more than 64 words falls back to a single frame"
)

// MARK: - ④ 重复时间点的词合并成一帧

let repeated = [
    LyricsWordDto(text: "a", startMs: 0),
    LyricsWordDto(text: "b", startMs: 0),
    LyricsWordDto(text: "c", startMs: 300),
]
if let repeatedFrames = LockScreenKaraoke.frames(words: repeated, lineText: "abc") {
    requireEqual(repeatedFrames.count, 2, "words that start together share one frame")
    requireEqual(repeatedFrames[0].revealedCharacters, 2, "the shared frame lights both words")
} else {
    failures += 1
    print("  FAIL repeated start times should still produce frames")
}

if failures == 0 {
    print("LockScreenKaraoke: all assertions passed")
} else {
    print("LockScreenKaraoke: \(failures) failure(s)")
    exit(1)
}
