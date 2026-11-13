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
    private var sources: [String: Sources] = [:]
    private var resolving: [String: Task<Sources, Never>] = [:]
    private var running: [String: Task<URL?, Never>] = [:]
    private var runningTokens: [String: UUID] = [:]
    private var reportedMisses = Set<String>()
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

    /// 预览图：有首帧缓存就裁成系统要的尺寸，没有就把静态封面按画幅裁一张。
    ///
    /// 这条路径**不做网络请求**：系统在视频还没到手时显示它，慢一拍就会先闪静态封面，
    /// 等得久了甚至直接退回静态封面、不再来要视频。所以宁可先用封面顶着。
    func previewImage(
        title: String,
        artist: String,
        duration: Double,
        aspect: LockScreenArtwork.Aspect,
        size: CGSize,
        cover: MPMediaItemArtwork?
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
        guard let cover,
              let still = cover.image(at: CGSize(width: 900, height: 900)) else {
            return nil
        }
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
        cover: MPMediaItemArtwork?
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
                cover: cover
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
        cover: MPMediaItemArtwork?
    ) async -> URL? {
        // 系统给视频 handler 的预算约 30 秒；整条"目录查询 + 下载 + 转码"压在 22 秒内，
        // 剩下的时间给本地 Fill 和转码。每个 await 之后都再看一眼，别把预算耗在一条
        // 走不通的源上。
        let deadline = Date().addingTimeInterval(22)
        guard isCurrent(stamp) else { return nil }

        let resolved = await resolveSources(
            title: title,
            artist: artist,
            album: album,
            deadline: deadline
        )
        guard isCurrent(stamp), !Task.isCancelled else { return nil }

        let attempts = candidates(
            for: aspect,
            from: resolved,
            hasCover: cover != nil
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
                    guard let cover,
                          let still = cover.image(at: CGSize(width: 900, height: 900)) else {
                        continue
                    }
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
            lock.unlock()
            return cached
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

        lock.lock()
        resolving[key] = nil
        sources[key] = value
        if sources.count > 48 {
            sources.removeAll()
        }
        lock.unlock()

        return value
    }

    private func performResolve(
        title: String,
        artist: String,
        album: String,
        deadline: Date
    ) async -> Sources {
        var canvas: AnimatedArtworkAsset?

        if LockScreenArtwork.wantsCanvas {
            if let metadata = await currentMetadata() {
                if matches(metadata: metadata, title: title, artist: artist) {
                    canvas = CanvasArtworkSource.asset(metadata: metadata)
                }
            } else {
                reportNoMetadataOnce()
            }
        }

        let apple = await AppleMusicArtworkSource.assets(
            title: title,
            artist: artist,
            album: album,
            session: session,
            deadline: deadline
        )

        return Sources(canvas: canvas, apple: apple)
    }

    private func currentMetadata() async -> [String: String]? {
        await MainActor.run { () -> [String: String]? in
            guard let track = statefulPlayer?.currentTrack()
                ?? nowPlayingScrollViewController?.loadedTrack else {
                return nil
            }
            return track.metadata()
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
