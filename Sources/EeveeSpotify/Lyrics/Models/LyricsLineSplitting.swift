import Foundation

// MARK: - 歌词正文按行拆
//
// 为什么单独一个文件：LRCLIB 的两条路（`syncedLyrics` / `plainLyrics`）原来都写
// `components(separatedBy: "\n").dropLast` —— 那是**假定响应以换行收束**。
//
// LRCLIB 大多数时候确实带尾换行（那时拆出来的最后一个元素是空串，丢掉它是对的），
// 但**没有尾换行的响应里，`dropLast` 丢的正是最后一行真歌词**，而且丢得静默：
// 日志只说 "N line(s)"，N 比真歌词少 1，没有任何东西会变红。
//
// 判据改成「**最后一个元素是空串才丢**」：与旧行为在"有尾换行"时逐字节一致，
// 在"没有尾换行"时保住最后一行。它只依赖 Foundation，所以能进 `tests.yml`
// 的纯逻辑测试（本机没有 Swift 工具链）。

enum LyricsLineSplitting {

    /// 按 `\n` 拆行，并且**只在末尾确实是一个空行时**把它丢掉。
    ///
    /// "a\nb\n" → ["a", "b"] （与旧的 `dropLast` 一致）
    /// "a\nb" → ["a", "b"] （旧的 `dropLast` 会把 "b" 吃掉）
    static func splitDroppingTrailingNewline(_ raw: String) -> [String] {
        var lines = raw.components(separatedBy: "\n")
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }
}
