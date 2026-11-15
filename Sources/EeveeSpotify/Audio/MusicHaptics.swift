import Foundation
import QuartzCore

/// 「音乐触感」：把 kick / snare 的瞬态计数变成 Taptic 反馈。
///
/// 三条闸门（都在主线程 30Hz 的那一拍里算，不碰音频线程）：
/// · **最小间隔 90ms**：再密的鼓点也不会变成连续震动；
/// · **连续 30 秒后自动降档**（间隔放到 200ms、强度打折）—— Taptic Engine 长时间高频会钝、
///   会发热，降档比"一直满强度"更接近人手能接受的程度；
/// · **静音 / 暂停不触发**：靠 `isFresh`（没有新的音频回调就什么都不做）。
///
/// 强度是用户选的 1…3 档；这里只管"打不打、打多重"。
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

    private static var lastKickCount: UInt64 = 0
    private static var lastSnareCount: UInt64 = 0
    /// 计数是"从进程启动累计"的：ticker 刚起来的那一拍要先对齐基准，
    /// 否则第一个 `kickCount > 0` 会被当成"这一拍有新的鼓点"、凭空震一下。
    private static var primed = false
    private static var lastTriggerAt: CFTimeInterval = 0
    private static var windowStartedAt: CFTimeInterval = 0
    private static var windowTriggers = 0
    private static var didLogFirstTrigger = false

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
        lastKickCount = 0
        lastSnareCount = 0
        primed = false
        lastTriggerAt = 0
        windowStartedAt = 0
        windowTriggers = 0
        didLogFirstTrigger = false
    }

    /// 一拍：有新的 kick / snare 就按闸门决定要不要打一下。
    ///
    /// - Parameter isFresh: 这一拍有没有读到新的音频回调（false = 音频停了，不做任何事）。
    static func consume(_ snapshot: AudioFeatures.Snapshot, isFresh: Bool, now: CFTimeInterval) {
        // 第一条只对齐基准（见 `primed`）；计数"变小"（理论上只在重启后出现）同样只对齐。
        if !primed || snapshot.kickCount < lastKickCount || snapshot.snareCount < lastSnareCount {
            lastKickCount = snapshot.kickCount
            lastSnareCount = snapshot.snareCount
            primed = true
            return
        }
        let newKicks = snapshot.kickCount > lastKickCount
        let newSnares = snapshot.snareCount > lastSnareCount
        lastKickCount = snapshot.kickCount
        lastSnareCount = snapshot.snareCount

        guard isFresh, newKicks || newSnares else {
            if windowTriggers > 0, now - lastTriggerAt > idleReset {
                windowTriggers = 0
            }
            return
        }

        if windowTriggers == 0 { windowStartedAt = now }
        let degraded = now - windowStartedAt > degradeAfter
        let gap = degraded ? degradedGap : minimumGap
        guard now - lastTriggerAt >= gap else { return }

        let level = intensity * (degraded ? 0.7 : 1)
        if newKicks {
            HapticFeedback.musicKick(intensity: level)
        } else {
            // snare 比 kick 更短更脆：同一档强度再压一点，否则听起来像两个底鼓。
            HapticFeedback.musicSnare(intensity: level * 0.8)
        }
        lastTriggerAt = now
        windowTriggers += 1
        if !didLogFirstTrigger {
            didLogFirstTrigger = true
            writeDebugLog(
                "[\(logTag)] first \(newKicks ? "kick" : "snare") tap — strength \(strength)"
                    + " low=\(String(format: "%.3f", snapshot.low))"
                    + " high=\(String(format: "%.3f", snapshot.high))"
                    + " rms=\(String(format: "%.3f", snapshot.rms))"
            )
        }
    }
}
