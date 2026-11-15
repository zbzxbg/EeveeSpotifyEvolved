import Foundation
import MediaPlayer
import UIKit

/// 听歌统计的录音器：1 秒一拍，把「真的在播的那些秒」记进本地统计。
///
/// ── 为什么是轮询
/// 换歌 / 暂停 / 拖动进度条这三件事在这套代码里没有一条统一的回调：它们各自散在不同的
/// hook 里，而且大多带着「只在某个功能开着时才装」的前提；新增 Orion hook 在注入进程里
/// 解析不到目标时有 SIGTRAP 的前科（见 `BlockedArtistSkip` 文件头的说明）。轮询只用已经
/// 验证可用的原语，1 秒读几个字段的代价可以忽略。
///
/// ── 为什么**没有**「熄屏就不跑」的 guard
/// Spotify 在后台照常放音频、进程也不会被挂起 —— 恰恰要在这时候继续记。暂停的影响由
/// `ListeningStatsPlaybackRules.tickCredit` 自己承担：`rate == 0` 的那一拍记 0 秒。
///
/// ── 线程
/// 定时器是私有队列上的 `DispatchSourceTimer`（主 run loop 的 `Timer` 在锁屏/后台会被
/// 合并、推迟，睡眠定时器那边踩过同一个坑）；每拍只把 `tick()` 投回主队列。
/// 所有会话状态只在主线程读写，磁盘那边是 `ListeningStatsStore` 自己的串行队列。
///
/// ── 不重复计数
/// 会话里记着「累计多少秒」和「已经落盘多少秒」，每次只把差值交给 store，交完立刻清空；
/// 被强杀时最多丢掉最后一段还没 flush 的尾巴（≤2 分钟）。
final class ListeningStatsRecorder {

    static let shared = ListeningStatsRecorder()

    /// 轮询间隔。
    private static let interval: TimeInterval = 1.0

    /// 攒够这么多秒就落一次盘。换歌 / 暂停 / 进后台仍会立即 flush，所以这个间隔只影响
    /// 「一首长歌/单曲循环一直不停」时的整份 JSON 重写频率；写盘次数少一半以上。
    private static let flushThreshold: Double = 120

    /// 一次会话最多为封面读几次 metadata（换歌瞬间常常还读不到）。
    private static let maxArtworkAttempts = 3

    private let store: ListeningStatsStore
    private let queue = DispatchQueue(label: "com.eevee.listening-stats.recorder", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var backgroundObserver: NSObjectProtocol?
    private var session: Session?
    private var didLogFirstTrack = false

    /// 一次曲目会话。`struct` + 主线程读写，避免闭包里抓着引用改状态。
    private struct Session {
        var trackID: String
        var title: String
        var artist: String
        var durationSeconds: Int
        var artworkURL: String?
        /// 封面取过几次。换歌那一拍 metadata 常常还没就绪，所以要允许隔几拍重试；
        /// 但最多 `maxArtworkAttempts` 次（它是主线程上的 metadata 读取，别每拍都做）。
        var artworkAttempts = 0

        var counter = ListeningStatsPlayCounter()

        /// 还没落盘的秒数 / 播放次数，按日桶分组（跨零点时一段会话会落到两个桶里）。
        var pendingSeconds: [String: Double] = [:]
        var pendingPlays: [String: Int] = [:]

        /// 已经落盘了多少秒（= `counter.seconds` 里那部分），用来判断 flush 的时机。
        var persistedSeconds: Double = 0

        /// 上一拍的播放位置与时刻；nil 表示「这一拍只记基准，不记秒」。
        var lastPosition: Double?
        var lastTickAt: Date?
    }

    private init(store: ListeningStatsStore = .shared) {
        self.store = store
    }

    // MARK: - 生命周期

    /// 装上定时器与后台通知。**幂等**：重复调用只有第一次生效。关着统计时不装定时器 ——
    /// 关闭状态下一拍都不跑，打开时再由 `settingsDidChange()` 调回来。
    func start() {
        // store 是 Foundation-only，够不到 `writeDebugLog`；在这里把日志出口接上。
        ListeningStatsLog.sink = { writeDebugLog($0) }

        guard timer == nil else { return }
        guard UserDefaults.listeningStatsEnabled else {
            writeDebugLog("[Stats] recorder idle — recording is off")
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.interval,
            repeating: Self.interval,
            leeway: .milliseconds(200)
        )
        timer.setEventHandler { [weak self] in
            // 备份导入 / 别处改键时定时器可能还在；开关关着就不要再投主队列。
            guard UserDefaults.listeningStatsEnabled else { return }
            guard let self else { return }
            DispatchQueue.main.async { self.tick() }
        }
        timer.resume()
        self.timer = timer

        observeBackground()

        writeDebugLog("[Stats] recorder started — polling every 1s (local only)")
    }

    /// 摘掉定时器，并把当前会话结算掉。
    func stop() {
        guard timer != nil else { return }

        if var current = session {
            flush(&current)
        }
        session = nil

        timer?.cancel()
        timer = nil

        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
        backgroundObserver = nil

        writeDebugLog("[Stats] recorder stopped")
    }

    /// 设置页拨完开关后调它：关掉时落盘、结束会话并摘掉定时器（真正零轮询），
    /// 重开时重新装定时器、从下一拍记位置基准（不会把关闭前那半首和重开后的秒数拼成一次播放）。
    func settingsDidChange() {
        if UserDefaults.listeningStatsEnabled {
            start()
            resetBaseline()
            writeDebugLog("[Stats] recording enabled")
        } else {
            stop()
            writeDebugLog("[Stats] recording disabled — existing data kept")
        }
    }

    /// 丢掉当前会话 —— **不落盘**。
    ///
    /// 给「清除统计数据」用：会话里还攒着一段没落盘（或已经排进 store 队列）的秒数，
    /// 只清文件的话，下一次 flush 会把刚清掉的那部分又带回来。丢掉会话之后，下一拍会在
    /// 当前位置重开一段新会话，清空之前的数据不会再出现。
    func discardCurrentSession() {
        session = nil
    }

    private func observeBackground() {
        guard backgroundObserver == nil else { return }

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            ListeningStatsRecorder.shared.flushForBackground()
        }
    }

    /// 进后台可能是进程被杀前的最后一个机会：把没落盘的那一段交出去。
    private func flushForBackground() {
        guard var current = session else { return }
        guard !current.pendingSeconds.isEmpty || !current.pendingPlays.isEmpty else { return }
        flush(&current)
        session = current
    }

    // MARK: - 每一拍

    private func tick() {
        // 开关是**实时读**的；关着就一眼都不看。
        guard UserDefaults.listeningStatsEnabled else { return }

        // 先看播放速率：暂停 / 没在播时，只把已有会话落盘并冻结位置基准，
        // 不去读当前曲目和 metadata —— 否则暂停浏览时也会每秒摸一次曲目元数据。
        let nowPlaying = MPNowPlayingInfoCenter.default().nowPlayingInfo
        let rate = Self.playbackRate(from: nowPlaying)
        if rate <= 0 {
            if var current = session {
                flush(&current)
                current.lastPosition = nil
                current.lastTickAt = nil
                session = current
            }
            return
        }

        let now = Date()
        let track = currentTrack()

        guard let info = makeTrackInfo(track: track, nowPlaying: nowPlaying) else {
            resetBaseline()
            return
        }

        // 换歌：先把旧会话结算掉，再给新会话记基准（这一拍不记秒）。
        if session?.trackID != info.trackID {
            finalizeSession()
            startSession(info, now: now)
            return
        }

        guard var current = session else {
            startSession(info, now: now)
            return
        }

        if current.artworkURL == nil,
           current.artworkAttempts < Self.maxArtworkAttempts,
           let track {
            current.artworkURL = LyricsArtworkResolver.artworkURL(for: track)?.absoluteString
            current.artworkAttempts += 1
        }

        let position = Self.playbackPosition(
            elapsed: nowPlaying?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber
        )

        if ListeningStatsPlaybackRules.isTrackRestart(position: position, lastPosition: current.lastPosition) {
            // 同一首从头又放了一遍 ⇒ 结算上一段、开新会话，循环播放才会再记一次播放。
            session = current
            finalizeSession()
            startSession(info, now: now)
            return
        }

        let wallSeconds = current.lastTickAt.map { now.timeIntervalSince($0) } ?? 0
        let credit = ListeningStatsPlaybackRules.tickCredit(
            rate: rate,
            position: position,
            lastPosition: current.lastPosition,
            wallSeconds: wallSeconds
        )

        current.lastTickAt = now
        if let position {
            current.lastPosition = position
        }

        if credit > 0 {
            let dayKey = ListeningStatsDayKey.key(for: now)
            let earnedPlay = current.counter.add(credit)
            current.pendingSeconds[dayKey, default: 0] += credit
            if earnedPlay {
                current.pendingPlays[dayKey, default: 0] += 1
            }
        }

        session = current

        if current.counter.seconds - current.persistedSeconds >= Self.flushThreshold {
            guard var flushing = session else { return }
            flush(&flushing)
            session = flushing
        }
    }

    // MARK: - 会话

    private func startSession(_ info: TrackInfo, now: Date) {
        var session = Session(
            trackID: info.trackID,
            title: info.title,
            artist: info.artist,
            durationSeconds: info.durationSeconds,
            artworkURL: nil
        )
        session.lastTickAt = now
        self.session = session

        if !didLogFirstTrack {
            didLogFirstTrack = true
            writeDebugLog("[Stats] first track seen — stats now start from here (nothing before this point exists)")
        }
    }

    /// 结算并丢掉当前会话；下一次换歌 / 重新播放会开一段新的。
    private func finalizeSession() {
        guard var current = session else { return }
        flush(&current)
        session = nil
    }

    /// 把「还没落盘的那一段」交给 store。调用方负责把 `session` 写回。
    private func flush(_ session: inout Session) {
        let dayKeys = Set(session.pendingSeconds.keys).union(session.pendingPlays.keys)
        guard !dayKeys.isEmpty else { return }

        var entries: [ListeningStatsEntry] = []
        entries.reserveCapacity(dayKeys.count)

        for dayKey in dayKeys {
            let seconds = session.pendingSeconds[dayKey] ?? 0
            let plays = session.pendingPlays[dayKey] ?? 0
            guard seconds > 0 || plays > 0 else { continue }

            entries.append(
                ListeningStatsEntry(
                    dayKey: dayKey,
                    trackID: session.trackID,
                    title: session.title,
                    artist: session.artist,
                    durationSeconds: session.durationSeconds,
                    artworkURL: session.artworkURL,
                    seconds: seconds,
                    plays: plays
                )
            )
        }

        // 先清空再交出去：交出去的那部分绝不会再交第二次。
        session.pendingSeconds.removeAll()
        session.pendingPlays.removeAll()
        session.persistedSeconds = session.counter.seconds

        guard !entries.isEmpty else { return }
        store.persist(entries)
    }

    private func resetBaseline() {
        guard var current = session else { return }
        current.lastPosition = nil
        current.lastTickAt = nil
        session = current
    }

    // MARK: - 播放器读数

    private func currentTrack() -> SPTPlayerTrack? {
        // 不开歌词时 `statefulPlayer` 可能抓不到，再退到播放页 view model 上那份。
        statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
    }

    private func makeTrackInfo(track: SPTPlayerTrack?, nowPlaying: [String: Any]?) -> TrackInfo? {
        // 曲目对象拿不到时，系统 Now Playing 里那几项通常还在，用它兜底。
        // 注意不能只靠 `??`：有些构建的 getter **在 metadata 没就绪时返回空串而不是 nil**，
        // 所以逐项挑第一个非空值。
        let title = Self.firstNonEmpty(
            track?.string(ifResponding: "trackTitle"),
            nowPlaying?[MPMediaItemPropertyTitle] as? String
        )
        let artist = Self.firstNonEmpty(
            track?.string(ifResponding: "artistName"),
            track?.string(ifResponding: "artistTitle"),
            nowPlaying?[MPMediaItemPropertyArtist] as? String
        )

        var durationSeconds = 0
        if let milliseconds = track?.trackDurationMilliseconds, milliseconds > 0 {
            durationSeconds = milliseconds / 1000
        } else if let seconds = nowPlaying?[MPMediaItemPropertyPlaybackDuration] as? NSNumber,
                  seconds.doubleValue > 0 {
            durationSeconds = Int(seconds.doubleValue.rounded())
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)

        let trackIdentifier = track?.trackIdentifier ?? ""
        let trackID = ListeningStatsTrackKey.identifier(
            trackID: trackIdentifier,
            title: trimmedTitle,
            artist: trimmedArtist,
            durationSeconds: durationSeconds
        )

        return TrackInfo(
            trackID: trackID,
            title: trimmedTitle,
            artist: trimmedArtist,
            durationSeconds: durationSeconds
        )
    }

    /// 逐个挑第一个非空字符串（空串也当作「没拿到」）。
    private static func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            guard let value else { continue }
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return ""
    }

    private static func playbackRate(from info: [String: Any]?) -> Double {
        if let rate = info?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber {
            return rate.doubleValue
        }

        // 读不到 rate 时才看系统状态；两样都读不到按「没在播」处理 —— 宁可少记，
        // 也不要把暂停算成在听。
        switch MPNowPlayingInfoCenter.default().playbackState {
        case .playing: return 1
        case .paused, .stopped: return 0
        default: return 0
        }
    }

    private static func playbackPosition(elapsed: NSNumber?) -> Double? {
        if let value = elapsed?.doubleValue, value > 0 {
            return value
        }
        if let resolved = WordByWordPositionResolver.shared.currentPositionSeconds(), resolved >= 0 {
            return resolved
        }
        return elapsed?.doubleValue
    }

    /// 当前曲目的最小画像（换歌判定与落盘都用它）。
    private struct TrackInfo {
        let trackID: String
        let title: String
        let artist: String
        let durationSeconds: Int
    }
}
