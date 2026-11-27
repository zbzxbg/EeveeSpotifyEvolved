import AVFoundation
import Foundation
import UIKit

/// 听歌页（`NowPlayingIOS27` 那一版满幅封面）上的**动效封面**。
///
/// ## 素材
///
/// 只走 Apple Music 专辑的 `editorialVideo`（`motionDetailSquare` / `motionSquareVideo1x1`，
/// 见 `AppleMusicArtworkSource`）。**不用 Canvas**：播放页那一格有时候摆的正是 Canvas 帧 /
/// 艺人图 —— 那正是 `NowPlayingIOS27` 宁可用 `metadata["image_url"]` 也不用壳里那张图的原因。
/// 封面这一格必须是**这张专辑**，所以只认按"曲名 + 艺人 + 专辑 + 时长"四道校验挑出来的那张。
///
/// 缓存与锁屏**同一个 key**（`AnimatedArtworkCache` 的 `v2` 配方）：锁屏已经为这一首做过
/// 短片时，这里直接命中同一个文件，一个请求都不发。
///
/// ## 为什么贴着封面当**子视图**，而不是另起一层兄弟视图
///
/// 封面自己的 frame / 圆角 / 裁剪 / 下沿淡出 mask / 音频律动的 `layer` 仿射变换
/// **全在那一张 `UIImageView` 身上**。当子视图就自动继承这五样；另起一层兄弟视图就要把
/// 五样各写一遍，而且每一样都会比封面慢一拍（缩略图那一向最明显）。
///
/// ## 纪律
///
/// · 静音、循环、**不碰 `AVAudioSession`** —— 碰了会把用户正在听的歌抢走；
/// · 页内歌词（64pt 缩略图）与离开页面时**暂停**，不解码；回来以同一份文件秒开；
/// · 一首一份：换歌才换素材，其余每拍只是一次字符串比较 + 一次 `play()` 检查；
/// · 失败**不重试**（记进 `failedKeys`）：目录里没有就是没有，静默留在静态封面上。
enum NowPlayingMotionArtwork {

    static let logTag = "MotionCover"

    /// 解析整首（目录查询 + 下载）的预算。后台跑，不压 UI。
    private static let resolveDeadline: TimeInterval = 18
    /// 下载宽度：封面铺满整页宽（390–430pt），3x 屏下 1080 足够。
    private static let targetWidth: CGFloat = 1080

    // MARK: - 当前曲目

    struct Track: Equatable, Sendable {
        let identifier: String
        let title: String
        let artist: String
        let album: String
        let duration: Double

        /// 只有 id 的本地文件 / 播客拿不到匹配素材 —— 没曲名就别去问目录。
        var isUsable: Bool {
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// **与锁屏同一条 key**（`AnimatedArtworkCache`，v2 配方）：两处命中同一份文件。
        var cacheKey: String {
            AnimatedArtworkCache.key(
                title: title,
                artist: artist,
                duration: duration,
                aspect: .square
            )
        }
    }

    /// 这一拍播放器上是谁。
    ///
    /// 四样都从 `SPTPlayerTrack` 读（与歌词链路同一处口径）：`metadata["album_title"]` 是
    /// 专辑，`trackDurationMilliseconds` 把 `duration` / `duration_ms` 各种写法都归一化成了毫秒。
    static func currentTrack() -> Track? {
        guard let track = statefulPlayer?.currentTrack()
            ?? nowPlayingScrollViewController?.loadedTrack else { return nil }

        let metadata = track.metadata()
        let title = track.trackTitle().trimmingCharacters(in: .whitespacesAndNewlines)
        // `artistTitle()` 在 9.3 上不存在（见 `SPTPlayerTrack+Extension` 的说明）。
        let artist = (EeveeSpotify.hookTarget == .lastAvailableiOS14
            ? track.artistTitle()
            : track.artistName()).trimmingCharacters(in: .whitespacesAndNewlines)
        let album = (metadata["album_title"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Track(
            identifier: track.trackIdentifier,
            title: title,
            artist: artist,
            album: album,
            duration: Double(track.trackDurationMilliseconds ?? 0) / 1000
        )
    }

    // MARK: - 状态
    //
    // 与 `EntityMotionArtwork` 同一套：只在主线程读写，解析结果回 MainActor 再写。

    /// 正在服务的那一首（缓存 key）。换歌才变。
    private static var servingKey = ""
    private static var readyFile: URL?
    private static var failedKeys: Set<String> = []
    private static var resolveTask: Task<Void, Never>?

    private static var playerView: MotionArtworkPlayerView?
    private static var player: AVPlayer?
    private static var loopObserver: NSObjectProtocol?
    private static var didLogPlay = false
    /// 只装一次（App 生命周期级的观察者），见 `observeBackgroundOnce`。
    private static var didObserveBackground = false

    private struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    // MARK: - 对外入口

    /// 封面每拍调一次：换歌时换素材，其余时候保证"该播的还在播"。
    ///
    /// - Parameters:
    ///   - artwork: 我们画的那张满幅封面（`NowPlayingIOS27.artworkView`）。
    ///   - track: 这一拍的曲目；nil（取不到播放器 / 播客）⇒ 收起。
    ///   - expanded: 是否满幅（页内歌词的 64pt 缩略图**不播**，AM 那里也是静帧）。
    static func attach(to artwork: UIImageView, track: Track?, expanded: Bool) {
        observeBackgroundOnce()
        guard let track, track.isUsable else {
            teardownPlayer()
            servingKey = ""
            readyFile = nil
            return
        }

        let key = track.cacheKey
        if key != servingKey {
            // 换歌：先停上一首，再按新 key 取（缓存命中就秒开，否则排一次后台解析）。
            teardownPlayer()
            readyFile = nil
            servingKey = key
            // `existing` 会顺手刷新 LRU 时间戳（见 `AnimatedArtworkCache`），所以**只在换歌
            // 这一下**查一次，不要每拍查。
            if let cached = AnimatedArtworkCache.existing(key: key) {
                readyFile = cached
            } else if !failedKeys.contains(key) {
                startResolve(track: track, key: key)
            }
        }

        guard expanded, let file = readyFile,
              let view = ensureView(in: artwork, file: file) else {
            // 缩略图 / 还在解析：停解码并藏起来。静态封面一直在下面，不会留洞。
            player?.pause()
            playerView?.isHidden = true
            return
        }
        view.isHidden = false
        if let player, player.timeControlStatus != .playing, artwork.window != nil {
            player.play()
        }
    }

    /// 页面离开（或在屏但让位给播客）：停止解码，但**保留**"这一首已经备好"的状态。
    static func pause() {
        player?.pause()
    }

    /// 真的离开听歌页（`NowPlayingIOS27` 收尾时调）：连视图与素材一起摘掉。
    static func detach() {
        teardownPlayer()
        readyFile = nil
        servingKey = ""
    }

    /// 进后台就停解码。**不留"回前台要恢复"的记号** —— 回来之后那 0.3s 的复查节拍会再调
    /// `attach`，那里 `timeControlStatus != .playing` 自己会接上。
    private static func observeBackgroundOnce() {
        guard !didObserveBackground else { return }
        didObserveBackground = true
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            player?.pause()
        }
    }

    // MARK: - 播放层

    private static func ensureView(
        in artwork: UIImageView,
        file: URL
    ) -> MotionArtworkPlayerView? {
        if let playerView, playerView.superview === artwork, player != nil {
            if playerView.frame != artwork.bounds { playerView.frame = artwork.bounds }
            return playerView
        }
        teardownPlayer()

        let view = MotionArtworkPlayerView(frame: artwork.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "eevee-motion-artwork"
        // **子视图**（理由见文件头）：圆角 / 裁剪 / 下沿 mask / 律动变换都会自动套上。
        artwork.addSubview(view)
        playerView = view

        let item = AVPlayerItem(url: file)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        self.player = player

        if let previous = loopObserver {
            NotificationCenter.default.removeObserver(previous)
        }
        loopObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { _ in
            player.seek(to: .zero)
            player.play()
        }
        // 不在屏上就先不播（下一拍 `attach` 的 `timeControlStatus` 检查会把它接上）。
        if artwork.window != nil { player.play() }
        if !didLogPlay {
            didLogPlay = true
            writeDebugLog(
                "[\(logTag)] attached \(file.lastPathComponent)"
                    + " (\(max(1, byteSize(file) / 1024)) KB) behind the artwork"
            )
        }
        return view
    }

    private static func teardownPlayer() {
        // 绑到新名字：`if let loopObserver` 会在分支里遮住这个静态属性，
        // 下面那句赋值就成了给 let 赋值。
        if let observer = loopObserver {
            NotificationCenter.default.removeObserver(observer)
            loopObserver = nil
        }
        player?.pause()
        player = nil
        playerView?.removeFromSuperview()
        playerView = nil
        didLogPlay = false
    }

    // MARK: - 解析

    private static func startResolve(track: Track, key: String) {
        resolveTask?.cancel()
        resolveTask = Task.detached(priority: .utility) {
            let deadline = Date().addingTimeInterval(resolveDeadline)
            do {
                guard Date() < deadline else { throw Failure(reason: "over budget") }
                let assets = await AppleMusicArtworkSource.assets(
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    duration: track.duration,
                    session: URLSession.shared,
                    deadline: deadline
                )
                guard let asset = assets.square ?? assets.tall else {
                    throw Failure(reason: "no Apple Music editorial video")
                }
                let local = try await download(asset: asset, key: key, deadline: deadline)
                let size = byteSize(local)
                await MainActor.run {
                    // 换歌了：这份结果已经用不上了（`servingKey` 是主线程写、这里也是主线程读）。
                    guard servingKey == key else { return }
                    readyFile = local
                    resolveTask = nil
                    writeDebugLog(
                        "[\(logTag)] ready — \"\(track.title)\" by \"\(track.artist)\""
                            + " (id \(track.identifier)), \(max(1, size / 1024)) KB"
                    )
                    // 让这一拍之外的那 0.3s 复查节拍**立刻**把短片画上去（不用等下一拍）。
                    NowPlayingIOS27.reapply()
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    guard servingKey == key else { return }
                    failedKeys.insert(key)
                    // 只记"别再试了"，别让它无限长（连听几百首也不会涨）。
                    if failedKeys.count > 64 { failedKeys.removeAll() }
                    resolveTask = nil
                    writeDebugLog("[\(logTag)] skipped \"\(track.title)\" — \(message)")
                }
            }
        }
    }

    /// 下载 + 落进**与锁屏同一个**缓存。
    private static func download(
        asset: AnimatedArtworkAsset,
        key: String,
        deadline: Date
    ) async throws -> URL {
        if let existing = AnimatedArtworkCache.existing(key: key) { return existing }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("eevee-motion-\(UUID().uuidString).mp4")
        if asset.isHLS {
            try await HLSVideoDownloader.download(
                playlist: asset.videoURL,
                to: temporary,
                session: URLSession.shared,
                targetWidth: targetWidth,
                deadline: deadline
            )
        } else {
            let (data, response) = try await URLSession.shared.data(from: asset.videoURL)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw Failure(reason: "HTTP \(http.statusCode)")
            }
            try data.write(to: temporary, options: .atomic)
        }

        let stored = try AnimatedArtworkCache.store(temporary, key: key)
        AnimatedArtworkCache.trimIfNeeded()
        return stored
    }

    private static func byteSize(_ url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.intValue
    }
}

/// 只干一件事：把自己整个变成一层 `AVPlayerLayer`（圆角 / 裁剪 / 下沿用**父视图**那一套）。
final class MotionArtworkPlayerView: UIView {

    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
