import AVFoundation
import Foundation
import QuartzCore

/// 「音乐触感」：把 `AudioFeatures` 的 onset 事件变成 Taptic 反馈。
///
/// 三条闸门（都在主线程 30 / 60Hz 的那一拍里算，不碰音频线程）：
/// · **最小间隔 90ms**：再密的鼓点也不会变成连续震动；
/// · **连续 30 秒后自动降档**（间隔放到 200ms、强度打折）—— Taptic Engine 长时间高频会钝、
///   会发热，降档比"一直满强度"更接近人手能接受的程度；
/// · **静音 / 暂停不触发**：靠 `isFresh`（没有新的音频回调就什么都不做）。
///
/// 触发判据不在这里：`AudioFeatures` 已经按 128 帧的滑窗给出"哪一路、多强、落在块内哪里"
/// 的 onset；这里只负责按顺序消费、按频带选触感、按间隔丢重复。
enum MusicHaptics {

    private static let logTag = AudioFeatures.logTag

    /// 两次触发之间的最小间隔（秒）。
    private static let minimumGap = 0.09
    /// 降档后的最小间隔。
    private static let degradedGap = 0.20
    /// 连续触发超过这个时长就降档。
    private static let degradeAfter = 30.0
    /// 超过这个时长没有触发，视为一段新的"连击"，强度从满档重新开始。
    private static let idleReset = 5.0

    /// 已经消费到的 onset 序号；`primed` 之前只对齐、不补打。
    private static var lastSeenSerial: UInt64 = 0
    private static var primed = false
    private static var lastTriggerAt: CFTimeInterval = 0
    private static var windowStartedAt: CFTimeInterval = 0
    private static var windowTriggers = 0
    /// 被 90ms 地板挡掉的 onset 数（从上次真的打出去算起）—— 诊断用。
    private static var suppressedSinceLastTap = 0
    /// 逐次诊断日志的预算：一首长歌最多这么多行，别把日志刷爆。
    private static let tapLogBudget = 900
    private static var loggedTaps = 0
    private static var didLogBudget = false

    /// 用户选的强度档 1…3（默认中档 2）。
    static var strength: Int {
        min(max(UserDefaults.musicHapticsStrength, 1), 3)
    }

    /// 档位 → 强度。中档就能摸到，高档不刺耳；低档在公交上基本感觉不到。
    private static var intensity: CGFloat {
        switch strength {
        case 1: return 0.35
        case 3: return 0.90
        default: return 0.60
        }
    }

    /// 设置页那颗「试一下」：用同一套强度和引擎，能当场分辨"引擎没反应"和"设置没生效"。
    static func testTap() {
        HapticFeedback.musicKick(intensity: intensity)
    }

    static func reset() {
        lastSeenSerial = 0
        primed = false
        lastTriggerAt = 0
        windowStartedAt = 0
        windowTriggers = 0
        suppressedSinceLastTap = 0
        loggedTaps = 0
        didLogBudget = false
    }

    /// 一拍：消费这一拍新到的 onset，按闸门决定打几下。
    ///
    /// - Parameter isFresh: 这一拍有没有读到新的音频回调（false = 音频停了，不做任何事）。
    static func consume(_ snapshot: AudioFeatures.Snapshot, isFresh: Bool, now: CFTimeInterval) {
        guard isFresh else {
            if windowTriggers > 0, now - lastTriggerAt > idleReset {
                windowTriggers = 0
            }
            return
        }
        // 第一条只对齐基准（重启 / 刚打开开关时不要补打上一轮的旧事件）。
        if !primed || snapshot.onsetSerial < lastSeenSerial {
            lastSeenSerial = snapshot.onsetSerial
            primed = true
            return
        }
        guard snapshot.onsetSerial > lastSeenSerial else {
            if windowTriggers > 0, now - lastTriggerAt > idleReset {
                windowTriggers = 0
            }
            return
        }

        let seen = lastSeenSerial
        let pending = [
            snapshot.onsets.0,
            snapshot.onsets.1,
            snapshot.onsets.2,
            snapshot.onsets.3,
        ]
        .filter { $0.serial > seen }
        .sorted { $0.serial < $1.serial }
        lastSeenSerial = snapshot.onsetSerial

        guard !pending.isEmpty else {
            if windowTriggers > 0, now - lastTriggerAt > idleReset {
                windowTriggers = 0
            }
            return
        }

        for onset in pending {
            if windowTriggers == 0 { windowStartedAt = now }
            let degraded = now - windowStartedAt > degradeAfter
            let gap = degraded ? degradedGap : minimumGap
            guard now - lastTriggerAt >= gap else {
                suppressedSinceLastTap += 1
                continue
            }
            fire(onset, degraded: degraded, snapshot: snapshot, now: now)
        }
    }

    /// 打一下：频带决定触感（low = 底鼓、high = 更脆的军鼓），强度由 onset 的
    /// 绝对响度折算。
    private static func fire(
        _ onset: AudioFeatures.Onset,
        degraded: Bool,
        snapshot: AudioFeatures.Snapshot,
        now: CFTimeInterval
    ) {
        let hit = min(max(onset.strength, 0), 1)
        let degradeScale: CGFloat = degraded ? 0.7 : 1
        let level = intensity * (0.45 + 0.55 * CGFloat(hit)) * degradeScale
        switch onset.band {
        case 0:
            HapticFeedback.musicKick(intensity: level)
        default:
            // high 更短更脆：同一档强度再压一点，否则听起来像两个底鼓。
            HapticFeedback.musicSnare(intensity: level * 0.85)
        }
        let previousTriggerAt = lastTriggerAt
        lastTriggerAt = now
        windowTriggers += 1
        logTap(
            onset,
            snapshot: snapshot,
            now: now,
            gap: previousTriggerAt > 0 ? now - previousTriggerAt : nil,
            degraded: degraded
        )
        suppressedSinceLastTap = 0
    }

    /// 每真打一次写一行。
    ///
    /// 这一行同时回答三件事：
    /// · `age` —— 这个 onset 在音频里出现到现在（主线程这一拍）过了多久。**这就是
    ///   "分析 → 打出去"那一段的全部延迟**，正数意味着它已经开始播、我们晚了；
    /// · `str` / `skip` —— 这一下有多强、之前被 90ms 地板挡掉几次；
    /// · `band` —— low / high，用来判断是哪一路在误触（例如踩镲混进了 high）。
    private static func logTap(
        _ onset: AudioFeatures.Onset,
        snapshot: AudioFeatures.Snapshot,
        now: CFTimeInterval,
        gap: CFTimeInterval?,
        degraded: Bool
    ) {
        guard loggedTaps < tapLogBudget else {
            guard !didLogBudget else { return }
            didLogBudget = true
            writeDebugLog(
                "[\(logTag)] tap diag — \(tapLogBudget) line(s) written; further taps are not logged"
            )
            return
        }
        loggedTaps += 1

        let age: String
        if onset.hostTime != 0 {
            // `mHostTime` 是 mach 绝对时钟，和 `CACurrentMediaTime()` 同一个时基。
            // `AVAudioTime.seconds(forHostTime:)` 是公开 API；CoreAudio 那两个
            // `Audio…HostTime` 函数在 iOS 上会被当成私有符号。
            let seconds = AVAudioTime.seconds(forHostTime: onset.hostTime)
                + Double(onset.offsetSeconds)
            age = String(format: "%+.3f", now - seconds)
        } else {
            age = "?"
        }
        let gapText = gap.map { String(format: "%.3f", $0) } ?? "first"
        writeDebugLog(
            "[\(logTag)] tap \(bandName(onset.band)) s=\(strength)"
                + (degraded ? " degraded" : "")
                + " gap=\(gapText) age=\(age)"
                + " str=\(String(format: "%.2f", onset.strength))"
                + " blk=\(snapshot.blockFrames)"
                + " skip=\(suppressedSinceLastTap)"
                + " low=\(String(format: "%.3f", snapshot.low))"
                + " high=\(String(format: "%.3f", snapshot.high))"
        )
    }

    private static func bandName(_ band: UInt8) -> String {
        band == 0 ? "low" : "high"
    }
}
