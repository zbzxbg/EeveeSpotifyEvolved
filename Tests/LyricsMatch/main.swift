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

// MARK: - 结果

if failures == 0 {
    print("LyricsMatch: all assertions passed")
} else {
    print("LyricsMatch: \(failures) assertion(s) FAILED")
    exit(1)
}
