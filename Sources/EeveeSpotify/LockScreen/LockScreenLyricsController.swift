import Foundation
import MediaPlayer
import UIKit

/// 锁屏歌词的调度器。
///
/// Spotify 只在**它自己**写 now-playing 的时刻经过我们的 hook，而歌词要跟着播放进度换行，
/// 所以这里自己起一个 0.25 秒的 GCD 定时器。为什么不用 `Timer`：主 run loop 的定时器在
/// 锁屏之后会被系统节流，歌词会站着不动；GCD 定时器不经过 run loop。
///
/// 每一拍只做一件事：按 now-playing 里的 `elapsedPlaybackTime + rate × Δ` 算出现在唱到
/// 哪一行。行变了就换这一段片子的 `artworkID`、把新的 `MPMediaItemAnimatedArtwork` 交给
/// 注入器重写一次 now-playing。系统拿 ID 判断素材新旧，所以"换行"必须换 ID，**不能**改文件。
final class LockScreenLyricsController {

    static let shared = LockScreenLyricsController()

    private init() {}

    private let lock = NSLock()

    // MARK: - 共享状态（注入器在任意线程读，主线程写）

    private var info: [String: Any]?
    private var infoAt: CFAbsoluteTime = 0

    private var cover: CGImage?
    private var coverTrackKey = ""

    private var trackKey = ""
    private var trackId = ""
    private var lines: [LockScreenLyricLine] = []
    /// 这一份词是谁给的（画到底沿的小字）。空字符串 = 不画。
    private var credit = ""
    private var linesFetched = false
    /// 正在取词（或正在等播放器对象出现）。避免同一首每拍都重来一遍。
    private var fetchInFlight = false
    /// 冷启动时 `statefulPlayer` 可能比第一次 now-playing 写入晚几秒才出现；
    /// 这段时间里"没有曲目对象"不等于"这首没词"，要给到一次重试的机会。
    private var playerRetryDeadline: CFAbsoluteTime = 0
    private var nextPlayerRetryAt: CFAbsoluteTime = 0
    /// 已经在"等播放器"上放弃过一次：此后按慢节奏继续试（不占定时器预算）。
    private var waitingForPlayer = false
    private var generation: UInt64 = 0
    private var loggedNoLyricsFor = ""
    /// 页内那份 dto 往往比锁屏这次取词晚到（自动优选要跑完整条链），而词级时间轴
    /// 只有它可能带来。这个标记保证同一首只尝试转换一次：对不上行文本的词每拍重算
    /// 没有意义（真的换上之后 `lines` 里就有帧，判据自己会停）。
    private var upgradeAttempted = false

    /// 这一行要装的 artwork，按 now-playing 键（1x1 / 3x4）存。
    /// 注入器只负责把它和现有字典比对后写回去。
    private var prepared: [String: Any] = [:]
    private var preparedLineKey = ""
    /// prepared 属于哪一首。切歌的那一瞬间 Spotify 可能先写新歌的字典、
    /// 定时器还没跑到 —— 不比对就会把上一首的歌词装到新歌上。
    private var preparedTrackKey = ""

    private let previews = NSCache<NSString, UIImage>()
    private var clipTasks: [String: Task<URL?, Never>] = [:]

    // MARK: - 主线程状态

    private var timer: DispatchSourceTimer?
    private var lastEnabled = false
    /// 有东西装着（行/artwork 或定时器）。注入器在开关关着时每写一次 now-playing 都会
    /// 调 `noteDisabled()`；靠它把"其实已经什么都不做"的那种调用挡在外面。
    private var active = false
    private var lastTickAt: CFAbsoluteTime = 0
    private var lateTickLogs = 0

    // MARK: - 生命周期

    func activate() {
        guard #available(iOS 26.0, *) else {
            writeDebugLog("[\(LockScreenLyrics.logTag)] skipped — lock screen artwork needs iOS 26")
            return
        }
        guard NSClassFromString("MPMediaItemAnimatedArtwork") != nil else {
            writeDebugLog("[\(LockScreenLyrics.logTag)] skipped — MPMediaItemAnimatedArtwork not found")
            return
        }
        previews.countLimit = 8
        lastEnabled = LockScreenLyrics.isEnabled
        // 这里**不注册 `UserDefaults.didChangeNotification` 观察者**：Spotify 写默认值的
        // 频率很高，每条通知都跑一次我们的回调（再读一次默认值）没有必要，也不会让开关
        // 变化更及时 —— 下一次 now-playing 写入（`inject`）本来就会重读开关。设置页的
        // 开关直接调 `settingsDidChange()`。
        writeDebugLog(
            "[\(LockScreenLyrics.logTag)] ready —"
                + " lock screen lyrics \(lastEnabled ? "on" : "off")"
        )
    }

    /// 设置页的开关调用。不开观察者，所以由 UI 主动通知。
    func settingsDidChange() {
        let enabled = LockScreenLyrics.isEnabled
        guard enabled != lastEnabled else { return }
        lastEnabled = enabled

        if enabled {
            writeDebugLog("[\(LockScreenLyrics.logTag)] switched on")
            refreshTimer()
            // 刚打开时可能已经播了一会儿：让注入器按 Spotify 最近一次写的字典补一次，
            // 时钟才会从现在开始走（否则要等它下一次自己写 now-playing）。
            if #available(iOS 26.0, *) {
                LockScreenArtworkInjector.republishForLockScreen()
            }
        } else {
            writeDebugLog("[\(LockScreenLyrics.logTag)] switched off")
            noteDisabled(force: true)
        }
    }

    /// 「歌词 → 文字」的两档倍率变了。
    ///
    /// 盘上那些片段不用删：倍率进了 `frameHash`（见 `LockScreenLyrics.frameHash`），
    /// 新值自然落到新文件。要清的是**当前这一行已经装好**的那份 —— `tick()` 的判据是
    /// `preparedLineKey == lineKey`，不清掉的话锁屏会一直显示旧字号，直到下一句。
    ///
    /// 只清 `preparedLineKey`、不清 `prepared`：后者是系统正在取的那份素材，
    /// 清掉会让锁屏在重渲完之前短暂变回官方封面。
    func typographyDidChange() {
        guard LockScreenLyrics.isEnabled else { return }
        lock.lock()
        preparedLineKey = ""
        lock.unlock()
        refreshTimer()
        writeDebugLog("[\(LockScreenLyrics.logTag)] typography changed — rebuilding the current line")
    }

    /// 注入器发现开关关着时调用（每次 now-playing 写入都会走）。只在真的有东西装着时
    /// 收尾一次：停表、清状态、重写一次 now-playing 把我们的键撤掉。
    func noteDisabled(force: Bool = false) {
        lock.lock()
        let wasActive = force || active || !prepared.isEmpty
        active = false
        prepared = [:]
        preparedLineKey = ""
        preparedTrackKey = ""
        lock.unlock()
        guard wasActive else { return }

        onMain { [weak self] in
            guard let self else { return }
            self.lastEnabled = false
            self.stopTimer()
            self.reset()
            if #available(iOS 26.0, *) {
                LockScreenArtworkInjector.republishForLockScreen()
            }
        }
    }

    // MARK: - 注入器的入口

    /// Spotify 每写一次 now-playing 都会经过这里。只记快照与"该不该跑"，真正算行在定时器里。
    func noteNowPlaying(_ info: [String: Any]) {
        guard #available(iOS 26.0, *) else { return }
        guard LockScreenLyrics.isEnabled else { return }

        lock.lock()
        self.info = info
        self.infoAt = CFAbsoluteTimeGetCurrent()
        active = true
        lock.unlock()

        onMain { [weak self] in self?.refreshTimer() }
    }

    /// 封面静帧（注入器已经从系统字典或元数据里拿到了）。第一行的预览/短片用它铺底。
    func noteCover(_ image: UIImage, trackKey: String) {
        guard let cgImage = image.cgImage else { return }
        lock.lock()
        if coverTrackKey == trackKey, cover != nil {
            lock.unlock()
            return
        }
        cover = cgImage
        coverTrackKey = trackKey
        lock.unlock()
    }

    /// 当前这一行要装的 artwork（可能为空：还没取到词 / 这一首没词 / 已经换歌了）。
    func preparedArtwork(trackKey: String) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        guard preparedTrackKey == trackKey else { return [:] }
        return prepared
    }

    // MARK: - 定时器

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func refreshTimer() {
        guard LockScreenLyrics.isEnabled else {
            stopTimer()
            return
        }
        if currentRate() > 0 {
            startTimer()
        } else {
            stopTimer()
        }
    }

    private func currentRate() -> Double {
        lock.lock()
        let info = self.info
        lock.unlock()
        guard let info else { return 0 }
        return (info[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue ?? 1
    }

    private func startTimer() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        // 250ms：换行感知的上限。leeway 压小 —— 锁屏时系统会合并定时器，
        // 合并得太狠会让两句之间明显慢半拍。
        source.schedule(
            deadline: .now() + .milliseconds(250),
            repeating: .milliseconds(250),
            leeway: .milliseconds(50)
        )
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    private func stopTimer() {
        guard let timer else { return }
        timer.cancel()
        self.timer = nil
    }

    // MARK: - 每一拍

    private func tick() {
        guard #available(iOS 26.0, *) else { return }
        guard LockScreenLyrics.isEnabled else {
            stopTimer()
            return
        }

        // 锁屏之后定时器可能被系统合并/推迟。真的被压住过就记一行（最多五次），
        // 否则"歌词半拍不跟"在日志里没有任何痕迹。
        let now = CFAbsoluteTimeGetCurrent()
        if lastTickAt > 0, now - lastTickAt > 2, lateTickLogs < 5 {
            lateTickLogs += 1
            writeDebugLog(
                "[\(LockScreenLyrics.logTag)] ticked \(String(format: "%.1f", now - lastTickAt))s late"
            )
        }
        lastTickAt = now

        lock.lock()
        let info = self.info
        let at = self.infoAt
        lock.unlock()

        guard let info,
              let reported = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber,
              let title = info[MPMediaItemPropertyTitle] as? String,
              !title.isEmpty else {
            return
        }
        let rate = (info[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue ?? 1
        guard rate > 0 else {
            // 暂停：锁屏停在最后那一行，不起新素材。
            stopTimer()
            return
        }

        let elapsed = reported.doubleValue + rate * (CFAbsoluteTimeGetCurrent() - at)
        let artist = info[MPMediaItemPropertyArtist] as? String ?? ""
        let duration = (info[MPMediaItemPropertyPlaybackDuration] as? NSNumber)?.doubleValue ?? 0
        let key = LockScreenLyrics.trackKey(title: title, artist: artist, duration: duration)

        lock.lock()
        let changed = key != trackKey
        lock.unlock()

        if changed {
            // 封面不在主线程上取（`MPMediaItemArtwork.image(at:)` 会同步回调
            // Spotify 的 provider）。注入器那边会用异步抓到的静帧补上。
            beginTrack(key: key, title: title)
        }

        var ready = false
        var currentLines: [LockScreenLyricLine] = []
        var shouldRetry = false
        var waitingForPlayerRetry = false
        lock.lock()
        ready = linesFetched
        currentLines = lines
        if !ready, !fetchInFlight, trackKey == key {
            // 冷启动：第一次写入可能比 `statefulPlayer` 早到。等一秒再试，15 秒后放弃。
            shouldRetry = now >= nextPlayerRetryAt
        } else if ready, currentLines.isEmpty, waitingForPlayer, now >= nextPlayerRetryAt {
            // 放弃之后按 5 秒的慢节奏继续看播放器对象出现没有 —— 那一首不该永久没词。
            waitingForPlayerRetry = true
            nextPlayerRetryAt = now + 5
            playerRetryDeadline = now + 15
        }
        lock.unlock()

        if shouldRetry || waitingForPlayerRetry {
            beginTrack(key: key, title: title)
            lock.lock()
            ready = linesFetched
            currentLines = lines
            lock.unlock()
        }

        guard ready, !currentLines.isEmpty else { return }

        // 页内那份 dto 可能这时才落地，而且只有它可能带词级时间轴。转换放后台队列，
        // 成功时清掉 `preparedLineKey`，下一拍按新帧表重装当前行（见 `finishUpgrade`）。
        upgradeLinesFromLoadedDto(replacing: currentLines, key: key)

        let positionMs = Int((elapsed * 1000).rounded())
        guard let location = Self.locate(in: currentLines, positionMs: positionMs) else { return }
        let lineKey = Self.lineKey(for: location)

        lock.lock()
        let shown = preparedLineKey
        lock.unlock()
        guard shown != lineKey else { return }

        install(
            lineKey: lineKey,
            location: location,
            lines: currentLines,
            trackKey: key
        )
        refreshTimer()
    }

    @discardableResult
    private func beginTrack(key: String, title: String) -> Bool {
        lock.lock()
        let isNewTrack = trackKey != key
        if isNewTrack {
            playerRetryDeadline = CFAbsoluteTimeGetCurrent() + 15
        }
        trackKey = key
        trackId = ""
        lines = []
        credit = ""
        linesFetched = false
        upgradeAttempted = false
        fetchInFlight = true
        waitingForPlayer = false
        prepared = [:]
        preparedLineKey = ""
        preparedTrackKey = ""
        // 上一首的封面不能给这一首当模糊底。若本轮已经从新字典里抓到封面
        // （`noteCover` 按 trackKey 存的），比对一下就知道该不该留。
        if coverTrackKey != key {
            cover = nil
            coverTrackKey = ""
        }
        generation &+= 1
        let stamp = generation
        let retryDeadline = playerRetryDeadline
        lock.unlock()

        if isNewTrack {
            previews.removeAllObjects()
            LockScreenLyrics.trimCache(keeping: key)
            writeDebugLog("[\(LockScreenLyrics.logTag)] track \"\(title)\"")
        }

        guard let track = currentTrack(matching: title) else {
            let now = CFAbsoluteTimeGetCurrent()
            let gaveUp = now > retryDeadline
            lock.lock()
            if stamp == generation {
                fetchInFlight = false
                if gaveUp {
                    linesFetched = true
                    waitingForPlayer = true
                    nextPlayerRetryAt = now + 5
                } else {
                    nextPlayerRetryAt = now + 1
                }
            }
            lock.unlock()
            if gaveUp {
                writeDebugLog(
                    "[\(LockScreenLyrics.logTag)] no player track for this title — no lyrics to draw"
                )
            }
            return false
        }
        let identifier = track.trackIdentifier
        lock.lock()
        if stamp == generation { trackId = identifier }
        lock.unlock()

        // 这一首的词如果已经在内存里（歌词页加载过），直接转，不发网络请求。
        if let dto = loadedLyrics(for: identifier),
           let converted = LockScreenLyricsFetcher.convert(dto, source: currentLyricsSource) {
            let source = dto.providerName.isEmpty
                ? (currentLyricsSource?.description ?? "")
                : dto.providerName
            lock.lock()
            if stamp == generation {
                lines = converted
                credit = source
                linesFetched = true
                fetchInFlight = false
            }
            lock.unlock()
            writeDebugLog(
                "[\(LockScreenLyrics.logTag)] \(converted.count) line(s) already loaded"
                    + LockScreenLyricsFetcher.coverageLogSuffix(for: converted)
            )
            return true
        }

        let query = makeQuery(track: track)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = LockScreenLyricsFetcher.lines(
                for: query,
                trackId: identifier,
                deadline: Date().addingTimeInterval(20),
                onFallback: { [weak self] partial in
                    // 仍在取词队列上：只把兜底交给主线程装上去，最终结果由
                    // `finishFetch` 再收口（逐字档会整体替换）。
                    DispatchQueue.main.async {
                        self?.applyFetchedFallback(
                            stamp: stamp,
                            key: key,
                            identifier: identifier,
                            result: partial
                        )
                    }
                }
            )
            DispatchQueue.main.async {
                self?.finishFetch(stamp: stamp, key: key, identifier: identifier, result: result)
            }
        }
        return false
    }

    /// 取词这一跳先交出来的**行级兜底**（逐字那一档还在后面几个源里找）。
    ///
    /// 锁屏要尽快有字：同步取词整条链能跑好几秒，等升级完成再交就等于每首歌开头
    /// 空白这么久。这里先把兜底装上；`finishFetch` 拿到逐字那一份时再整体替换。
    private func applyFetchedFallback(
        stamp: UInt64,
        key: String,
        identifier: String,
        result: LockScreenLyricsFetcher.Result
    ) {
        lock.lock()
        guard stamp == generation, trackKey == key, trackId == identifier,
              result.lines != lines else {
            lock.unlock()
            return
        }
        lines = result.lines
        credit = result.source.description
        linesFetched = true
        // `fetchInFlight` 保持 true：词级那一跳还没回来。
        lock.unlock()

        writeDebugLog(
            "[\(LockScreenLyrics.logTag)] \(result.lines.count) line(s) ready"
                + LockScreenLyricsFetcher.coverageLogSuffix(for: result.lines)
                + " — line-timed fallback shown, still looking for word-by-word"
        )
        tick()
    }

    private func finishFetch(
        stamp: UInt64,
        key: String,
        identifier: String,
        result: LockScreenLyricsFetcher.Result?
    ) {
        lock.lock()
        guard stamp == generation, trackKey == key, trackId == identifier else {
            lock.unlock()
            return
        }
        // 兜底已经装上了（`applyFetchedFallback`）：这一跳若没升级就把原样留着 ——
        // `result` 为 nil 只可能是"一个源都没答上来"，那时也不该把已经显示的词抽掉。
        let previous = lines
        if let result {
            // 这一跳是**行级兜底**、而手里已经是页内 dto 升级来的逐字行时不能往回退。
            let previousHadKaraoke = previous.contains { !$0.karaoke.isEmpty }
            let incomingHasKaraoke = result.lines.contains { !$0.karaoke.isEmpty }
            if !(previousHadKaraoke && !incomingHasKaraoke) {
                lines = result.lines
                credit = result.source.description
            }
        }
        // 换成另一份（逐字升级 / 换源 / 行数变化）⇒ 当前这一行已经装出去的素材作废，
        // 下一拍按新帧表重装（`tick` 的判据只有行号，不比对内容）。
        if lines != previous {
            preparedLineKey = ""
        }
        linesFetched = true
        fetchInFlight = false
        waitingForPlayer = false
        let count = lines.count
        let coverage = LockScreenLyricsFetcher.coverageLogSuffix(for: lines)
        lock.unlock()

        if count == 0 {
            if loggedNoLyricsFor != key {
                loggedNoLyricsFor = key
                writeDebugLog(
                    "[\(LockScreenLyrics.logTag)] no synced lyrics for this track —"
                        + " the lock screen keeps its artwork"
                )
            }
            if #available(iOS 26.0, *) {
                LockScreenArtworkInjector.republishForLockScreen()
            }
            refreshTimer()
            return
        }

        writeDebugLog("[\(LockScreenLyrics.logTag)] \(count) line(s) ready\(coverage)")
        tick()
    }

    // MARK: - 逐字升级（页内 dto → 锁屏）

    /// 锁屏自己取词时往往只能拿到**行级**时间轴（例如 Spicy 对这首歌只回 `type=Line`），
    /// 词级时间轴要等页内那条链跑完、`currentLyricsDto` 落地才可能有。同一首的 dto
    /// 对得上、且到了逐字档时，把行换成转换后的那一份，并清掉 `preparedLineKey`：
    /// 当前这一行已经装出去的素材是按单帧画的，下一拍要按帧表重装一次。
    ///
    /// 转换（罗马化 + 逐字对齐）在后台队列上做，锁只在读/写状态时短暂持有；
    /// 回到主线程时按 generation 判断这一首还在不在。
    private func upgradeLinesFromLoadedDto(
        replacing current: [LockScreenLyricLine],
        key: String
    ) {
        // 逐字关着时不升级：`convert` 那时根本不建帧表。
        guard UserDefaults.lockScreenWordByWord else { return }
        // 已经有帧（取词那次就是逐字档，或已经升级过）就不用再看。
        guard !current.contains(where: { !$0.karaoke.isEmpty }) else { return }

        lock.lock()
        let identifier = trackId
        let stamp = generation
        let canAttempt = trackKey == key && !identifier.isEmpty && !upgradeAttempted
        lock.unlock()
        guard canAttempt else { return }

        // dto 还没落地时 `loadedLyrics` 给 nil —— 这时**不能**记"试过了"，
        // 下一拍还要再看一次。
        guard let dto = loadedLyrics(for: identifier) else { return }
        // 档次判据与页内 auto-select 同一份：行级/纯文本的 dto 换过来也不会有帧。
        guard LyricsAutoSelect.tier(of: dto) == .word else { return }

        lock.lock()
        guard stamp == generation, trackKey == key, trackId == identifier else {
            lock.unlock()
            return
        }
        upgradeAttempted = true
        lock.unlock()

        let source = currentLyricsSource
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let converted = LockScreenLyricsFetcher.convert(dto, source: source)
            DispatchQueue.main.async {
                self?.finishUpgrade(
                    stamp: stamp,
                    key: key,
                    identifier: identifier,
                    converted: converted,
                    providerName: dto.providerName
                )
            }
        }
    }

    /// 升级转换回到主线程。只有真的带上了帧才换 —— 词拼起来和行文本对不上时
    /// `convert` 给的是空帧表，换过去只是把同一份行级词重画一遍。
    private func finishUpgrade(
        stamp: UInt64,
        key: String,
        identifier: String,
        converted: [LockScreenLyricLine]?,
        providerName: String
    ) {
        guard let converted,
              converted.contains(where: { !$0.karaoke.isEmpty }) else { return }

        lock.lock()
        guard stamp == generation, trackKey == key, trackId == identifier else {
            lock.unlock()
            return
        }
        let previousCount = lines.count
        lines = converted
        // 署名跟着**实际**给词的那一份走（与 `beginTrack` 里"内存里已加载"那条同一条规则）。
        if !providerName.isEmpty { credit = providerName }
        // 只清标记：下一拍会按新帧表重装。不清 `prepared` —— 系统可能还在取那份素材
        // （同 `typographyDidChange`）。
        preparedLineKey = ""
        lock.unlock()

        let provider = providerName.isEmpty ? "currentLyricsDto" : providerName
        writeDebugLog(
            "[\(LockScreenLyrics.logTag)] word-by-word upgrade — \(converted.count) line(s)"
                + LockScreenLyricsFetcher.coverageLogSuffix(for: converted)
                + (previousCount == converted.count
                    ? ""
                    : " (line count \(previousCount) → \(converted.count))")
                + " from \(provider)"
        )
        // 帧表变了 = 这一行的素材整个换了：让定时器继续跑，下一拍就会重装。
        refreshTimer()
    }

    // MARK: - 装一行

    @available(iOS 26.0, *)
    private func install(
        lineKey: String,
        location: LocatedLine,
        lines: [LockScreenLyricLine],
        trackKey: String
    ) {
        let supported = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
        guard !supported.isEmpty else { return }
        let aspects = LockScreenArtwork.Aspect.allCases.filter {
            supported.contains(Self.nowPlayingKey(for: $0))
        }
        guard !aspects.isEmpty else { return }

        // 先把这一行占住，定时器就不会重复发起。预览在后台画：锁屏正在画那一屏，
        // 一次模糊 + 两次文字排版堵在主线程上会有肉眼可见的卡顿。
        lock.lock()
        preparedLineKey = lineKey
        lock.unlock()

        let cover = currentCover()
        let credit = currentCredit()
        let texts = Self.texts(for: location, in: lines)
        let frameHash = LockScreenLyrics.frameHash(
            line: texts.line,
            next: texts.next,
            translation: texts.translation,
            romanization: texts.romanization,
            isDuet: texts.isDuet,
            flipped: texts.flipped,
            nextFlipped: texts.nextFlipped,
            karaoke: texts.karaoke,
            credit: credit,
            hasCover: cover != nil,
            // 两档倍率进文件名：改了「歌词 → 文字」之后旧片段不该再被命中，
            // 否则锁屏上要等到下一次清理缓存才换字号。
            textScale: NgzhwmSettingsViewModel.lyricsTextScale,
            spacingScale: NgzhwmSettingsViewModel.lyricsLineSpacingScale
        )

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var rendered: [LockScreenArtwork.Aspect: UIImage] = [:]
            for aspect in aspects {
                let size = LyricClipRenderer.clipSize(for: aspect)
                if let image = try? LyricClipRenderer.stillImage(
                    cover: cover,
                    line: texts.line,
                    next: texts.next,
                    translation: texts.translation,
                    romanization: texts.romanization,
                    isDuet: texts.isDuet,
                    flipped: texts.flipped,
                    nextFlipped: texts.nextFlipped,
                    revealedCharacters: texts.karaoke.first?.revealedCharacters,
                    credit: credit,
                    size: size
                ) {
                    rendered[aspect] = UIImage(cgImage: image)
                }
            }
            DispatchQueue.main.async {
                self?.finishInstall(
                    lineKey: lineKey,
                    location: location,
                    texts: texts,
                    credit: credit,
                    frameHash: frameHash,
                    aspects: aspects,
                    rendered: rendered,
                    lines: lines,
                    trackKey: trackKey,
                    cover: cover
                )
            }
        }
    }

    @available(iOS 26.0, *)
    private func finishInstall(
        lineKey: String,
        location: LocatedLine,
        texts: LineTexts,
        credit: String,
        frameHash: String,
        aspects: [LockScreenArtwork.Aspect],
        rendered: [LockScreenArtwork.Aspect: UIImage],
        lines: [LockScreenLyricLine],
        trackKey: String,
        cover: CGImage?
    ) {
        // 画预览这段时间里可能已经切歌/换行：不是当前这一行就丢掉。
        guard LockScreenLyrics.isEnabled else { return }
        lock.lock()
        let stillCurrent = trackKey == self.trackKey && preparedLineKey == lineKey
        lock.unlock()
        guard stillCurrent else { return }

        var prepared: [String: Any] = [:]
        for aspect in aspects {
            let key = Self.nowPlayingKey(for: aspect)
            let artworkID = LockScreenLyrics.artworkID(
                trackKey: trackKey,
                lineIndex: location.index,
                resting: location.resting,
                aspect: aspect,
                frameHash: frameHash
            )
            if let preview = rendered[aspect] {
                previews.setObject(preview, forKey: artworkID as NSString)
            }
            prepared[key] = artwork(
                artworkID: artworkID,
                aspect: aspect,
                location: location,
                texts: texts,
                credit: credit,
                frameHash: frameHash,
                lines: lines,
                trackKey: trackKey,
                cover: cover
            )
        }

        guard !prepared.isEmpty else { return }

        lock.lock()
        self.prepared = prepared
        preparedTrackKey = trackKey
        lock.unlock()

        writeDebugLog(
            "[\(LockScreenLyrics.logTag)] line \(location.index)\(location.resting ? " (resting)" : "")"
                + " — installing \(prepared.count) artwork key(s)"
        )
        LockScreenArtworkInjector.republishForLockScreen()
    }

    @available(iOS 26.0, *)
    private func artwork(
        artworkID: String,
        aspect: LockScreenArtwork.Aspect,
        location: LocatedLine,
        texts: LineTexts,
        credit: String,
        frameHash: String,
        lines: [LockScreenLyricLine],
        trackKey: String,
        cover: CGImage?
    ) -> MPMediaItemAnimatedArtwork {
        let seconds = Self.clipSeconds(for: location, in: lines)
        let size = LyricClipRenderer.clipSize(for: aspect)
        let lineKey = Self.lineKey(for: location)

        return MPMediaItemAnimatedArtwork(
            artworkID: artworkID,
            previewImageRequestHandler: { [weak self] wanted, completion in
                guard let self else {
                    completion(nil)
                    return
                }
                // 系统来取预览图。这一行是"它到底按 ID 重新取了几次"的唯一证据：
                // 是否要给每行切片（Canvas 叠词那条路）取决于这个节奏。
                let cached = self.previewImage(for: artworkID)
                writeDebugLog(
                    "[\(LockScreenLyrics.logTag)] still asked — line \(location.index)"
                        + "\(location.resting ? "r" : "") \(aspect.rawValue)"
                        + " \(Int(wanted.width))x\(Int(wanted.height))"
                        + (cached == nil ? " cold" : " warm")
                )
                if let ready = cached {
                    completion(ArtworkImageScaling.fill(ready, to: wanted))
                    return
                }
                // 没画好就现画一张（几十毫秒）—— 交 nil 系统会画灰块，比静态封面还难看。
                if let image = try? LyricClipRenderer.stillImage(
                    cover: cover,
                    line: texts.line,
                    next: texts.next,
                    translation: texts.translation,
                    romanization: texts.romanization,
                    isDuet: texts.isDuet,
                    flipped: texts.flipped,
                    nextFlipped: texts.nextFlipped,
                    revealedCharacters: texts.karaoke.first?.revealedCharacters,
                    credit: credit,
                    size: size
                ) {
                    let uiImage = UIImage(cgImage: image)
                    self.previews.setObject(uiImage, forKey: artworkID as NSString)
                    completion(ArtworkImageScaling.fill(uiImage, to: wanted))
                } else if let cover {
                    completion(ArtworkImageScaling.fill(UIImage(cgImage: cover), to: wanted))
                } else {
                    completion(nil)
                }
            },
            videoAssetFileURLRequestHandler: { [weak self] _, completion in
                guard let self else {
                    completion(nil)
                    return
                }
                writeDebugLog(
                    "[\(LockScreenLyrics.logTag)] video asked — line \(location.index)"
                        + "\(location.resting ? "r" : "") \(aspect.rawValue)"
                )
                Task { [weak self] in
                    guard let self else {
                        completion(nil)
                        return
                    }
                    // 这一行已经不是当前行了（用户拖了进度/切了歌）：不要再花时间编码。
                    guard self.isLineCurrent(trackKey: trackKey, lineKey: lineKey) else {
                        completion(nil)
                        return
                    }
                    let file = await self.clipURL(
                        trackKey: trackKey,
                        lineIndex: location.index,
                        resting: location.resting,
                        aspect: aspect,
                        frameHash: frameHash,
                        line: texts.line,
                        next: texts.next,
                        translation: texts.translation,
                        romanization: texts.romanization,
                        isDuet: texts.isDuet,
                        flipped: texts.flipped,
                        nextFlipped: texts.nextFlipped,
                        karaoke: texts.karaoke,
                        credit: credit,
                        cover: cover,
                        seconds: seconds
                    )
                    completion(file)
                }
            }
        )
    }

    /// 单帧短片按"到下一行的时间 + 余量"给时长；写文件是异步且单飞的。
    @available(iOS 26.0, *)
    private func clipURL(
        trackKey: String,
        lineIndex: Int,
        resting: Bool,
        aspect: LockScreenArtwork.Aspect,
        frameHash: String,
        line: String?,
        next: String?,
        translation: String?,
        romanization: String?,
        isDuet: Bool,
        flipped: Bool,
        nextFlipped: Bool,
        karaoke: [LockScreenKaraokeFrame],
        credit: String,
        cover: CGImage?,
        seconds: Double
    ) async -> URL? {
        let directory = LockScreenLyrics.cacheDirectory(for: trackKey)
        let file = directory.appendingPathComponent(
            LockScreenLyrics.clipFileName(
                lineIndex: lineIndex,
                resting: resting,
                aspect: aspect,
                frameHash: frameHash
            )
        )
        if FileManager.default.fileExists(atPath: file.path) {
            writeDebugLog(
                "[\(LockScreenLyrics.logTag)] clip reused — \(file.lastPathComponent)"
            )
            return file
        }

        lock.lock()
        if let running = clipTasks[file.path] {
            lock.unlock()
            return await running.value
        }
        let size = LyricClipRenderer.clipSize(for: aspect)
        // 编码一条要多久、每段名义时长是多少 —— 决定"按行切片"能不能对得上时间轴。
        writeDebugLog(
            "[\(LockScreenLyrics.logTag)] clip encoding — line \(lineIndex)"
                + "\(resting ? "r" : "") \(aspect.rawValue) \(String(format: "%.1f", seconds))s"
        )
        let task = Task<URL?, Never> {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                try await LyricClipRenderer.write(
                    cover: cover,
                    line: line,
                    next: next,
                    translation: translation,
                    romanization: romanization,
                    isDuet: isDuet,
                    flipped: flipped,
                    nextFlipped: nextFlipped,
                    karaoke: karaoke,
                    credit: credit,
                    size: size,
                    seconds: seconds,
                    to: file
                )
                return file
            } catch {
                writeDebugLog(
                    "[\(LockScreenLyrics.logTag)] clip failed — \(error.localizedDescription)"
                )
                return nil
            }
        }
        clipTasks[file.path] = task
        lock.unlock()

        let result = await task.value
        lock.lock()
        clipTasks[file.path] = nil
        lock.unlock()
        return result
    }

    // MARK: - 状态

    private func currentCover() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return cover
    }

    private func currentCredit() -> String {
        lock.lock()
        defer { lock.unlock() }
        return credit
    }

    /// 系统可能在我们已经换行/切歌之后才来要上一行的视频：那时不要再花时间编码。
    private func isLineCurrent(trackKey: String, lineKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.trackKey == trackKey && preparedLineKey == lineKey
    }

    /// 设置页的"清除"：连当前这首一起清，同时把这行已经装出去的 artwork 撤掉，
    /// 免得系统手里还指着一个刚被删掉的文件。下一拍会按当前行重新装。
    func purgeCache() {
        lock.lock()
        prepared = [:]
        preparedLineKey = ""
        preparedTrackKey = ""
        clipTasks.removeAll()
        lock.unlock()

        previews.removeAllObjects()
        LockScreenLyrics.clearCache()
        if #available(iOS 26.0, *) {
            LockScreenArtworkInjector.republishForLockScreen()
        }
    }

    private func previewImage(for artworkID: String) -> UIImage? {
        previews.object(forKey: artworkID as NSString)
    }

    private func reset() {
        lock.lock()
        info = nil
        infoAt = 0
        cover = nil
        coverTrackKey = ""
        trackKey = ""
        trackId = ""
        lines = []
        credit = ""
        linesFetched = false
        fetchInFlight = false
        waitingForPlayer = false
        upgradeAttempted = false
        playerRetryDeadline = 0
        nextPlayerRetryAt = 0
        prepared = [:]
        preparedLineKey = ""
        preparedTrackKey = ""
        clipTasks.removeAll()
        generation &+= 1
        lock.unlock()

        previews.removeAllObjects()
    }

    private func currentTrack(matching title: String) -> SPTPlayerTrack? {
        guard let track = statefulPlayer?.currentTrack() else { return nil }
        let trackTitle = Self.title(of: track)
        guard LockScreenArtwork.looksLikeSameSong(trackTitle, title) else { return nil }
        return track
    }

    private func loadedLyrics(for identifier: String) -> LyricsDto? {
        guard currentLyricsDtoTrackId == identifier else { return nil }
        return currentLyricsDto
    }

    private func makeQuery(track: SPTPlayerTrack) -> LyricsSearchQuery {
        let metadata = track.metadata()
        let title = Self.title(of: track)
        let metadataTitle = metadata["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        var titleVariants: [String] = []
        if let metadataTitle, !metadataTitle.isEmpty, metadataTitle != title {
            titleVariants.append(metadataTitle)
        }

        let album = metadata["album_title"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        return LyricsSearchQuery(
            title: title,
            primaryArtist: Self.artist(of: track),
            spotifyTrackId: track.trackIdentifier,
            durationMs: track.trackDurationMilliseconds,
            artistNames: Self.allArtistNames(in: metadata),
            titleVariants: titleVariants,
            albumTitle: (album?.isEmpty == false) ? album : nil
        )
    }

    /// `SPTPlayerTrack` 是手写的 `@objc protocol` —— **声明了不等于实现了**：8.9.8 上
    /// `artistName` 就不存在，直接调会 `unrecognized selector` 崩掉（见
    /// `SPTPlayerTrack+Extension.swift` 文件头）。这两个 getter 一律走探测式调用。
    private static func title(of track: SPTPlayerTrack) -> String {
        track.string(ifResponding: "trackTitle") ?? ""
    }

    private static func artist(of track: SPTPlayerTrack) -> String {
        track.string(ifResponding: "artistName")
            ?? track.string(ifResponding: "artistTitle")
            ?? ""
    }

    private static func allArtistNames(in metadata: [String: String]) -> [String] {
        metadata.keys
            .filter { $0 == "artist_name" || $0.hasPrefix("artist_name:") }
            .sorted()
            .compactMap { key in
                guard let value = metadata[key] else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
    }

    // MARK: - 行与时间

    struct LocatedLine {
        let index: Int
        let resting: Bool
    }

    /// 现在唱到第几行。`resting` = 这一句已经唱完、下一句还远（间奏/换段），
    /// 此时只画压暗的下一行。
    static func locate(in lines: [LockScreenLyricLine], positionMs: Int) -> LocatedLine? {
        guard !lines.isEmpty else { return nil }
        guard positionMs >= 0 else { return nil }

        var index = -1
        for (offset, line) in lines.enumerated() {
            if line.startMs <= positionMs {
                index = offset
            } else {
                break
            }
        }
        // 还没到第一行：预告第一行（压暗显示）。
        guard index >= 0 else {
            return LocatedLine(index: -1, resting: true)
        }

        // 唱完 breakMs 之后到下一行开始之前都算"间奏态"：只留压暗的下一行。
        // 不把"下一句还远"加进判据 —— 那样在下一句前 4 秒会翻回刚唱完的那一句，
        // 用户会看到一句已经唱过的词又被点亮。
        let line = lines[index]
        let resting = positionMs > line.endMs + LockScreenLyrics.breakMs
        return LocatedLine(index: index, resting: resting)
    }

    private static func lineKey(for location: LocatedLine) -> String {
        "\(location.index)\(location.resting ? "r" : "")"
    }

    private struct LineTexts {
        let line: String?
        let next: String?
        let translation: String?
        let romanization: String?
        let isDuet: Bool
        let flipped: Bool
        let nextFlipped: Bool
        /// 逐字的帧表（空 = 单帧）。它同时进 `frameHash`：单帧与多帧是两份素材。
        let karaoke: [LockScreenKaraokeFrame]
    }

    private static func texts(
        for location: LocatedLine,
        in lines: [LockScreenLyricLine]
    ) -> LineTexts {
        if location.resting {
            let nextLine = location.index + 1 < lines.count ? lines[location.index + 1] : nil
            return LineTexts(
                line: nil,
                next: nextLine?.text,
                translation: nil,
                romanization: nil,
                isDuet: nextLine?.isDuet ?? false,
                flipped: false,
                nextFlipped: nextLine?.agentFlipped ?? false,
                karaoke: []
            )
        }
        let current = location.index >= 0 && location.index < lines.count
            ? lines[location.index]
            : nil
        let nextLine = location.index + 1 < lines.count ? lines[location.index + 1] : nil
        // 译文 / 罗马字只在"这一行正在唱"时画：间奏态只留压暗的下一行，
        // 多一行辅助文字会把那个提示挤掉。
        let translation = current?.translation ?? ""
        let romanization = current?.romanization ?? ""
        return LineTexts(
            line: current?.text,
            next: nextLine?.text,
            translation: translation.isEmpty ? nil : translation,
            romanization: romanization.isEmpty ? nil : romanization,
            isDuet: current?.isDuet ?? false,
            flipped: current?.agentFlipped ?? false,
            nextFlipped: nextLine?.agentFlipped ?? false,
            karaoke: current?.karaoke ?? []
        )
    }

    /// 一段片子的名义时长。换行由定时器负责，这里只要"盖住到下一行的时间"。
    private static func clipSeconds(
        for location: LocatedLine,
        in lines: [LockScreenLyricLine]
    ) -> Double {
        guard !location.resting, location.index >= 0, location.index < lines.count else {
            return 20
        }
        let start = lines[location.index].startMs
        let end = location.index + 1 < lines.count
            ? lines[location.index + 1].startMs
            : lines[location.index].endMs + LockScreenLyrics.breakMs
        let gap = Double(end - start) / 1000
        return min(
            max(gap + 2, LockScreenLyrics.shortestClipSeconds),
            LockScreenLyrics.longestClipSeconds
        )
    }

    @available(iOS 26.0, *)
    private static func nowPlayingKey(for aspect: LockScreenArtwork.Aspect) -> String {
        switch aspect {
        case .square: return MPNowPlayingInfoProperty1x1AnimatedArtwork
        case .tall: return MPNowPlayingInfoProperty3x4AnimatedArtwork
        }
    }
}
