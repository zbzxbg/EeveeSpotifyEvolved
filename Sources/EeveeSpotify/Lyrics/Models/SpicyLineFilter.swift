import Foundation

/// SpicyLyrics 的**行级筛选**：哪些行是「间奏行」，不该当成歌词正文留下来。
///
/// ## 为什么要有它用户报的现场）
///
/// 「呼吸灯的下一行有可能是 ♪，而不是下一行歌词」—— 苹果那份 TTML 在间奏结束处常常留一个
/// **空的人声条目**（`Type: Vocal`，`Syllables` 全空、或者 `Text: ""`）。我们以前把空文本
/// 交给 `lyricsNoteIfEmpty` 换成 `♪` 留在行里，于是渲染层看到的是：
///
/// ```
/// …上一句  →  （三个呼吸点）  →  ♪  →  下一句
/// ```
///
/// 呼吸点之后先冒出一个小音符，下一句被挤到再下一行 —— 的就是"间奏/空行"。
///
/// 处置与网易云 / Musixmatch 同一条纪律把原本有的间奏全部删掉）：
/// **整行丢弃**，间奏交给 `LyricInterludeTimeline` 从相邻行的时间间隙去推 —— 空行在渲染层
/// 里照样占一行高度，看着就是"漏了一句词"。
///
/// ## 为什么单独一个文件
///
/// `SpicyLyricsRepository` 带 Orion / UIKit 依赖，进不了 CI；而这条判据错了只表现为
/// "真机上多一行 ♪ / 少一句词"，肉眼很难归因。抽成 Foundation-only 的纯函数之后，
/// `Tests/SpicyLyricsJsonMapping` 能直接钉住它（与 `SpicySyllableText` 同一个理由）。
enum SpicyLineFilter {

    /// 整行只有音乐符号时算间奏行。符号集与
    /// `MusixmatchLyricsRepository.isMxmInterludeRow` 保持一致。
    private static let musicSymbols = "♪♫♬♩♭♯"

    /// 这一行是不是**间奏行**：空白（含纯空格、纯换行），或整行只有 ♪ ♫ ♬ ♩ ♭ ♯
    /// **以及夹在符号之间的空白**（`" ♪ ♪ "` 这种）。
    ///
    /// ⚠️ 只要行里还有**一个**非空白、非符号字符就**不算**间奏 —— `♪ la la` 这种带正文的行必须留着
    /// （真有歌用音符开头）；反过来 `[间奏]` 这种方括号标注不归这里管，那是
    /// `LyricsMarkerFilter` 的活。
    static func isInterludeRow(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return trimmed.allSatisfy { $0.isWhitespace || musicSymbols.contains($0) }
    }
}
