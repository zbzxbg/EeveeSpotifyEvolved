import ActivityKit
import Foundation
import MediaPlayer

/// 锁屏 / 灵动岛的「实时活动」—— **App 侧的那一半**：什么时候有卡、卡上写什么、什么时候收。
///
/// 卡片长什么样在 WidgetKit 扩展里（`Scripts/build-live-activity-appex.sh` 也编
/// `NowPlayingActivityAttributes.swift`）。两份代码之间只有那一个结构体的契约，
/// 这里只构造 `ContentState`，一个字段都不多写。
///
/// 为什么数据源是 `MPNowPlayingInfoCenter` 而不是 Spotify 自己的播放对象：
/// now-playing 是**系统**的状态，Spotify 每次换歌 / 播放暂停都会往那份字典里写一次
/// （`NowPlayingArtworkInjector.x.swift` 就是在同一个 setter 上搭的），键名全是公开 API。
/// 绕过它去摸 Spotify 的私有播放模型，等于把"换一版就崩"请进来。
///
/// 为什么是 2 秒轮询，而不是 hook 那个 setter：
/// 轮询只读一份字典，两秒一次的开销可以忽略；hook 则要我们站进 Spotify 写状态的路径，
/// 那条路径上有同步观察者，多一个回调就多一处和它抢时序的机会。
///
/// 更新频率的纪律（ActivityKit 对 `update` 有预算）：
/// · 只在**换歌**与**播放 / 暂停**时更新一次；
/// · 进度条不更新 —— 卡片里的 `Text(timerInterval:)` 自己会走（见 attributes 文件头）。
///
/// 线程：所有状态只在**主队列**上读写（轮询定时器挂在主队列，开关来自设置页也是主线程）。
enum LiveActivityController {

    private static let tag = "LiveActivity"

    /// 轮询间隔。够跟住换歌与播放暂停，又不让主线程有任何可感知的负担。
    private static let pollInterval: TimeInterval = 2

    /// 「没有曲目」要持续多久才收卡。Spotify 换歌、切播客、重建播放器时会短暂清空那份
    /// 字典，立刻收卡会让卡片闪一下。
    private static let idleGrace: TimeInterval = 30

    /// 申请失败之后隔多久再试。拒绝对我们来说是不可恢复的（额度用完 / 系统里关掉了本 App
    /// 的实时活动 / 扩展没签上），每两秒重试一次只会把同一行写满。
    private static let requestRetryDelay: TimeInterval = 60

    private static var poller: DispatchSourceTimer?
    private static var card: Activity<NowPlayingActivityAttributes>?
    /// 上一拍卡上写的"曲目 + 在不在播"。相同就不必再 `update`。
    private static var lastSignature = ""
    /// 上一个真正打过 payload 的曲目（换歌才打一行，同一首只打一次）。
    private static var lastTrackId = ""
    /// `nowPlayingInfo` 从什么时候开始没有曲目（nil = 有）。
    private static var idleSince: Date?
    /// 申请失败之后的冷却截止时刻（见 `requestRetryDelay`）。
    private static var nextRequestAttemptAt: Date?
    /// 系统不允许实时活动时只打一行。
    private static var notedUnsupported = false

    // MARK: - 开关

    /// 开关的唯一入口：启动时（`EeveeSpotify.init`）与设置页拨完开关都调它。幂等。
    static func syncWithSettings() {
        guard UserDefaults.liveActivityEnabled else {
            stop()
            return
        }

        // 用户在 iOS 设置里关掉了「实时活动」：开关留着（下次开系统设置就接着用），
        // 但这里一行都不做。
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            noteUnsupportedOnce()
            return
        }

        startPolling()
        // 拨开关的那一刻就对一次，不必等第一拍 —— 卡片与当前曲目同步出现。
        if Thread.isMainThread {
            pollNowPlaying()
        } else {
            DispatchQueue.main.async { pollNowPlaying() }
        }
    }

    /// 收尾：停轮询、结束卡片。开关关掉、「重置本页」都走这里。
    static func stop() {
        stopPolling()
        idleSince = nil
        nextRequestAttemptAt = nil
        endCard(reason: "switch is off")
    }

    // MARK: - 轮询

    private static func startPolling() {
        guard poller == nil else { return }

        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(
            deadline: .now() + pollInterval,
            repeating: pollInterval,
            leeway: .milliseconds(200)
        )
        source.setEventHandler { pollNowPlaying() }
        source.resume()
        poller = source
    }

    private static func stopPolling() {
        poller?.cancel()
        poller = nil
    }

    /// 一拍：读 now-playing → 决定"不动 / 更新 / 申请 / 收卡"。
    private static func pollNowPlaying() {
        // 开关在别处被改过（备份导入、重置）时，这一拍就是收尾的那一拍。
        guard UserDefaults.liveActivityEnabled else {
            stop()
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            noteUnsupportedOnce()
            stopPolling()
            return
        }

        guard let snapshot = currentSnapshot() else {
            noteIdle()
            return
        }
        idleSince = nil

        let wanted = signature(of: snapshot)
        let content = ActivityContent(state: snapshot.state, staleDate: nil)

        if let live = reusableCard() {
            // 同一首、同一个播放状态：卡片上的东西一点没变，不花 ActivityKit 的更新预算。
            guard wanted != lastSignature else { return }
            lastSignature = wanted
            notePayloadIfTrackChanged(snapshot)
            Task { await live.update(content, alertConfiguration: nil) }
            return
        }

        // 手上没有卡片：向系统申请一张。失败过就在冷却里等着（见 `requestRetryDelay`）。
        if let next = nextRequestAttemptAt, next > Date() {
            return
        }
        requestCard(snapshot: snapshot, content: content, wanted: wanted)
    }

    /// 「没有曲目」那一拍：等够 `idleGrace` 才收卡。
    private static func noteIdle() {
        let since = idleSince ?? Date()
        idleSince = since
        guard Date().timeIntervalSince(since) >= idleGrace else { return }
        endCard(reason: "nothing is playing")
    }

    // MARK: - 卡片的生命周期

    /// 当前那张卡。**一个 App 同时只能有一张**：内存里那份优先；进程重启之后（内存里那份
    /// 没了）从 `activities` 里认领回同一张 —— 绝不申请第二张。
    private static func reusableCard() -> Activity<NowPlayingActivityAttributes>? {
        if let card, isLive(card) {
            return card
        }
        card = nil

        guard let existing = Activity<NowPlayingActivityAttributes>.activities.first(where: {
            isLive($0)
        }) else {
            return nil
        }
        card = existing
        return existing
    }

    /// `activityState` 是系统那边的**真**状态：用户把卡片划掉之后，内存里那份实例还在，
    /// 但已经不能再用（`update` 不会再落到屏幕上），必须重新申请一张。
    private static func isLive(_ item: Activity<NowPlayingActivityAttributes>) -> Bool {
        if case .active = item.activityState { return true }
        return false
    }

    private static func requestCard(
        snapshot: NowPlayingSnapshot,
        content: ActivityContent<NowPlayingActivityAttributes.ContentState>,
        wanted: String
    ) {
        let attributes = NowPlayingActivityAttributes(trackId: snapshot.trackId)
        do {
            card = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            lastSignature = wanted
            nextRequestAttemptAt = nil
            notePayloadIfTrackChanged(snapshot)
            writeDebugLog("[\(tag)] started a card — lock screen and Dynamic Island")
        } catch {
            // 申请会被系统拒绝：额度用完、用户在设置里关掉了本 App 的实时活动、或者随包打进
            // IPA 的 widget 扩展没被签名。哪一种都不该影响播放。
            nextRequestAttemptAt = Date().addingTimeInterval(requestRetryDelay)
            writeDebugLog("[\(tag)] request rejected — \(error)")
        }
    }

    /// 结束所有活动实例（正常只有一张）+ 把"卡上写了什么"的记忆清掉，
    /// 这样下次开开关时不会因为签名没变而漏掉第一拍。
    private static func endCard(reason: String) {
        let live = Activity<NowPlayingActivityAttributes>.activities
        card = nil
        lastSignature = ""
        lastTrackId = ""

        guard !live.isEmpty else { return }
        Task {
            for item in live {
                await item.end(nil, dismissalPolicy: .immediate)
            }
            writeDebugLog("[\(tag)] ended the card — \(reason)")
        }
    }

    // MARK: - now-playing 快照

    /// 一拍快照：只挑"画一张卡"需要的字段。`trackId` 只用来判断"是不是换歌"。
    private struct NowPlayingSnapshot {

        let trackId: String
        let title: String
        let artist: String
        let isPlaying: Bool
        /// 这一首的起始时刻（`now - elapsed`）。暂停时也留着，恢复播放时重算。
        let startedAt: Date
        /// 总时长（秒）。0 = 未知，卡片就只画一个静止的进度点。
        let duration: Double

        var state: NowPlayingActivityAttributes.ContentState {
            NowPlayingActivityAttributes.ContentState(
                title: title,
                artist: artist,
                isPlaying: isPlaying,
                startedAt: startedAt,
                duration: duration
            )
        }
    }

    /// 读一拍的 now-playing。没有曲目（字典为空 / 没有标题）时返回 nil —— 播客广告、
    /// 页面还没起播这类空字典都落在这里。
    private static func currentSnapshot() -> NowPlayingSnapshot? {
        guard let info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return nil }
        guard let title = info[MPMediaItemPropertyTitle] as? String, !title.isEmpty else {
            return nil
        }

        let artist = info[MPMediaItemPropertyArtist] as? String ?? ""
        let duration = (info[MPMediaItemPropertyPlaybackDuration] as? NSNumber)?.doubleValue ?? 0

        // 播放位置只在这一刻读一次：之后进度条靠 `startedAt + duration` 自己走。
        // 缺这一键时按 0 算 —— 卡片上就是"刚从开头开始"。
        let elapsed = (info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber)?.doubleValue ?? 0

        // 速率是"在不在播"的唯一判据（0 = 暂停，1 = 播放）。缺这一键时按在播算：
        // Spotify 每条 now-playing 都带它，缺了多半是刚切歌、进度仍在走。
        let rate = (info[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue
        let isPlaying = (rate ?? 1) > 0.5

        return NowPlayingSnapshot(
            trackId: trackIdentity(info: info, title: title, artist: artist, duration: duration),
            title: title,
            artist: artist,
            isPlaying: isPlaying,
            startedAt: Date(timeIntervalSinceNow: -max(0, elapsed)),
            duration: max(0, duration)
        )
    }

    /// 曲目身份：从"最具体"退到"最笼统"，第一个有值的就用作 `trackId`
    /// （它只进卡片上的那个字段，不参与渲染）：
    ///
    /// 1. 外部内容标识 —— Spotify 放曲目 URI 的那一格；同一首换了播放位置也是同一个值；
    /// 2. 媒体项的持久 id —— 本地曲库里的那一串数字；
    /// 3. 标题 + 艺人 + 时长 —— 前两格都没有时的兜底（同一专辑里同名同长的两首会撞上，
    ///    代价只是"卡片不重画一次"）。
    private static func trackIdentity(
        info: [String: Any],
        title: String,
        artist: String,
        duration: Double
    ) -> String {
        if let external = info[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String,
           !external.isEmpty {
            return "ext:\(external)"
        }
        if let persistent = info[MPMediaItemPropertyPersistentID] as? NSNumber {
            return "id:\(persistent.uint64Value)"
        }
        return "meta:\(title)|\(artist)|\(Int(duration))"
    }

    private static func signature(of snapshot: NowPlayingSnapshot) -> String {
        let playState = snapshot.isPlaying ? "1" : "0"
        return "\(snapshot.trackId)#\(playState)"
    }

    // MARK: - 日志

    /// 换歌时打一行 payload：卡片上写什么、判成在播还是暂停。同一首只打一次。
    private static func notePayloadIfTrackChanged(_ snapshot: NowPlayingSnapshot) {
        guard snapshot.trackId != lastTrackId else { return }
        lastTrackId = snapshot.trackId

        let playState = snapshot.isPlaying ? "playing" : "paused"
        writeDebugLog(
            "[\(tag)] payload — \"\(snapshot.title)\" / \"\(snapshot.artist)\","
                + " \(playState), duration \(Int(snapshot.duration))s"
        )
    }

    private static func noteUnsupportedOnce() {
        guard !notedUnsupported else { return }
        notedUnsupported = true
        writeDebugLog("[\(tag)] the system does not allow Live Activities — nothing is requested")
    }
}
