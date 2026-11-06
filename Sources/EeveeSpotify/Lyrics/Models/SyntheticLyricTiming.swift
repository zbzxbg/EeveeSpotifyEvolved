import Foundation

/// 给**占位文案**合成行级时间轴（只服务这一条路）。
///
/// ── 为什么还需要它
/// Spotify 9.1.x 把 NPV 歌词模块重写成响应驱动的组件（`Lyrics_CardElementImpl.*` /
/// `Lyrics_NPVElementsKitImpl.*`）。**无时间轴的 payload 在这个版本上有可能整个不显示**，
/// 而占位恰恰是"取不到词"那条路上唯一交出去的东西。所以 `makeUnavailableLyrics` 给它补
/// 一层按曲目时长铺开的行级时间轴（那里**写死**调用，没有开关）。
///
/// ⚠️ **真实歌词源不合成**：给本来没有时间轴的源（Genius / PetitLyrics 这类纯文本）编一层
/// 假 offset 只会让整首都不准；歌词模块出现与否由元素列表决定，不需要靠伪造时间轴去骗
/// 渲染层。
///
/// ── 边界（重要）
/// · 只作用于**占位 payload**，不碰任何真实歌词源的数据。
/// · 合成是**近似**的：行会按字符权重被铺在曲目时长上，位置不保证准确。
///   对一个只写着"未找到歌词"的占位来说，这个精度足够。
enum SyntheticLyricTiming {

    /// 每行至少占用的时长，避免超短行被压成 0ms 导致相邻行 offset 相同。
    private static let minimumLineMs = 900

    /// 字符权重的下限：空行/极短行（副歌间的空档）也要占到一点时间。
    private static let minimumWeight = 4

    /// 拿不到曲目时长时的兜底单行时长。
    private static let fallbackLineMs = 4000

    /// 判定"这份数据已经自带时间轴"：至少一半的行有有效 offset。
    ///
    /// 口径与 `hasUsableLineLevelData` 一致（同样 50% 阈值），
    /// 这样"我们认为可用"与"渲染层认为可用"不会打架。
    /// 现在只剩占位这一条路会用；占位行永远没有真实 offset，
    /// 这个判据的作用是"别把已经铺过时间轴的那份再铺一遍"。
    static func alreadyHasLineTiming(_ lines: [LyricsLineDto]) -> Bool {
        guard !lines.isEmpty else { return false }
        let timed = lines.filter { ($0.offsetMs ?? 0) > 0 }.count
        return timed * 10 >= lines.count * 5
    }

    /// 返回一份**每一行都有 offset** 的副本。
    ///
    /// - Parameter lines: 原始行。
    /// - Parameter durationMs: 曲目时长（毫秒）。为 nil 时按每行 `fallbackLineMs` 估算。
    /// - Returns: 行数相同、offset 单调递增的副本。
    /// 若原来已经有一半以上的行带 offset，则**原样返回**（不覆盖真实时间轴）。
    static func applying(
        to lines: [LyricsLineDto],
        durationMs: Int?
    ) -> [LyricsLineDto] {
        guard !lines.isEmpty else { return lines }
        guard !alreadyHasLineTiming(lines) else { return lines }

        let weights = lines.map { max($0.content.count, minimumWeight) }
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return lines }

        // 总时长：拿不到就用"行数 × 兜底单行时长"估一个，保证 offset 能单调铺开。
        let totalMs = max(durationMs ?? (lines.count * fallbackLineMs), lines.count * minimumLineMs)

        var result: [LyricsLineDto] = []
        result.reserveCapacity(lines.count)

        var accumulatedWeight = 0
        var accumulatedMs = 0
        for (index, line) in lines.enumerated() {
            // 每行起点取"按累计权重算出的位置"与"上一行之后至少 minimumLineMs"
            // 两者中的较大值 —— 前者让整体分布贴合时长，后者保证严格递增。
            let weightedMs = totalMs * accumulatedWeight / totalWeight
            let startMs = max(weightedMs, accumulatedMs)

            var copy = line
            copy.offsetMs = startMs
            result.append(copy)

            accumulatedMs = startMs + minimumLineMs
            accumulatedWeight += weights[index]
        }

        // 末行起点必须落在时长之内，否则会被 Spotify 当成"整首都在未来"。
        if let last = result.last?.offsetMs, last >= totalMs, result.count > 1 {
            result[result.count - 1].offsetMs = max(totalMs - minimumLineMs, 0)
        }

        return result
    }
}
