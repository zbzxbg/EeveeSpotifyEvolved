import Foundation

extension LyricsDto {

    /// 把整份歌词的时间轴平移 `offsetMs`（**正数 = 时间戳后移 = 歌词出现得更晚**）。
    ///
    /// 只动时间、不动文本。用于「歌词偏移」（见 `LyricsTimingOffset`）：
    /// 行级、逐词、以及 AMLL 的副唱音节必须**一起**移，否则行对了、词还会跳。
    /// 起对**所有歌词源**生效（Genius 除外），施加点是
    /// `CustomLyrics.storeLyricsDto`。
    ///
    /// 早于 0 的时间戳夹到 0（一行“在歌曲开始前就该出现”等价于一开始就显示）。
    func applyingTimingOffset(_ offsetMs: Int) -> LyricsDto {
        guard offsetMs != 0 else { return self }

        var result = self
        result.lines = result.lines.map { line in
            var line = line
            line.offsetMs = shifted(line.offsetMs, by: offsetMs)
            line.endOffsetMs = shifted(line.endOffsetMs, by: offsetMs)

            if let words = line.words {
                line.words = words.map { shifted($0, by: offsetMs) }
            }
            if var vocal = line.backgroundVocal {
                vocal.syllables = vocal.syllables.map { shifted($0, by: offsetMs) }
                line.backgroundVocal = vocal
            }
            return line
        }
        return result
    }

    private func shifted(_ value: Int?, by offset: Int) -> Int? {
        guard let value else { return nil }
        return max(0, value + offset)
    }

    private func shifted(_ word: LyricsWordDto, by offset: Int) -> LyricsWordDto {
        var word = word
        word.startMs = max(0, word.startMs + offset)
        if let end = word.endMs {
            word.endMs = max(0, end + offset)
        }
        return word
    }
}
