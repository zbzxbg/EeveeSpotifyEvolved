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

/// 对唱叠句时的一帧：当前句与同一时刻还在唱的另一位歌手那句，各自亮到第几个字符。
///
/// 锁屏一次只画一句会漏掉另一半：两个人同时唱时，后开始的那句一接管，先开始的那句
/// 就从画面上消失。这一份把两张帧表按时间并起来，渲染时两句同时画、各自逐词亮。
struct LockScreenKaraokePairFrame: Equatable {
    let offsetMs: Int
    /// 当前句（`LockScreenLyricsController` 选中的那一句）亮到第几个字符。
    let lineCharacters: Int
    /// 另一位歌手那句亮到第几个字符。
    let companionCharacters: Int
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

    /// 两张帧表并成一张（对唱叠句用）。
    ///
    /// 时间取并集；每一句"亮到第几个字符"取该时刻之前**最近**的那一帧（还没开始就是 0）。
    /// 两张表都必须换算到**同一个起点**之后才传进来：另一个声部往往先开口，它的帧偏移
    /// 会是负数（这一段开始前就唱掉的词），这里会把它们算进 0 那一帧的已亮字符数。
    ///
    /// 任何一边少于两帧（没有真正的逐词数据）就返回 nil，调用方退回只画当前句。
    static func combinedFrames(
        line: [LockScreenKaraokeFrame],
        companion: [LockScreenKaraokeFrame]
    ) -> [LockScreenKaraokePairFrame]? {
        guard line.count >= 2, companion.count >= 2 else { return nil }
        let offsets = Set(
            [0] + (line.map(\.offsetMs) + companion.map(\.offsetMs)).filter { $0 >= 0 }
        ).sorted()
        guard offsets.count >= 2 else { return nil }

        var pair: [LockScreenKaraokePairFrame] = []
        pair.reserveCapacity(offsets.count)
        var lineIndex = 0
        var companionIndex = 0
        var lineRevealed = 0
        var companionRevealed = 0
        for offset in offsets {
            while lineIndex < line.count, line[lineIndex].offsetMs <= offset {
                lineRevealed = line[lineIndex].revealedCharacters
                lineIndex += 1
            }
            while companionIndex < companion.count,
                  companion[companionIndex].offsetMs <= offset {
                companionRevealed = companion[companionIndex].revealedCharacters
                companionIndex += 1
            }
            pair.append(
                LockScreenKaraokePairFrame(
                    offsetMs: offset,
                    lineCharacters: lineRevealed,
                    companionCharacters: companionRevealed
                )
            )
        }
        return pair
    }
}
