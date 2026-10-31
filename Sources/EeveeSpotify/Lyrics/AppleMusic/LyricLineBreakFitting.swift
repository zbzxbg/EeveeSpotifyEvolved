import Foundation

/// 「这一行该在哪里折」的**复核器** —— 纯逻辑：只依赖一个"给我量这段宽度"的闭包，不碰 UIKit。
///
/// ```
/// [LyricWrap] fs=22.0 w=334.0 layout=331.8 text=405.4 breaks=[36] "I'm tryna put you in the worst mood ↵ah"
/// [LyricWrap] fs=22.0 w=334.0 layout=331.8 text=394.4 breaks=[]   "P1 cleaner than your church shoes ah"
/// [LyricWrap] fs=22.0 w=334.0 layout=331.8 text=337.0 breaks=[]   "I switch up my cup I kill any pain"
/// ```
/// 按 331.8pt 的预算，337~394pt 的行**本该折**，CoreText 却一个断点都没给；而给了断点的 5 行
/// `text` 都在 405~557pt ⇒ **折行那一侧与渲染那一侧不是同一把尺子**
/// （折行用 `CTFontCreateWithName(uiFont.fontName)`，渲染与诊断用 `UIFont.systemFont`）。
///
/// 后果正是的那件事：断点被插在**太靠右**的位置 ⇒ 第一段仍然超宽 ⇒ 渲染器再折一次
/// ⇒ 屏幕上多出一行。
///
/// 这个类型只做一件事：**拿渲染那把尺子复核 CoreText 的断点**，把仍然超宽的那一段再切开。
/// 它**只加、不删**（CoreText 原有的断点全部保留）⇒ 最坏情况与改动前逐字相同，不会更糟。
enum LyricLineBreakFitting {

    /// 把 `[0, count)` 按断点切成若干**视觉行**区间（升序、不重叠、无空段）。
    ///
    /// 例：`count = 10, breaks = [4]` ⇒ `[0..<4, 4..<10]`。
    /// 断点里 0 / count / 越界 / 重复一律忽略。
    static func segments(count: Int, breaks: Set<Int>) -> [Range<Int>] {
        guard count > 0 else { return [] }
        let cuts = ([0] + breaks.filter { $0 > 0 && $0 < count }.sorted() + [count])
        var result: [Range<Int>] = []
        for index in 0..<(cuts.count - 1) where cuts[index] < cuts[index + 1] {
            result.append(cuts[index]..<cuts[index + 1])
        }
        return result
    }

    /// **整行重排**：完全丢掉 CoreText 的断点，用渲染那把尺子从头贪心折行。
    ///
    /// （逐词歌词**额外换行**还没修吗+「Melox 就没这个问题」）：
    ///
    /// `verifiedBreaks` 只加不删 ⇒ **CoreText 自己那个多余的断点永远留着**。
    /// Starboy L2 就是现场：
    ///
    /// ```
    /// text=405.4 layout=331.8 ct=342.5 breaks=[31,36] "I'm tryna put you in the worst ↵mood ↵ah"
    /// ```
    ///
    /// CoreText 断在 36（"ah" 前），它的第一段 `…worst mood` 量出来 342.5 > 331.8 ⇒ 我们又在 31 补一刀
    /// ⇒ 屏幕上**三行**：`…worst` / `mood` / `ah`。正确的两行是 `…worst` / `mood ah`。
    ///
    /// 重排一次就对了：贪心地从行首吃词，吃不下就在**上一个空格后**断；没有空格就硬切。
    /// 只在"整行确实超宽"时由调用方启用（整行放得下就一个断点都不需要）。
    static func reflowBreaks(
        text: String,
        count: Int,
        layoutWidth: CGFloat,
        measure: (Range<Int>) -> CGFloat
    ) -> Set<Int> {
        guard count > 1, layoutWidth > 0 else { return [] }
        let characters = Array(text)
        guard characters.count == count else { return [] }

        var result: Set<Int> = []
        var lineStart = 0
        while lineStart < count - 1 {
            var end = lineStart + 1
            var lastSpace: Int?
            while end <= count {
                let width = measure(lineStart..<end)
                if width > layoutWidth { break }
                if characters[end - 1] == " " { lastSpace = end }
                end += 1
            }
            // 剩下的都放得下 ⇒ 收工。
            if end > count { break }

            // 在最后一个空格后断（空格留在上一行）；一行里没有空格才硬切。
            var cut = lastSpace ?? (end - 1)
            if cut <= lineStart { cut = lineStart + 1 }
            if cut >= count { break }
            result.insert(cut)
            lineStart = cut
        }
        return result
    }

    /// 复核断点：返回 CoreText 的断点 ∪ 补出来的断点。
    ///
    /// - Parameters:
    /// - text: 整行文本（按 `Character` 切）
    /// - count: 字符数（调用方已经算过就传进来，省一次 `Array(text)`）
    /// - layoutWidth: 可用的排版宽度
    /// - coreTextBreaks: CoreText 给出的断点（字符下标）
    /// - measure: 量 `[lower, upper)` 这段文本的排版宽度 —— **必须是渲染那一侧的字体重量的**
    /// - Returns: 复核后的断点集合。
    static func verifiedBreaks(
        text: String,
        count: Int,
        layoutWidth: CGFloat,
        coreTextBreaks: Set<Int>,
        measure: (Range<Int>) -> CGFloat
    ) -> Set<Int> {
        var result = coreTextBreaks.filter { $0 > 0 && $0 < count }
        guard count > 1, layoutWidth > 0 else { return result }

        let characters = Array(text)
        guard characters.count == count else { return result }

        for segment in segments(count: count, breaks: result) {
            guard segment.count > 1 else { continue }
            for split in splits(
                in: segment,
                characters: characters,
                layoutWidth: layoutWidth,
                measure: measure
            ) {
                result.insert(split)
            }
        }
        return result
    }

    /// 把一个仍然超宽的区间再切：优先断在**空白之后**（词的边界），没有空白就断在字符边界
    /// （CJK 需要后者）。
    private static func splits(
        in segment: Range<Int>,
        characters: [Character],
        layoutWidth: CGFloat,
        measure: (Range<Int>) -> CGFloat
    ) -> [Int] {
        var splits: [Int] = []
        var cursor = segment.lowerBound
        // 有界：最多切"字符数 + 8"次（正常情况下几次就够，防止测量异常时死循环）。
        var steps = 0
        while cursor < segment.upperBound, steps < characters.count + 8 {
            steps += 1
            if measure(cursor..<segment.upperBound) <= layoutWidth { break }

            // 往后扫到"最后一个放得下的位置"；同时记住最后一个"空白之后"的位置。
            var best = cursor + 1
            var bestAfterSpace = -1
            var probe = cursor + 1
            while probe <= segment.upperBound {
                if measure(cursor..<probe) <= layoutWidth {
                    best = probe
                    if probe < segment.upperBound, characters[probe - 1].isWhitespace {
                        bestAfterSpace = probe
                    }
                } else {
                    break
                }
                probe += 1
            }

            let split = bestAfterSpace > cursor ? bestAfterSpace : best
            guard split > cursor, split < segment.upperBound else { break }
            splits.append(split)
            cursor = split
        }
        return splits
    }
}
