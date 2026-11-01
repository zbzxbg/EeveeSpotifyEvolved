import Foundation

/// 「伪逐字填充」：给**只有行级时间**的歌词行合成一份逐字时间轴。
///
/// 由来：`LyricVocalDurationEstimator` 是从 MeloX 移植的，那个文件头原话就是
/// "用于给出「伪逐字」时间轴与间奏判定" —— 本仓库一直只用了后半句（判定间奏）。
///
/// ⚠️ 三条纪律，改之前先读：
///
/// 1. **行起点是真的，只有行内分布是估的** ⇒ 这里只产"渲染用的音节"，
///    绝不改变 `LyricLine.timingKind`。一旦把这类行标成 `.precise`，
///    `LyricInterludeTimeline` 就会把估出来的间隙当成作者时间轴
///    （`.preciseTiming` 那条分支），间奏点会开始在每处换气上乱冒。
/// 2. 填料终点与 `LyricInterludeTimeline.contentEndTime` **同一套算法**
///    （`min(估算演唱时长, 到下一行的时长)`）。两处算得不一样的话，会出现
///    "这一行还没填完，间奏点已经开始"或者"填完了但点还没亮"。
/// 3. 拼出来的文本必须**逐字等于**原行。渲染层是把音节文本拼回整行、再按字符
///    下标记时的，少一个空格整行都会漂。
///
/// 它确实是在编时间（所以挂在「实验」里、默认关）：一行唱得比估算快/慢时，
/// 填充前沿会提前或滞后。估算值本身很保守（每字 0.32s，钳在 2~8 秒）。
enum PseudoWordTiming {

    /// 一个字的填充片。
    struct Piece: Equatable {
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    /// 合成一行。文本为空 / 只有空白 / 时间不可用 ⇒ 空数组（调用方退回普通文本）。
    ///
    /// - Parameters:
    ///   - text: 行文本（取 `LyricsLineDto.content`，与渲染层用的 `text` 同源）。
    ///   - startTime: 这一行的**真实**起点。
    ///   - nextStartTime: 下一行起点；`nil` 表示末行（只按估算值铺）。
    static func pieces(
        for text: String,
        startTime: TimeInterval,
        nextStartTime: TimeInterval?
    ) -> [Piece] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }

        let visibleCount = characters.filter { !$0.isWhitespace }.count
        guard visibleCount > 0 else { return [] }

        let estimated = LyricVocalDurationEstimator.estimatedDuration(for: text)
        // 不许越过下一行（与 `contentEndTime` 同一条夹取）。
        let fillDuration: TimeInterval
        if let available = nextStartTime.map({ max($0 - startTime, 0) }) {
            // 两行起点相同（或下一行在起点之前）⇒ 这一行没有可填的窗口，直接不填。
            guard available > 0 else { return [] }
            fillDuration = min(estimated, available)
        } else {
            fillDuration = estimated
        }
        guard fillDuration.isFinite, fillDuration > 0 else { return [] }

        let perCharacter = fillDuration / Double(visibleCount)
        var pieces: [Piece] = []
        pieces.reserveCapacity(characters.count)

        var cursor = startTime
        for character in characters {
            if character.isWhitespace {
                // 空格不占时间（占时间会在词与词之间"卡"一下），但**必须留在列表里**，
                // 否则拼回来的整行少一个字符，后面的字符下标全部前移。
                pieces.append(
                    Piece(text: String(character), startTime: cursor, endTime: cursor)
                )
                continue
            }

            let next = min(cursor + perCharacter, startTime + fillDuration)
            pieces.append(
                Piece(text: String(character), startTime: cursor, endTime: next)
            )
            cursor = next
        }

        return pieces
    }
}
