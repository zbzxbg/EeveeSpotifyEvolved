import Foundation
import MediaPlayer
import UIKit

/// 睡眠定时器：到点把正在播的歌暂停。
///
/// 为什么不用 `Timer`：锁屏/后台时主 run loop 的定时器会被系统合并、推迟（锁屏歌词那边
/// 踩过同一个坑），这里用 GCD 的 `DispatchSourceTimer`，而且只认**绝对截止时间** ——
/// 就算被合并几拍，算出来的剩余时间仍然是对的。
///
/// 与 Spotify 自带的睡眠定时器（`ios-feature-sleeptimer`，播客/⋯ 菜单里那份）互不干扰：
/// 它管它自己的，我们只在到点时调一次暂停，而且只在真的在播时调。
final class SleepTimerController {

    static let shared = SleepTimerController()

    /// 可选时长（分钟）。留 1 分钟那档：只想听完手上这首的时候，它比 15 分钟好用。
    static let presetMinutes = [1, 5, 10, 15, 30, 45, 60, 90]

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.eevee.sleep-timer", qos: .utility)
    private var source: DispatchSourceTimer?
    private var deadline: Date?
    /// 每次 start/cancel 都换一个新的。旧定时器冒出来的那一拍直接丢掉 —— 否则刚重开
    /// 定时器，就可能被上一只定时器的收尾逻辑取消掉。
    private var generation: UInt64 = 0

    private init() {}

    /// 剩余秒数；没有在跑时返回 nil。
    var remaining: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let deadline else { return nil }
        return max(deadline.timeIntervalSinceNow, 0)
    }

    var isRunning: Bool { remaining != nil }

    func start(minutes: Int) {
        guard minutes > 0 else { return }

        lock.lock()
        let previous = source
        generation &+= 1
        let token = generation
        deadline = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        source = timer
        lock.unlock()
        previous?.cancel()

        // 0.5 秒一拍：到点误差不会超过半秒，而每拍只读一个时间差，开销可以忽略。
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.tick(token: token) }
        timer.resume()

        writeDebugLog("[SleepTimer] started — \(minutes) min")
    }

    func cancel() {
        lock.lock()
        let previous = source
        source = nil
        deadline = nil
        generation &+= 1
        lock.unlock()
        previous?.cancel()
        writeDebugLog("[SleepTimer] canceled")
    }

    private func tick(token: UInt64) {
        lock.lock()
        guard token == generation, let deadline else {
            lock.unlock()
            return
        }
        let left = deadline.timeIntervalSinceNow
        lock.unlock()
        guard left <= 0 else { return }

        lock.lock()
        guard token == generation else {
            lock.unlock()
            return
        }
        let previous = source
        source = nil
        self.deadline = nil
        generation &+= 1
        lock.unlock()
        previous?.cancel()

        writeDebugLog("[SleepTimer] expired — pausing")
        DispatchQueue.main.async { SleepTimerController.pauseIfPlaying() }
    }

    /// 只在真的在播时暂停。
    ///
    /// 到点时用户可能已经自己按了暂停；那种情况下再"切换一次"会把歌**放起来** ——
    /// 这是这个功能最容易写错的地方，所以先读播放速率再决定。
    static func pauseIfPlaying() {
        let rate = (
            MPNowPlayingInfoCenter.default()
                .nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber
        )?.doubleValue ?? 0
        guard rate > 0 else {
            writeDebugLog("[SleepTimer] already paused — nothing to do")
            return
        }

        if let player = statefulPlayer as? NSObject,
           player.responds(to: Selector("pause")) {
            _ = player.perform(Selector("pause"))
            writeDebugLog("[SleepTimer] paused via statefulPlayer.pause()")
            return
        }
        if WordByWordPlaybackControl.togglePlayPause() {
            writeDebugLog("[SleepTimer] paused via native play button")
        }
    }
}
