import Foundation

/// SpicyLyrics 音节（`Syllable`）数据的拼接规则。
///
/// 单独一个文件，是为了**能被 CI 直接测**（`Tests/SpicyLyricsJsonMapping`）：
/// 规则住在 `SpicyLyricsRepository` 里的话，那边带 Orion/UIKit 依赖，进不了 CI。
///
/// ## ★ `IsPartOfWord` 是**前瞻**的（本仓库曾把方向搞反）
///
/// 它标在**前一个**音节上，含义是「**下一个**音节接着同一个词、中间不加空格」。
/// 也就是说：判断第 i 个音节前面要不要空格，看的是**第 i-1 个**音节的
/// `IsPartOfWord`，而不是它自己的。
///
/// 2026-10-13 从官方 v1 API 取回的真实数据（`apple_music` / `spicy_lyrics` 两个源都一样）：
/// ```
/// [("long", false), ("e", true),   ("nough", false)]                 → "long enough"
/// [("how", false),  ("I'm", false), ("feel", true), ("in'", false)]  → "how I'm feelin'"
/// [("Ooh-", true),  ("ooh,", false)]                                 → "Ooh-ooh,"
/// [("We're", false), ("no", false), ("strangers", false)]            → "We're no strangers"
/// ```
/// 按「看它自己那一位」的读法（本仓库 2026-10-13 之前的实现）会拼出
/// `"longe nough"` / `"I'mfeel in'"` / `"Ooh- ooh,"` —— 实测 7 首曲目、423 条有音节的
/// 歌词行里，**153 行**（36%）与官方规则不一致。同一个坑上游也踩过并修好了
/// （`KaraokeLyricsDto.plainText` 的注释写着 "since the flag is forward-looking"）。
enum SpicySyllableText {

    /// 整行文本 —— Spotify 那一行显示的就是它。
    static func joined(_ syllables: [SLObjPackValue]) -> String {
        var text = ""
        var previousIsPartOfWord = false
        for syllable in syllables {
            guard let piece = syllable["Text"]?.stringValue else { continue }
            if !text.isEmpty && !previousIsPartOfWord {
                text += " "
            }
            text += piece
            previousIsPartOfWord = syllable["IsPartOfWord"]?.boolValue ?? false
        }
        return text
    }

    /// 逐词（逐字高亮）那一份：每个**非空白**音节一个词；空白音节（`" "` / `"　"`）
    /// 不参与高亮，但仍要参与前瞻状态的推进。
    ///
    /// ⚠️ 词与词之间的空格前缀**必须**用与 `joined` 同一套判据，否则逐字高亮的位置
    /// 会跟整行文本对不上（一个字错位，整行高亮就跟着错）。
    static func words(_ syllables: [SLObjPackValue]) -> [LyricsWordDto] {
        var words: [LyricsWordDto] = []
        var previousIsPartOfWord = false
        for syllable in syllables {
            guard let piece = syllable["Text"]?.stringValue else { continue }
            let isBlank = piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !isBlank {
                let start = syllable["StartTime"]?.doubleValue.map { Int($0 * 1000) }
                let end = syllable["EndTime"]?.doubleValue.map { Int($0 * 1000) }
                let needsSpace = !words.isEmpty && !previousIsPartOfWord
                words.append(
                    LyricsWordDto(
                        text: needsSpace ? " " + piece : piece,
                        startMs: start ?? 0,
                        endMs: end
                    )
                )
            }
            previousIsPartOfWord = syllable["IsPartOfWord"]?.boolValue ?? false
        }
        return words
    }
}
