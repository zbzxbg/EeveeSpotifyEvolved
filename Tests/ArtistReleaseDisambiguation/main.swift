import Foundation

// 「最新发布」在多位同名艺人之间用页面歌名投票的回归测试（纯 Foundation）。
//
// 跑法（需要 Swift 工具链；本仓库本机没有，所以由 CI 跑）：
//   swiftc Sources/EeveeSpotify/Appearance/ArtistReleaseDisambiguation.swift \
//          Tests/ArtistReleaseDisambiguation/main.swift \
//          -o /tmp/artist-release-disambiguation-tests && /tmp/artist-release-disambiguation-tests

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

// MARK: - 归一化

require(
    ArtistReleaseDisambiguation.normalized("LUZ ROJA - Slowed") == "luzrojaslowed",
    "spaces and punctuation must drop out"
)
require(
    ArtistReleaseDisambiguation.normalized("八千七百八十万 次播放") == "八千七百八十万次播放",
    "CJK stays, the separator drops"
)
require(
    ArtistReleaseDisambiguation.normalized("Mimì") != ArtistReleaseDisambiguation.normalized("MIMI"),
    "diacritics must keep two artists apart"
)

// MARK: - 投票

let pageText = """
热门
1. LUZ ROJA - Slowed 八千七百八十万 次播放
2. TE CONOCÍ - Super Slowed 四千〇四十万 次播放
3. アンコールダンス (feat. 重音テト) 五百二十五万 次播放
"""

require(
    ArtistReleaseDisambiguation.score(
        titles: ["LUZ ROJA - Slowed", "TE CONOCÍ - Super Slowed", "别的歌"],
        pageText: pageText
    ) == 2,
    "two of the three titles are on the page"
)
require(
    ArtistReleaseDisambiguation.score(
        titles: ["Casa Mia", "Mai più", "Kyv"],
        pageText: pageText
    ) == 0,
    "a different artist's tracks do not match"
)
require(
    ArtistReleaseDisambiguation.score(titles: ["ab", "cd"], pageText: "ab cd") == 0,
    "titles shorter than three characters are skipped"
)
require(
    ArtistReleaseDisambiguation.score(titles: ["LUZ ROJA - Slowed"], pageText: "") == 0,
    "an empty page cannot vote"
)
require(
    ArtistReleaseDisambiguation.score(titles: ["LUZ ROJA - Slowed"], pageText: pageText, limit: 0) == 0,
    "limit 0 looks at nothing"
)

// MARK: - 选谁

require(
    ArtistReleaseDisambiguation.bestIndex(scores: [3, 0]) == 0,
    "the only candidate above the minimum wins"
)
require(
    ArtistReleaseDisambiguation.bestIndex(scores: [0, 3, 1]) == 1,
    "the highest score wins wherever it sits"
)
require(
    ArtistReleaseDisambiguation.bestIndex(scores: [1, 1]) == nil,
    "everyone below the minimum is no answer"
)
require(
    ArtistReleaseDisambiguation.bestIndex(scores: [2, 2]) == nil,
    "a tie is not an answer (never guess)"
)
require(
    ArtistReleaseDisambiguation.bestIndex(scores: []) == nil,
    "no candidates is no answer"
)
require(
    ArtistReleaseDisambiguation.bestIndex(scores: [4], minimum: 5) == nil,
    "the minimum is configurable"
)

// MARK: - 一个完整的同名场景

// 页面上是日文歌 ⇒ 只该选中那位日文候选，意大利语候选一张都对不上。
let japanesePage = """
热门
1. アンコールダンス (feat. 重音テト) 五百二十五万 次播放
2. マジック・メイド (feat. 重音テト) 三百〇二万 次播放
3. ヒトリボッチ 一百九十八万 次播放
"""
let candidates: [[String]] = [
    ["Casa Mia", "Mai più", "Dove sei"],
    ["アンコールダンス (feat. 重音テト)", "マジック・メイド (feat. 重音テト)", "ヒトリボッチ"],
]
let scores = candidates.map {
    ArtistReleaseDisambiguation.score(titles: $0, pageText: japanesePage)
}
require(scores == [0, 3], "the Japanese candidate is the only one that matches (got \(scores))")
require(
    ArtistReleaseDisambiguation.bestIndex(scores: scores) == 1,
    "the Japanese candidate must win"
)

// 页面没加载出来 ⇒ 一票没有 ⇒ 不猜。
require(
    ArtistReleaseDisambiguation.bestIndex(
        scores: candidates.map { ArtistReleaseDisambiguation.score(titles: $0, pageText: "") }
    ) == nil,
    "with no page text nobody wins"
)

print("artist release disambiguation: all assertions passed")
