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
        _ = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.settingsMayHaveChanged()
        }
        // 只在 App 不在前台时跑：锁屏歌词要的本来就是锁屏，而前台的 Spotify 有自己的
        // now-playing / 界面链路，我们这时去重写那份字典只会和它抢同一套观察者。
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshTimer()
        }
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshTimer()
        }
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshTimer()
        }
        writeDebugLog(
            "[\(LockScreenLyrics.logTag)] ready —"
                + " lock screen lyrics \(lastEnabled ? "on" : "off")"
        )
    }

    private func settingsMayHaveChanged() {
        let enabled = LockScreenLyrics.isEnabled
        guard enabled != lastEnabled else { return }
        lastEnabled = enabled

        if enabled {
            writeDebugLog("[\(LockScreenLyrics.logTag)] switched on")
            refreshTimer()
            // 前台不补写：见 `refreshTimer` 的说明。锁屏后的第一拍会自己接管。
            if #available(iOS 26.0, *), UIApplication.shared.applicationState == .background {
                LockScreenArtworkInjector.republishForLockScreen()
            }
        } else {
            writeDebugLog("[\(LockScreenLyrics.logTag)] switched off")
            stopTimer()
            reset()
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
        // 只在后台（= 锁屏 / 用户在别的 App）跑：前台那一段用不到，而且此刻 Spotify
        // 自己的界面链路正在用同一份 now-playing，重写它只会把两边的观察者搅在一起。
        guard UIApplication.shared.applicationState == .background else {
            suspendForForeground()
            return
        }
        if currentRate() > 0 {
            startTimer()
        } else {
            stopTimer()
        }
    }

    /// 回到前台：停表，并把已经装出去的歌词 artwork 撤掉。
    ///
    /// 不撤的话，Spotify 在前台每次自己写 now-playing，我们的 hook 都会把这一行的
    /// artwork 再塞回去 —— 那仍然是一次前台写入。行数据与缓存都留着，下次锁屏直接重装。
    private func suspendForForeground() {
        stopTimer()
        lock.lock()
        prepared = [:]
        preparedLineKey = ""
        preparedTrackKey = ""
        lock.unlock()
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
            // 第一拍晚 600ms：刚进后台时系统还在收尾 scene 更新，别在这个窗口里
            // 去动 now-playing（那是 scene-update watchdog 盯的时刻）。
            deadline: .now() + .milliseconds(600),
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
        // 回到前台就停（观察者已经处理；这个判断兜住竞态）。
        guard UIApplication.shared.applicationState == .background else {
            suspendForForeground()
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
           let converted = LockScreenLyricsFetcher.convert(dto) {
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
            )
            return true
        }

        let query = makeQuery(track: track)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = LockScreenLyricsFetcher.lines(
                for: query,
                trackId: identifier,
                deadline: Date().addingTimeInterval(20)
            )
            DispatchQueue.main.async {
                self?.finishFetch(stamp: stamp, key: key, identifier: identifier, result: result)
            }
        }
        return false
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
        lines = result?.lines ?? []
        if let result {
            credit = result.source.description
        }
        linesFetched = true
        fetchInFlight = false
        waitingForPlayer = false
        let count = lines.count
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

        writeDebugLog("[\(LockScreenLyrics.logTag)] \(count) line(s) ready")
        tick()
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
            credit: credit,
            hasCover: cover != nil
        )

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var rendered: [LockScreenArtwork.Aspect: UIImage] = [:]
            for aspect in aspects {
                let size = LyricClipRenderer.clipSize(for: aspect)
                if let image = try? LyricClipRenderer.stillImage(
                    cover: cover,
                    line: texts.line,
                    next: texts.next,
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
        texts: (line: String?, next: String?),
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
        texts: (line: String?, next: String?),
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
                if let ready = self.previewImage(for: artworkID) {
                    completion(ArtworkImageScaling.fill(ready, to: wanted))
                    return
                }
                // 没画好就现画一张（几十毫秒）—— 交 nil 系统会画灰块，比静态封面还难看。
                if let image = try? LyricClipRenderer.stillImage(
                    cover: cover,
                    line: texts.line,
                    next: texts.next,
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
            return file
        }

        lock.lock()
        if let running = clipTasks[file.path] {
            lock.unlock()
            return await running.value
        }
        let size = LyricClipRenderer.clipSize(for: aspect)
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

    private static func texts(
        for location: LocatedLine,
        in lines: [LockScreenLyricLine]
    ) -> (line: String?, next: String?) {
        if location.resting {
            let next = location.index + 1 < lines.count ? lines[location.index + 1].text : nil
            return (nil, next)
        }
        let line = location.index >= 0 ? lines[location.index].text : nil
        let next = location.index + 1 < lines.count ? lines[location.index + 1].text : nil
        return (line, next)
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
