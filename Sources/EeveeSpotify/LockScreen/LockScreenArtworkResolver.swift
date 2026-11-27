import Foundation
import MediaPlayer
import UIKit

/// 把"当前这一首"解析成一条本地短片。
///
/// 三件事都归它管：挑源（Canvas → Apple Music → 本地 Fill）、下载/渲染并落盘、
/// 给系统一个本地 URL。系统的两个 handler（预览图 / 视频）可能同时、也可能隔很久才被
/// 调用，所以同一首歌的解析要**单飞**：同一个 key 只跑一个任务，后来的人等它的结果。
final class LockScreenArtworkResolver {

    static let shared = LockScreenArtworkResolver()

    /// 一首歌的两个画幅共用一次目录查询。
    private struct Sources {
        let canvas: AnimatedArtworkAsset?
        let apple: AppleMusicEditorialAssets

        static let empty = Sources(canvas: nil, apple: .empty)
    }

    private enum Candidate {
        case remote(AnimatedArtworkAsset)
        case fill

        var label: String {
            switch self {
            case .remote(let asset): return asset.source.rawValue
            case .fill: return "fill"
            }
        }

        var alwaysExport: Bool {
            if case .remote(let asset) = self { return asset.isHLS }
            return false
        }
    }

    private let session: URLSession
    private let lock = NSLock()
    /// 一首歌的目录查询结果。
    ///
    /// `retryAfter` 只在**什么也没找到**时才有值：那种"空"可能只是 metadata 还没就绪、
    /// token 没拿到或网络超时，不能按歌缓存到本次运行结束（否则这首歌之后再出现的锁屏
    /// 都不会再试）。确定找到了东西就永久缓存。
    private struct CachedSources {
        let value: Sources
        let retryAfter: Date?
    }
    private static let transientMissRetryInterval: TimeInterval = 120
    private var sources: [String: CachedSources] = [:]
    private var resolving: [String: Task<Sources, Never>] = [:]
    private var running: [String: Task<URL?, Never>] = [:]
    private var runningTokens: [String: UUID] = [:]
    private var reportedMisses = Set<String>()
    /// 已经排过预热的 key → 上一次排的时间。`videoFileURL` 自己做单飞，这里只是为了别每写
    /// 一次 now-playing 就 spawn 一个 Task；但**空结果**要允许过一阵再预热一次（与
    /// `transientMissRetryInterval` 同一个间隔），否则一次早到的失败会让这首歌永远不再试。
    private var warmed: [String: Date] = [:]
    private var reportedNoMetadata = false
    private var lastNowPlaying = ""
    private var generation: UInt64 = 0

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    // MARK: - 切歌

    /// 系统写 now-playing 时由注入器调用。标识变了就把旧任务全部取消：旧歌的下载不应该
    /// 在切歌之后继续跑，也不应该把结果写进缓存（代次戳在每个落盘点上都再核一次）。
    func noteNowPlaying(identifier: String) {
        lock.lock()
        guard identifier != lastNowPlaying else {
            lock.unlock()
            return
        }
        lastNowPlaying = identifier
        generation &+= 1
        let stale = running.values
        running.removeAll()
        runningTokens.removeAll()
        lock.unlock()

        stale.forEach { $0.cancel() }
    }

    private func currentGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    private func isCurrent(_ stamp: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stamp == generation
    }

    private func isCurrentTrack(_ identifier: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return identifier == lastNowPlaying
    }

    // MARK: - 系统要的两样东西

    /// 预览图：有首帧缓存就裁成系统要的尺寸，没有就用注入时抓到的封面静帧裁一张。
    ///
    /// 这条路径**不做网络请求、也不回调 Spotify 的 artwork provider**：系统在视频还没到手
    /// 时显示它，慢一拍就会先闪静态封面，等得久了甚至直接退回静态封面、不再来要视频。
    /// 静帧由注入器在写 now-playing 时抓一次（拿不到就退到 track metadata 的封面地址）；
    /// 拿不到静帧时宁可不注入动画键，也不交给系统一个空预览 —— 那会显示成灰色占位图。
    func previewImage(
        title: String,
        artist: String,
        duration: Double,
        aspect: LockScreenArtwork.Aspect,
        size: CGSize,
        still: UIImage?
    ) -> UIImage? {
        let key = AnimatedArtworkCache.key(
            title: title,
            artist: artist,
            duration: duration,
            aspect: aspect
        )
        if let cached = AnimatedArtworkCache.preview(key: key) {
            return ArtworkImageScaling.fill(cached, to: size)
        }
        guard let still else { return nil }
        return ArtworkImageScaling.fill(still, to: size)
    }

    /// 视频：缓存里有就给路径，没有就挑源、下载/渲染、裁画幅、落盘。系统给这个 handler
    /// 的预算是 30 秒，所以目录查询和下载的超时都压在 15 秒以内。
    func videoFileURL(
        identifier: String,
        title: String,
        artist: String,
        album: String,
        duration: Double,
        aspect: LockScreenArtwork.Aspect,
        size: CGSize,
        still: UIImage?
    ) async -> URL? {
        let key = AnimatedArtworkCache.key(
            title: title,
            artist: artist,
            duration: duration,
            aspect: aspect
        )
        if let existing = AnimatedArtworkCache.existing(key: key) {
            return existing
        }
        // 系统可能在切歌之后才来要上一首的素材；旧 artwork 对象还活着，但那首歌已经不是
        // 当前曲目了，没必要再为它下载。
        guard isCurrentTrack(identifier) else { return nil }

        let stamp = currentGeneration()
        let token = UUID()

        lock.lock()
        if let task = running[key] {
            lock.unlock()
            return await task.value
        }
        let task = Task<URL?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.produce(
                key: key,
                stamp: stamp,
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                aspect: aspect,
                size: size,
                still: still
            )
        }
        running[key] = task
        runningTokens[key] = token
        lock.unlock()

        let result = await task.value

        lock.lock()
        if runningTokens[key] == token {
            running[key] = nil
            runningTokens[key] = nil
        }
        lock.unlock()
        return result
    }

    // MARK: - 预热

    /// 系统来要素材之前，先把这一首的短片做出来。
    ///
    /// 系统给视频 handler 的预算是 30 秒，而第一次解析是"查目录（网络）+ 下载/渲染"，
    /// 真机上十几秒起 —— 等它来要才开始，锁屏那一屏基本只等得到静帧。所以注入完
    /// now-playing 就先把活排上：这时 App 通常还在前台、CPU 没被限，系统来要时直接命中缓存。
    func warm(
        identifier: String,
        title: String,
        artist: String,
        album: String,
        duration: Double,
        aspect: LockScreenArtwork.Aspect,
        still: UIImage?
    ) {
        guard LockScreenArtwork.isEnabled, still != nil else { return }

        let key = AnimatedArtworkCache.key(
            title: title,
            artist: artist,
            duration: duration,
            aspect: aspect
        )
        lock.lock()
        let now = Date()
        let last = warmed[key]
        let shouldWarm = last == nil
            || now.timeIntervalSince(last!) >= Self.transientMissRetryInterval
        if shouldWarm { warmed[key] = now }
        if warmed.count > 64 { warmed.removeAll() }
        lock.unlock()
        guard shouldWarm else { return }

        writeDebugLog(
            "[\(LockScreenArtwork.logTag)] warming — \(aspect.rawValue), \"\(title)\""
        )
        Task { [weak self] in
            _ = await self?.videoFileURL(
                identifier: identifier,
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                aspect: aspect,
                size: aspect.renderSize,
                still: still
            )
        }
    }

    // MARK: - 生产

    private func produce(
        key: String,
        stamp: UInt64,
        title: String,
        artist: String,
        album: String,
        duration: Double,
        aspect: LockScreenArtwork.Aspect,
        size: CGSize,
        still: UIImage?
    ) async -> URL? {
        // 系统给视频 handler 的预算约 30 秒；整条"目录查询 + 下载 + 转码"压在 22 秒内，
        // 剩下的时间给本地 Fill 和转码。每个 await 之后都再看一眼，别把预算耗在一条
        // 走不通的源上。
        let deadline = Date().addingTimeInterval(22)
        guard isCurrent(stamp) else { return nil }

        // 目录查询（Apple Music 专辑搜索 / 歌曲搜索 / 专辑详情）单独压一个上限：
        // 它一道超时就把后面本地 Fill 的时间也吃掉，用户看到的就是"什么都没有"。
        // 12 秒给 Apple Music 的几步串行请求留出余量；Fill 还有约 10 秒可跑。
        let resolved = await resolveSources(
            title: title,
            artist: artist,
            album: album,
            deadline: min(deadline, Date().addingTimeInterval(12))
        )
        guard isCurrent(stamp), !Task.isCancelled else { return nil }

        let attempts = candidates(
            for: aspect,
            from: resolved,
            hasCover: still != nil
        )

        for candidate in attempts {
            guard isCurrent(stamp), !Task.isCancelled, Date() < deadline else { return nil }

            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("eevee-lockart-\(UUID().uuidString).mp4")

            do {
                switch candidate {
                case .remote(let asset):
                    try await download(asset, to: temporary, deadline: deadline)
                case .fill:
                    guard let still else { continue }
                    guard Date() < deadline else { return nil }
                    try await FillArtworkRenderer.render(
                        cover: still,
                        aspect: aspect,
                        to: temporary
                    )
                }

                guard isCurrent(stamp), !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: temporary)
                    return nil
                }

                let ready = try await AnimatedArtworkVideo.cropped(
                    temporary,
                    to: aspect,
                    alwaysExport: candidate.alwaysExport
                )
                if ready != temporary {
                    try? FileManager.default.removeItem(at: temporary)
                }

                guard isCurrent(stamp), !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: ready)
                    return nil
                }

                let stored = try AnimatedArtworkCache.store(ready, key: key)
                await writePreview(of: stored, key: key, size: aspect.renderSize)
                AnimatedArtworkCache.trimIfNeeded()

                let bytes = (try? stored.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                writeDebugLog(
                    "[\(LockScreenArtwork.logTag)] \(candidate.label) ready —"
                        + " \(aspect.rawValue), \(bytes / 1024) KB,"
                        + " asked \(Int(size.width))x\(Int(size.height)), \"\(title)\""
                )
                return stored
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                writeDebugLog(
                    "[\(LockScreenArtwork.logTag)] \(candidate.label) failed —"
                        + " \(aspect.rawValue), \(error.localizedDescription)"
                )
            }
        }

        reportMissOnce(key: key, title: title)
        return nil
    }

    private func download(
        _ asset: AnimatedArtworkAsset,
        to destination: URL,
        deadline: Date
    ) async throws {
        guard Date() < deadline else {
            throw HLSVideoDownloader.Failure(reason: "timed out")
        }
        if asset.isHLS {
            try await HLSVideoDownloader.download(
                playlist: asset.videoURL,
                to: destination,
                session: session,
                targetWidth: 960,
                deadline: deadline
            )
            return
        }

        let (temporary, response) = try await session.download(from: asset.videoURL)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw HLSVideoDownloader.Failure(
                reason: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            )
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private func writePreview(of url: URL, key: String, size: CGSize) async {
        guard let image = try? await AnimatedArtworkVideo.previewImage(of: url, size: size) else {
            return
        }
        AnimatedArtworkCache.storePreview(image, key: key)
    }

    // MARK: - 封面静帧

    private var stills: [String: UIImage] = [:]
    private var preparingStills = Set<String>()
    private var stillAttempts: [String: Int] = [:]
    private var reportedNoStill = Set<String>()

    private func stillKey(title: String, artist: String) -> String {
        "\(title)|\(artist)"
    }

    func cachedStill(title: String, artist: String) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        return stills[stillKey(title: title, artist: artist)]
    }

    func keepStill(_ image: UIImage, title: String, artist: String) {
        let key = stillKey(title: title, artist: artist)
        lock.lock()
        if stills.count >= 6, let oldest = stills.keys.first {
            stills[oldest] = nil
        }
        stills[key] = image
        preparingStills.remove(key)
        stillAttempts[key] = nil
        lock.unlock()
    }

    /// `MPMediaItemPropertyArtwork` 拿不到图时，从 track metadata 的封面地址补一张。
    ///
    /// 为什么需要：iOS 27 上 Spotify 的 now-playing 字典不一定带 `MPMediaItemPropertyArtwork`，
    /// 而动画键没有预览图就会被系统画成灰色占位图。metadata 里有 `image_url`，封面是公开
    /// CDN 地址，抓一张 640 的图足够裁预览。
    func prepareStill(title: String, artist: String) {
        let key = stillKey(title: title, artist: artist)

        lock.lock()
        if stills[key] != nil || preparingStills.contains(key) {
            lock.unlock()
            return
        }
        let attempts = (stillAttempts[key] ?? 0) + 1
        stillAttempts[key] = attempts
        // now-playing 的写入很密；给 metadata 十几拍时间就绪，别在第一秒就放弃。
        if attempts > 12 {
            lock.unlock()
            return
        }
        preparingStills.insert(key)
        lock.unlock()

        Task { [weak self] in
            guard let self else { return }
            guard let url = await self.metadataCoverURL(title: title, artist: artist) else {
                self.finishStillAttempt(key: key, title: title)
                return
            }
            var image: UIImage?
            // 先试 640 档、失败再回 metadata 给的那档：300 的图铺满锁屏要放大三倍。
            for candidate in Self.coverCandidates(url) {
                guard let (data, response) = try? await self.session.data(from: candidate),
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let loaded = UIImage(data: data) else {
                    continue
                }
                image = loaded
                break
            }
            guard let image else {
                self.finishStillAttempt(key: key, title: title)
                return
            }

            self.keepStill(image, title: title, artist: artist)
            writeDebugLog(
                "[\(LockScreenArtwork.logTag)] cover still from track metadata —"
                    + " \(Int(image.size.width))x\(Int(image.size.height)), \"\(title)\""
            )
            // Spotify 只按自己的节奏写 now-playing；补一次，下一次 hook 就能把动画键放进去。
            DispatchQueue.main.async {
                LockScreenArtworkInjector.refreshNowPlayingInfo(title: title, artist: artist)
            }
        }
    }

    /// 封面候选：大图档优先，原件兜底。两张都是同一个哈希，只有前缀不同。
    private static func coverCandidates(_ url: URL) -> [URL] {
        guard let large = LockScreenArtwork.largeCoverURL(url) else { return [url] }
        return [large, url]
    }

    private func finishStillAttempt(key: String, title: String) {
        lock.lock()
        preparingStills.remove(key)
        let first = reportedNoStill.insert(key).inserted
        if reportedNoStill.count > 32 {
            reportedNoStill.removeAll()
        }
        lock.unlock()

        guard first else { return }
        writeDebugLog(
            "[\(LockScreenArtwork.logTag)] no cover still for \"\(title)\" —"
                + " the animated keys stay out; the lock screen keeps Spotify's own artwork"
        )
    }

    private func metadataCoverURL(title: String, artist: String) async -> URL? {
        await MainActor.run { () -> URL? in
            guard let track = statefulPlayer?.currentTrack()
                ?? nowPlayingScrollViewController?.loadedTrack else {
                return nil
            }
            let metadata = track.metadata()
            let currentTitle = metadata["title"] ?? ""
            guard LockScreenArtwork.looksLikeSameSong(currentTitle, title) else { return nil }
            return LyricsArtworkResolver.artworkURL(for: track)
        }
    }

    // MARK: - 选源

    private func candidates(
        for aspect: LockScreenArtwork.Aspect,
        from sources: Sources,
        hasCover: Bool
    ) -> [Candidate] {
        var result: [Candidate] = []
        if let canvas = sources.canvas {
            result.append(.remote(canvas))
        }
        if let asset = sources.apple.asset(for: aspect) {
            result.append(.remote(asset))
        }
        if hasCover, LockScreenArtwork.wantsFill {
            result.append(.fill)
        }
        return result
    }

    private func resolveSources(
        title: String,
        artist: String,
        album: String,
        deadline: Date
    ) async -> Sources {
        let key = "\(title)|\(artist)|\(album)"

        lock.lock()
        if let cached = sources[key] {
            if let retryAfter = cached.retryAfter, Date() >= retryAfter {
                sources[key] = nil
            } else {
                lock.unlock()
                return cached.value
            }
        }
        if let task = resolving[key] {
            lock.unlock()
            return await task.value
        }
        let task = Task<Sources, Never> { [weak self] in
            guard let self else { return .empty }
            return await self.performResolve(
                title: title,
                artist: artist,
                album: album,
                deadline: deadline
            )
        }
        resolving[key] = task
        lock.unlock()

        let value = await task.value

        // 空结果只当"临时失败"缓存：两分钟内不再问，之后允许重试。
        // 真找到了（Canvas / Apple Music 任一画幅）就按歌永久缓存。
        let found = value.canvas != nil
            || value.apple.square != nil
            || value.apple.tall != nil
        lock.lock()
        resolving[key] = nil
        sources[key] = CachedSources(
            value: value,
            retryAfter: found
                ? nil
                : Date().addingTimeInterval(Self.transientMissRetryInterval)
        )
        if sources.count > 48 {
            sources.removeAll()
        }
        lock.unlock()

        if !found {
            writeDebugLog(
                "[\(LockScreenArtwork.logTag)] sources miss for \"\(title)\" —"
                    + " retrying in \(Int(Self.transientMissRetryInterval))s"
            )
        }

        return value
    }

    private func performResolve(
        title: String,
        artist: String,
        album: String,
        deadline: Date
    ) async -> Sources {
        var canvas: AnimatedArtworkAsset?
        var canvasTrackURI: String?

        if LockScreenArtwork.wantsCanvas {
            if let snapshot = await currentTrackSnapshot() {
                if matches(metadata: snapshot.metadata, title: title, artist: artist) {
                    canvas = CanvasArtworkSource.asset(metadata: snapshot.metadata)
                    // metadata 没给 `canvas.url` 时再问一次 canvaz-cache（Taurus 那条路）。
                    if canvas == nil { canvasTrackURI = snapshot.uri }
                }
            } else {
                reportNoMetadataOnce()
            }
        }

        if canvas == nil, let uri = canvasTrackURI, Date() < deadline {
            canvas = await SpotifyCanvasCache.asset(
                trackURI: uri,
                session: session,
                deadline: deadline
            )
        }

        let apple = await AppleMusicArtworkSource.assets(
            title: title,
            artist: artist,
            album: album,
            session: session,
            deadline: deadline
        )

        // 这一首三条源各找到了什么，一行看完 —— 落在 Fill 上时就是"为什么看起来只有封面"。
        writeDebugLog(
            "[\(LockScreenArtwork.logTag)] sources — canvas \(canvas == nil ? "none" : "yes"),"
                + " apple square \(apple.square == nil ? "none" : "yes")"
                + " / tall \(apple.tall == nil ? "none" : "yes"), \"\(title)\""
        )
        return Sources(canvas: canvas, apple: apple)
    }

    /// 播放器当前这一首的元数据 + 曲目 URI，**在同一次主线程快照里取**。
    ///
    /// 分开取会串歌：metadata 还是 A，曲目 URI 已经变成 B，canvaz-cache 就会拿 B 的
    /// canvas 去配 A 的封面。URI 不是 `spotify:track:`（播客/本地文件）时留 nil，
    /// metadata 那条路照样可用。
    private struct TrackSnapshot {
        let metadata: [String: String]
        let uri: String?
    }

    private func currentTrackSnapshot() async -> TrackSnapshot? {
        await MainActor.run { () -> TrackSnapshot? in
            guard let track = statefulPlayer?.currentTrack()
                ?? nowPlayingScrollViewController?.loadedTrack else {
                return nil
            }
            let identifier = track.trackIdentifier
            return TrackSnapshot(
                metadata: track.metadata(),
                uri: identifier.hasPrefix("spotify:track:") ? identifier : nil
            )
        }
    }

    /// 系统来要素材时，歌可能已经换了 —— 换过就不要再拿新歌的 Canvas 去配旧封面。
    private func matches(metadata: [String: String], title: String, artist: String) -> Bool {
        let snapshotTitle = metadata["title"] ?? ""
        let snapshotArtist = metadata["artist_name"] ?? ""
        guard LockScreenArtwork.looksLikeSameSong(snapshotTitle, title) else { return false }
        guard !artist.isEmpty, !snapshotArtist.isEmpty else { return true }
        return LockScreenArtwork.looksLikeSameSong(snapshotArtist, artist)
    }

    private func reportNoMetadataOnce() {
        lock.lock()
        let first = !reportedNoMetadata
        reportedNoMetadata = true
        lock.unlock()

        guard first else { return }
        writeDebugLog(
            "[\(LockScreenArtwork.logTag)] Canvas skipped — the player exposes no track metadata;"
                + " Apple Music and the local loop still apply"
        )
    }

    private func reportMissOnce(key: String, title: String) {
        lock.lock()
        if reportedMisses.count > 64 {
            reportedMisses.removeAll()
        }
        let first = reportedMisses.insert(key).inserted
        lock.unlock()

        guard first else { return }
        writeDebugLog(
            "[\(LockScreenArtwork.logTag)] no clip for \"\(title)\" —"
                + " the lock screen keeps the still cover"
        )
    }
}
