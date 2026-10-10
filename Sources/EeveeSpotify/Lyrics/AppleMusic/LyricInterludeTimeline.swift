import Foundation

// 移植自 MeloX `MeloX/Core/Lyrics/LyricInterludeTimeline.swift` 的**检测与定位**部分（GPL-3.0）。
//
// 模型部分（`LyricInterlude` / `LyricInterludePlaybackPosition` / 两个枚举）先落在
// `LyricInterlude.swift` 里；这个文件补的是当时那行 TODO 点名的三件：
//
//   ① **间隙阈值** —— `minimumAnimatedGapDuration` = 填充前导 1s + 退出 1.8s。
//      比这更短的间隙连"点亮 → 退出"两个阶段都放不下，硬放只会看到点闪一下；
//      `normalizedInferredThreshold` 再把外部给的阈值夹到这条下界之上。
//   ② **`contentEndTime` 估算** ——「这一句唱到什么时候」：
//      作者标注的 `duration` 与最后一个音节的结束时间取**大者**；
//      只有行级时间的来源（`.lineSynchronized`）退回 `LyricVocalDurationEstimator`，
//      而且**不得超过**该行的显示时长 —— 下一行的起点就是人声尾部的上限，
//      否则估出来的尾巴会把整段间隙吃掉，间奏就永远判不出来。
//   ③ **policy 过滤** —— `.preciseTiming` 只认作者时间轴；`.automatic(threshold)`
//      把推断出来的 LRC 间隙也算进来（阈值先过一遍 `normalizedInferredThreshold`）。
//
// 附带 `position(at:in:)`：给定播放时间，回答「现在该显示哪个间奏、焦点归谁」。
// 它是纯函数，**不含时钟** —— 时钟由调用方给（本项目 = `AppleMusicLyricsPage` 宿主里
// 那条已经过真机验证的 CADisplayLink，见那个文件顶部"为什么不用 TimelineView"）。
//
// ⚠️ 与 MeloX 的差别只有措辞级：去掉 `nonisolated`（本仓库其余移植件也没用）、
//    注释改中文、`switch` 统一写成显式 `return`。阈值、判据、顺序一律照抄。

enum LyricInterludeTimeline {

    /// 能把「呼吸点」两个阶段都放完的最短间隙：填充前导 1s + 退出 1.8s。
    ///
    /// ⚠️ 这条下界**不只看 `.preciseTiming`** —— `.automatic` 传进来的阈值
    /// 也要被它夹一次（见 `normalizedInferredThreshold`），否则一个 1s 的阈值会让
    /// 每一处换气都变成间奏。
    static let minimumAnimatedGapDuration: TimeInterval =
        AppleMusicInterludeMotionProfile.iOS26_6.fillLeadInDuration
        + AppleMusicInterludeMotionProfile.iOS26_6.cueOutLeadTime

    /// 先把**候选**全算出来（一首歌一次），policy 之后再筛。
    ///
    /// 为什么分两步：换 policy（或用户拖阈值）不该重新解析歌词、更不该每帧重估人声尾部。
    /// 候选是"时间几何"的事实，policy 是"要不要显示"的口味，两者分开才缓存得住。
    ///
    /// 两头都照顾到：
    ///   · **前奏** —— 从 0 到第一句真正有内容时间的歌词之间也算一段间奏（`precedingLyricID == nil`）；
    ///   · 每两句之间 —— 上一句的人声尾部到下一句的起点。
    static func candidates(in lyrics: [LyricLine]) -> [LyricInterlude] {
        guard let firstLyric = lyrics.first else { return [] }

        var result: [LyricInterlude] = []

        // 网易云 YRC 会在 t=0 前面塞几行没有时间的内容行（作词/作曲之类）。
        // 真正"音乐开始"的是第一行**有可用内容时间**的歌词 ⇒ 前奏要落在它上面，
        // 否则间奏行会插在制作信息前面。
        let firstMusicalLyric = lyrics.first {
            contentEndTime(for: $0) != nil
        } ?? firstLyric

        if let prelude = makeInterlude(
            startTime: 0,
            precedingLyricID: nil,
            followingLyric: firstMusicalLyric,
            displayBeforeLyricID: firstMusicalLyric.id,
            timingSource: firstMusicalLyric.timingKind.interludeTimingSource
        ) {
            result.append(prelude)
        }

        guard lyrics.count > 1 else { return result }

        for followingIndex in lyrics.indices.dropFirst() {
            let precedingIndex = lyrics.index(before: followingIndex)
            let precedingLyric = lyrics[precedingIndex]
            let followingLyric = lyrics[followingIndex]

            guard let precedingEndTime = contentEndTime(for: precedingLyric),
                  let interlude = makeInterlude(
                      startTime: precedingEndTime,
                      precedingLyricID: precedingLyric.id,
                      followingLyric: followingLyric,
                      displayBeforeLyricID: followingLyric.id,
                      timingSource: precedingLyric.timingKind.interludeTimingSource
                  ) else {
                continue
            }
            result.append(interlude)
        }

        return result
    }

    /// 候选 → 按 policy 筛出真正要显示的间奏。
    static func interludes(
        in lyrics: [LyricLine],
        detectionPolicy: LyricInterludeDetectionPolicy
    ) -> [LyricInterlude] {
        interludes(
            from: candidates(in: lyrics),
            detectionPolicy: detectionPolicy
        )
    }

    /// 同上，但候选已经算好了（每帧调用时用这个，别重复推一遍）。
    static func interludes(
        from candidates: [LyricInterlude],
        detectionPolicy: LyricInterludeDetectionPolicy
    ) -> [LyricInterlude] {
        candidates.filter { interlude in
            switch (detectionPolicy, interlude.timingSource) {
            case (.preciseTiming, .precise):
                return interlude.gapDuration >= minimumAnimatedGapDuration
            case (.preciseTiming, .lineSynchronized):
                // 作者时间轴那一档**故意不认**推断出来的 LRC 间隙：
                // 那里"人声尾部"是我们自己估的，把估计值当事实去显示倒计时会误报。
                return false
            case (.automatic, .precise):
                return interlude.gapDuration >= minimumAnimatedGapDuration
            case let (.automatic(minimumInferredGapDuration), .lineSynchronized):
                return interlude.gapDuration
                    >= normalizedInferredThreshold(minimumInferredGapDuration)
            }
        }
    }

    /// 给定播放时间 → 这一拍该显示什么。
    ///
    /// 三个阶段（顺序不能换）：
    ///   1. 还没到 → 什么都不显示，但把 `nextTransitionTime` 报出去（调用方据此定时）；
    ///   2. `visualEndTime` 之前 → 点阵可见、**并且占着焦点**；
    ///   3. `countdownEndTime`（= 下一句的起点）之前 → 点阵已经视觉清空，但这一行
    ///      仍然"是它"（`visibleInterludeID` 不变，让视图认得出这是一次间奏交接），
    ///      同时把下一句提升为焦点行（`promotedLyricID`）。
    ///
    /// ⚠️ 第 3 阶段是 MeloX 的"提升"语义；本项目的渲染层暂时只消费前两个字段
    /// （见 `AppleMusicInterludeRow` 顶部说明），`promotedLyricID` 先照抄不丢。
    static func position(
        at playbackTime: TimeInterval,
        in interludes: [LyricInterlude]
    ) -> LyricInterludePlaybackPosition {
        guard playbackTime.isFinite else {
            return inactivePosition(nextTransitionTime: nil)
        }

        for interlude in interludes {
            let motionTiming = AppleMusicInterludeMotionProfile.iOS26_6.timing(
                for: interlude
            )

            if playbackTime < interlude.startTime {
                return inactivePosition(
                    nextTransitionTime: interlude.startTime
                )
            }

            if playbackTime < motionTiming.visualEndTime {
                return LyricInterludePlaybackPosition(
                    visibleInterludeID: interlude.id,
                    focusedInterludeID: interlude.id,
                    promotedLyricID: nil,
                    nextTransitionTime: motionTiming.visualEndTime
                )
            }

            if playbackTime < interlude.countdownEndTime {
                return LyricInterludePlaybackPosition(
                    // 槽位一直认到「作者标注的下一句起点」为止：视图才认得出
                    // "这不是普通的一行、是一次间奏交接"。点在这时其实已经画空了。
                    visibleInterludeID: interlude.id,
                    focusedInterludeID: nil,
                    promotedLyricID: interlude.followingLyricID,
                    nextTransitionTime: interlude.countdownEndTime
                )
            }
        }

        return inactivePosition(nextTransitionTime: nil)
    }

    private static func inactivePosition(
        nextTransitionTime: TimeInterval?
    ) -> LyricInterludePlaybackPosition {
        LyricInterludePlaybackPosition(
            visibleInterludeID: nil,
            focusedInterludeID: nil,
            promotedLyricID: nil,
            nextTransitionTime: nextTransitionTime
        )
    }

    private static func makeInterlude(
        startTime: TimeInterval,
        precedingLyricID: LyricLine.ID?,
        followingLyric: LyricLine,
        displayBeforeLyricID: LyricLine.ID,
        timingSource: LyricInterludeTimingSource
    ) -> LyricInterlude? {
        guard startTime.isFinite,
              followingLyric.time.isFinite else {
            return nil
        }

        let countdownEndTime = max(startTime, followingLyric.time)
        // 间隙为零（或负）不算间奏 —— 这是"两句之间真的有空白"的唯一硬判据。
        guard countdownEndTime > startTime else { return nil }

        return LyricInterlude(
            startTime: startTime,
            countdownEndTime: countdownEndTime,
            precedingLyricID: precedingLyricID,
            followingLyricID: followingLyric.id,
            displayBeforeLyricID: displayBeforeLyricID,
            timingSource: timingSource
        )
    }

    /// 「这一句唱到什么时候」—— 见文件头 ②。
    private static func contentEndTime(
        for lyric: LyricLine
    ) -> TimeInterval? {
        if lyric.timingKind == .lineSynchronized {
            let estimatedDuration = LyricVocalDurationEstimator.estimatedDuration(
                for: lyric.text
            )
            let displayDuration = lyric.duration.flatMap {
                duration -> TimeInterval? in
                guard duration.isFinite, duration > 0 else { return nil }
                return duration
            }
            // 估出来的演唱时长**不能超过**这一行实际显示多久（下一行的起点就是上限）：
            // 只有行级时间的来源里，`duration` 本来就是"到下一句为止"，
            // 拿它当上限才不会把间隙吃掉。
            let contentDuration = min(
                estimatedDuration,
                displayDuration ?? estimatedDuration
            )
            return lyric.time + contentDuration
        }

        let durationEndTime: TimeInterval? = lyric.duration.flatMap {
            duration -> TimeInterval? in
            guard duration.isFinite, duration > 0 else { return nil }
            return lyric.time + duration
        }
        let syllableEndTime = lyric.syllables
            .lazy
            .map(\.endTime)
            .filter(\.isFinite)
            .max()

        // 两者取大者：有的来源只给行 duration，有的只给逐字/逐音节时间，谁都可能更长。
        return [durationEndTime, syllableEndTime]
            .compactMap { $0 }
            .max()
    }

    private static func normalizedInferredThreshold(
        _ value: TimeInterval
    ) -> TimeInterval {
        value.isFinite
            ? max(value, minimumAnimatedGapDuration)
            : minimumAnimatedGapDuration
    }
}

private extension LyricLineTimingKind {
    var interludeTimingSource: LyricInterludeTimingSource {
        switch self {
        case .precise:
            return .precise
        case .lineSynchronized:
            return .lineSynchronized
        }
    }
}
