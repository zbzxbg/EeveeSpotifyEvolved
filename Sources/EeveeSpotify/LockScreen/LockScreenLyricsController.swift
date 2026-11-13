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
    private var linesFetched = false
    /// 正在取词（或正在等播放器对象出现）。避免同一首每拍都重来一遍。
    private var fetchInFlight = false
    /// 冷启动时 `statefulPlayer` 可能比第一次 now-playing 写入晚几秒才出现；
    /// 这段时间里"没有曲目对象"不等于"这首没词"，要给到一次重试的机会。
    private var playerRetryDeadline: CFAbsoluteTime = 0
    private var nextPlayerRetryAt: CFAbsoluteTime = 0
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
            // 刚打开时可能已经播了一会儿：让注入器按 Spotify 最近一次写的字典补一次，
            // 时钟才会从现在开始走（否则要等它下一次自己写 now-playing）。
            if #available(iOS 26.0, *) {
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
            leeway: .milliseconds(10)
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
        let duration = (info[MPNowPlayingInfoPropertyPlaybackDuration] as? NSNumber)?.doubleValue ?? 0
        let key = LockScreenLyrics.trackKey(title: title, artist: artist, duration: duration)

        lock.lock()
        let changed = key != trackKey
        lock.unlock()

        if changed {
            if let artwork = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork,
               let image = artwork.image(at: CGSize(width: 600, height: 600)) {
                noteCover(image, trackKey: key)
            }
            beginTrack(key: key, title: title)
        }

        var ready = false
        var currentLines: [LockScreenLyricLine] = []
        var shouldRetry = false
        lock.lock()
        ready = linesFetched
        currentLines = lines
        if !ready, !fetchInFlight, trackKey == key {
            shouldRetry = CFAbsoluteTimeGetCurrent() >= nextPlayerRetryAt
        }
        lock.unlock()

        // 冷启动：第一次写入可能比 `statefulPlayer` 早到。等一秒再试，15 秒后放弃。
        if shouldRetry {
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
        linesFetched = false
        fetchInFlight = true
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
            lock.lock()
            if stamp == generation {
                lines = converted
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
        linesFetched = true
        fetchInFlight = false
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

        let cover = currentCover()
        let texts = Self.texts(for: location, in: lines)
        let frameHash = LockScreenLyrics.frameHash(line: texts.line, next: texts.next)
        var prepared: [String: Any] = [:]
        for aspect in LockScreenArtwork.Aspect.allCases {
            let key = Self.nowPlayingKey(for: aspect)
            guard supported.contains(key) else { continue }
            let artworkID = LockScreenLyrics.artworkID(
                trackKey: trackKey,
                lineIndex: location.index,
                resting: location.resting,
                aspect: aspect,
                frameHash: frameHash
            )

            // 预览必须赶在系统来要之前画好：系统一拿到新 ID 就同时要预览与视频，
            // 预览慢一拍会先闪静态封面，再慢就画成灰色占位图。
            let size = LyricClipRenderer.clipSize(for: aspect)
            if let image = try? LyricClipRenderer.stillImage(
                cover: cover,
                line: texts.line,
                next: texts.next,
                size: size
            ) {
                previews.setObject(UIImage(cgImage: image), forKey: artworkID as NSString)
            }

            prepared[key] = artwork(
                artworkID: artworkID,
                aspect: aspect,
                location: location,
                texts: texts,
                frameHash: frameHash,
                lines: lines,
                trackKey: trackKey,
                cover: cover
            )
        }

        guard !prepared.isEmpty else { return }

        lock.lock()
        self.prepared = prepared
        preparedLineKey = lineKey
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
        frameHash: String,
        lines: [LockScreenLyricLine],
        trackKey: String,
        cover: CGImage?
    ) -> MPMediaItemAnimatedArtwork {
        let seconds = Self.clipSeconds(for: location, in: lines)
        let size = LyricClipRenderer.clipSize(for: aspect)

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
                    let file = await self.clipURL(
                        trackKey: trackKey,
                        lineIndex: location.index,
                        resting: location.resting,
                        aspect: aspect,
                        frameHash: frameHash,
                        line: texts.line,
                        next: texts.next,
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
        linesFetched = false
        fetchInFlight = false
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
        let trackTitle = track.trackTitle()
        guard LockScreenArtwork.looksLikeSameSong(trackTitle, title) else { return nil }
        return track
    }

    private func loadedLyrics(for identifier: String) -> LyricsDto? {
        guard currentLyricsDtoTrackId == identifier else { return nil }
        return currentLyricsDto
    }

    private func makeQuery(track: SPTPlayerTrack) -> LyricsSearchQuery {
        let metadata = track.metadata()
        let title = track.trackTitle()
        let metadataTitle = metadata["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        var titleVariants: [String] = []
        if let metadataTitle, !metadataTitle.isEmpty, metadataTitle != title {
            titleVariants.append(metadataTitle)
        }

        let album = metadata["album_title"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        return LyricsSearchQuery(
            title: title,
            primaryArtist: track.artistName(),
            spotifyTrackId: track.trackIdentifier,
            durationMs: track.trackDurationMilliseconds,
            artistNames: Self.allArtistNames(in: metadata),
            titleVariants: titleVariants,
            albumTitle: (album?.isEmpty == false) ? album : nil
        )
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

        let line = lines[index]
        let nextStart = index + 1 < lines.count ? lines[index + 1].startMs : nil
        let nextIsFar = nextStart == nil || (nextStart! - positionMs) > LockScreenLyrics.breakMs
        let resting = positionMs > line.endMs + LockScreenLyrics.breakMs && nextIsFar
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
