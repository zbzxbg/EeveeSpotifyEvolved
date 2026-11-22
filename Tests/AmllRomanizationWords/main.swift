import Foundation

// MARK: - AMLL 整行罗马字 → 逐词组（`AmllRomanizationWords`）
//
// 跑法（CI 里就是这条）：
//   swiftc Sources/EeveeSpotify/Lyrics/Models/LyricsWordDto.swift \
//          Sources/EeveeSpotify/Lyrics/Models/Amll/AmllRomanizationWords.swift \
//          Tests/AmllRomanizationWords/main.swift -o amll-romanization-words-tests
//
// 钉住的是：
//   ① 分词与官方整行字母一致时，按分词切回逐词组，文本仍用官方那份（空格/大小写不丢）；
//   ② 一个分词覆盖多个音节时，文本挂到第一个音节，其余组留空，但拼起来仍等于官方整行；
//   ③ 没有分词时退化成"按空格切词、词数相等才用"；对不上就返回 nil（保持静态）。

var failures = 0

func require(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)")
    }
}

func requireEqual(_ actual: [String]?, _ expected: [String], _ message: String) {
    guard let actual else {
        failures += 1
        print("  FAIL \(message) — got nil")
        return
    }
    if actual == expected {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message) — got \(actual), expected \(expected)")
    }
}

// MARK: - ① 日文分词：官方整行 → 逐词组

let japaneseWords = [
    LyricsWordDto(text: "今", startMs: 0, endMs: 500),
    LyricsWordDto(text: "も", startMs: 500, endMs: 800),
    LyricsWordDto(text: "思", startMs: 800, endMs: 1_300),
    LyricsWordDto(text: "い", startMs: 1_300, endMs: 1_500),
    LyricsWordDto(text: "出", startMs: 1_500, endMs: 1_900),
    LyricsWordDto(text: "す", startMs: 1_900, endMs: 2_200),
    LyricsWordDto(text: "ん", startMs: 2_200, endMs: 2_400),
    LyricsWordDto(text: "だ", startMs: 2_400, endMs: 2_800),
]
let japaneseChunks: [AmllRomanizationWords.Chunk] = [
    .init(range: NSRange(location: 0, length: 1), romaji: "ima"),
    .init(range: NSRange(location: 1, length: 1), romaji: "mo"),
    .init(range: NSRange(location: 2, length: 2), romaji: "omoi"),
    .init(range: NSRange(location: 4, length: 2), romaji: "dasu"),
    .init(range: NSRange(location: 6, length: 1), romaji: "n"),
    .init(range: NSRange(location: 7, length: 1), romaji: "da"),
]
let japaneseGroups = AmllRomanizationWords.groups(
    officialLine: "i ma mo o mo i da su n da",
    words: japaneseWords,
    chunks: japaneseChunks
)
requireEqual(
    japaneseGroups,
    ["i ma ", "mo ", "o mo i ", "", "da su ", "", "n ", "da"],
    "a Japanese chunk covering several syllables puts its text on the first one"
)
require(
    japaneseGroups?.joined() == "i ma mo o mo i da su n da",
    "the groups concatenate back to the official line"
)

// 分词字母与官方对不上：退回按空格切词；词数对不上就 nil。
requireEqual(
    AmllRomanizationWords.groups(
        officialLine: "ho",
        words: [LyricsWordDto(text: "ほ", startMs: 0, endMs: 100)],
        chunks: [.init(range: NSRange(location: 0, length: 1), romaji: "hi")]
    ),
    ["ho"],
    "a chunk mismatch falls back to one token per word when the counts line up"
)
require(
    AmllRomanizationWords.groups(
        officialLine: "ho ho ho",
        words: [LyricsWordDto(text: "ほ", startMs: 0, endMs: 100)],
        chunks: [.init(range: NSRange(location: 0, length: 1), romaji: "hi")]
    ) == nil,
    "a token count that does not match the word count returns nil"
)

// MARK: - ② 拼写对不上时按音拍数切

require(AmllRomanizationWords.moraCount("ima") == 2, "ima has two mora")
require(AmllRomanizationWords.moraCount("mo") == 1, "mo has one mora")
require(AmllRomanizationWords.moraCount("omoi") == 3, "omoi has three mora")
require(AmllRomanizationWords.moraCount("dasu") == 2, "dasu has two mora")
require(AmllRomanizationWords.moraCount("n") == 1, "a standalone n is one mora")
require(AmllRomanizationWords.moraCount("kitte") == 3, "a geminate consonant adds one mora")
require(AmllRomanizationWords.moraCount("onna") == 3, "the first n of nn is a mora")
require(AmllRomanizationWords.moraCount("gakkou") == 4, "gakkou keeps its long vowel as a mora")

let moraWords = [
    LyricsWordDto(text: "あ", startMs: 0, endMs: 200),
    LyricsWordDto(text: "の", startMs: 200, endMs: 400),
    LyricsWordDto(text: "日", startMs: 400, endMs: 600),
    LyricsWordDto(text: "見", startMs: 600, endMs: 1_000),
]
// 本地读音拼写故意与官方不同（aho / miwata），但音拍数仍然对得上。
let moraChunks: [AmllRomanizationWords.Chunk] = [
    .init(range: NSRange(location: 0, length: 1), romaji: "aho"),
    .init(range: NSRange(location: 1, length: 1), romaji: "hi"),
    .init(range: NSRange(location: 2, length: 1), romaji: "miwata"),
    .init(range: NSRange(location: 3, length: 1), romaji: "shi"),
]
requireEqual(
    AmllRomanizationWords.groups(
        officialLine: "a no hi mi wa ta shi",
        words: moraWords,
        chunks: moraChunks
    ),
    ["a no ", "hi ", "mi wa ta ", "shi"],
    "when spellings differ, the official tokens are split by mora counts"
)

// MARK: - ③ 没有日文分词：按空格切词

let englishWords = [
    LyricsWordDto(text: "Hello", startMs: 0, endMs: 500),
    LyricsWordDto(text: " world", startMs: 500, endMs: 900),
]
requireEqual(
    AmllRomanizationWords.groups(
        officialLine: "Hello world",
        words: englishWords,
        chunks: []
    ),
    ["Hello ", "world"],
    "without chunks, one whitespace token per word is used"
)

// MARK: - ③ 边界

require(
    AmllRomanizationWords.groups(officialLine: "", words: englishWords, chunks: []) == nil,
    "an empty official line produces no groups"
)
require(
    AmllRomanizationWords.groups(
        officialLine: "Hello world",
        words: [LyricsWordDto(text: "Hello", startMs: 0, endMs: 500)],
        chunks: []
    ) == nil,
    "a token count larger than the word count returns nil"
)

if failures == 0 {
    print("AmllRomanizationWords: all assertions passed")
} else {
    print("AmllRomanizationWords: \(failures) failure(s)")
    exit(1)
}
