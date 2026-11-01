import Foundation

/// `LyricsMatch` 的断言程序（纯逻辑，CI 跑；见 `.github/workflows/tests.yml`）。
///
/// 为什么要钉这一份：QQ 音乐 / 酷狗 / BiniLyrics / Unison 四个源都是"按名字搜、自己在结果里挑"，
/// 挑错的代价是把**别人的词**配到这首歌上（翻唱、Live 版、同曲异名），用户很难察觉。
/// 这里把四条判据的实际行为固定下来，以后改判据时至少知道自己改了什么。

var failures = 0

func require(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)")
    }
}

// MARK: - key：小写 + 去空白 / 标点 / 符号

require(LyricsMatch.key("Don't Stop Me Now") == LyricsMatch.key("Dont Stop Me Now"),
        "straight quote and no quote normalise to the same key")
require(LyricsMatch.key("Don’t Stop Me Now") == LyricsMatch.key("Dont Stop Me Now"),
        "curly quote normalises like the straight one")
require(LyricsMatch.key("夜に駆ける") == LyricsMatch.key("夜に駆ける"),
        "CJK titles survive normalisation unchanged")
require(LyricsMatch.key("  晴天  ") == LyricsMatch.key("晴天"),
        "surrounding whitespace is dropped")
require(LyricsMatch.key("") == "" && LyricsMatch.key(nil) == "",
        "empty and nil both give an empty key")
// 全角标点也要去掉 —— 曲库里「（Live）」和「(Live)」是同一首歌的两种写法。
require(LyricsMatch.key("晴天（Live）") == LyricsMatch.key("晴天(Live)"),
        "full-width and half-width brackets normalise alike")

// MARK: - leadArtist：合作者不算主艺人

require(LyricsMatch.leadArtist("米津玄師 feat. 菅田将暉") == "米津玄師", "feat. is cut")
require(LyricsMatch.leadArtist("A feat. B") == "A", "short feat. is cut")
require(LyricsMatch.leadArtist("A ft. B") == "A", "ft. is cut")
require(LyricsMatch.leadArtist("A featuring B") == "A", "featuring is cut")
require(LyricsMatch.leadArtist("A & B") == "A", "ampersand collaboration is cut")
require(LyricsMatch.leadArtist("周杰伦") == "周杰伦", "a plain name is untouched")
require(LyricsMatch.leadArtist(nil) == "", "nil gives an empty string")
// ⚠️ 只有 "feat" 在**词首**才算合作标记：`Featherstone` 是一个乐队名，不能被切成 `Featherstone` 之外的东西。
require(LyricsMatch.leadArtist("Featherstone") == "Featherstone", "a name merely starting with Fe is kept")

// MARK: - sameArtist：互相包含

require(LyricsMatch.sameArtist("Jay Chou", "周杰伦") == false,
        "different scripts for the same person do not match — documented limitation")
require(LyricsMatch.sameArtist("Jay Chou (周杰倫)", "周杰倫"), "a fuller credit contains ours")
require(LyricsMatch.sameArtist("周杰倫", "Jay Chou (周杰倫)"), "ours contains the credit")
require(LyricsMatch.sameArtist("米津玄師 feat. 菅田将暉", "米津玄師"), "a collaboration credit matches its lead")
require(LyricsMatch.sameArtist("", "周杰倫") == false, "empty credit never matches")
require(LyricsMatch.sameArtist("周杰倫", "") == false, "empty artist never matches")

// MARK: - lengthMatches：缺数据不否决

require(LyricsMatch.lengthMatches(213_000, 214_000, slackMs: 2_000), "within slack")
require(LyricsMatch.lengthMatches(213_000, 220_000, slackMs: 2_000) == false, "outside slack")
require(LyricsMatch.lengthMatches(nil, 214_000, slackMs: 2_000), "missing candidate length passes")
require(LyricsMatch.lengthMatches(213_000, nil, slackMs: 2_000), "missing track length passes")
require(LyricsMatch.lengthMatches(0, 214_000, slackMs: 2_000), "zero candidate length passes")
require(LyricsMatch.lengthMatches(nil, nil, slackMs: 2_000), "both missing passes")

// MARK: - titlesMatch：曲库的标题后缀（译名 / Explicit / feat.）

require(LyricsMatch.baseTitle("人マニア (人狂热症) (Explicit)") == "人マニア",
        "trailing bracketed suffixes are dropped")
require(LyricsMatch.baseTitle("晴天（Live）") == "晴天", "full-width brackets are dropped too")
require(LyricsMatch.baseTitle("Hello") == "Hello", "a title without brackets is untouched")
require(LyricsMatch.baseTitle("(Intro)") == "", "a title that is only a bracket segment leaves nothing")
require(LyricsMatch.baseTitle(nil) == "", "nil gives an empty base title")
require(LyricsMatch.titlesMatch("人マニア (人狂热症) (Explicit)", "人マニア"),
        "the catalogue's translated/explicit suffix still matches")
require(LyricsMatch.titlesMatch("晴天（Live）", "晴天"), "a bracketed live marker is stripped")
require(LyricsMatch.titlesMatch("ユリイカ", "ユリイカ"), "an exact title matches")
require(LyricsMatch.titlesMatch("人マニア (feat. 重音テト)", "人マニア"),
        "a feat. suffix is a bracket segment")
// ❗不能退化成"包含"：`晴天` 不该命中 `晴天霹雳`，`ユリイカ` 不该命中 `ユリイカ English ver.`。
require(LyricsMatch.titlesMatch("晴天霹雳", "晴天") == false, "prefix-only containment is not a match")
require(LyricsMatch.titlesMatch("ユリイカ English ver.", "ユリイカ") == false,
        "an unbracketed version marker is not a match")
require(LyricsMatch.titlesMatch(nil, "人マニア") == false, "nil candidate never matches")
require(LyricsMatch.titlesMatch("人マニア", "") == false, "empty target never matches")
// 落单的左括号按"吞掉后半段"处理（括号是成对的；这是调用方唯一能拿到的确定性行为）。
require(LyricsMatch.baseTitle("Hello (Live") == "Hello", "an unmatched opening bracket drops the rest")
require(LyricsMatch.titlesMatch("人マニア (人狂热症) (Explicit)", anyOf: ["Yurieka", "人マニア"]),
        "anyOf accepts the localised title")
require(LyricsMatch.titlesMatch("ユリイカ", anyOf: ["Yurieka"]) == false,
        "anyOf does not accept a title that matches none")

// MARK: - lengthGap：只给排序用，不知道就是 nil

require(LyricsMatch.lengthGap(127_000, 127_242) == 242, "the gap is absolute")
require(LyricsMatch.lengthGap(127_242, 127_000) == 242, "argument order does not matter")
require(LyricsMatch.lengthGap(0, 127_000) == nil, "zero candidate length is unknown")
require(LyricsMatch.lengthGap(127_000, nil) == nil, "missing track length is unknown")

// MARK: - 结果

if failures == 0 {
    print("LyricsMatch: all assertions passed")
} else {
    print("LyricsMatch: \(failures) assertion(s) FAILED")
    exit(1)
}
