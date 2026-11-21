import Foundation

/// 一行逐字要放的那几帧：时间点 + 亮到第几个字符。
///
/// 锁屏那一块画面是系统画的，App 只能交出"一段本地视频"，所以逐字**不是**逐帧重绘，
/// 而是**一次性编进这段短片**：每个词开始的那一刻一帧，之前唱完的词是亮白、没唱到的压暗。
/// 这样片段仍是"一行一段"，只是从单帧变成多帧（见 `LyricClipRenderer.writeFrames`）。
struct LockScreenKaraokeFrame: Equatable {
    /// 相对**这一行开始**的毫秒数（第一帧恒为 0）。
    let offsetMs: Int
    /// 这一帧亮到第几个字符（按 `String` 的 Character 计，渲染时再换成 UTF-16 长度）。
    let revealedCharacters: Int
}

enum LockScreenKaraoke {

    /// 一帧一个词，再多的歌也用不上；超过就退回单帧（整行点亮）。
    static let maximumFrames = 64
    /// 只有一个词谈不上逐字。
    static let minimumWords = 2

    /// 词级时间轴 → 帧表。返回 nil = 这一行不做逐字（调用方退回单帧）。
    ///
    /// 判据只有一条：**词拼起来必须正好等于这一行要画出来的字**。
    /// 差一个空格都不行 —— 帧里存的是"亮到第几个字符"，文本对不上就会亮错位置；
    /// 而各源的 `content` 与 `words` 之间本来就有空格/括号的细微差别。
    static func frames(words: [LyricsWordDto], lineText: String) -> [LockScreenKaraokeFrame]? {
        guard words.count >= minimumWords, words.count <= maximumFrames else { return nil }
        let line = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        guard words.map(\.text).joined() == line else { return nil }

        let base = words[0].startMs
        var frames: [LockScreenKaraokeFrame] = []
        frames.reserveCapacity(words.count)
        var revealed = 0

        for word in words {
            let offset = max(0, word.startMs - base)
            revealed += word.text.count
            let frame = LockScreenKaraokeFrame(offsetMs: offset, revealedCharacters: revealed)
            if let last = frames.last, last.offsetMs == frame.offsetMs {
                // 同一时刻开始的两个词（或时间倒退被夹平）：合成一帧，留**后来**那个字符数。
                // 两帧同一时间戳会被 AVAssetWriter 拒掉，而且看起来也只会亮前一帧。
                frames[frames.count - 1] = frame
                continue
            }
            if let last = frames.last, offset < last.offsetMs { continue }
            frames.append(frame)
        }

        // 第一帧要落在 0：调度器在换行那一刻换片段，动画就从 0 开始放。
        guard frames.count >= 2 else { return nil }
        if frames[0].offsetMs != 0 {
            frames.insert(
                LockScreenKaraokeFrame(offsetMs: 0, revealedCharacters: 0),
                at: 0
            )
        }
        return frames
    }
}
