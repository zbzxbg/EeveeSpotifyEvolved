import AVFoundation
import Foundation
import UIKit

/// 艺人页的**动效头图**（Apple Music 的 `motionArtist*`）。
///
/// ## 素材从哪来
///
/// Apple 的目录接口里，**艺人**和专辑一样带 `editorialVideo`，只是档位名不同（2026-11-27
/// 用 Michael Jackson 的 id 32940 实测）：
///
/// ```
/// GET /v1/catalog/us/artists/32940?extend=editorialVideo
/// editorialVideo:
///   motionArtistSquare1x1       ← 我们优先用它：页头是竖高的，方档裁得最少
///   motionArtistWide16x9        ← AM 自己的页头接近 16:9，它用这档
///   motionArtistFullscreen16x9
/// ```
///
/// 每一档都是 `{ previewFrame, video }`，`video` 是一条 HLS 地址（**结尾没有 `.m3u8`**，
/// 别拿扩展名判 HLS）。`previewFrame` 里还带 `bgColor` / `textColor1…4` —— 那是 Apple
/// 按可读性算好的配色，将来做"浅底黑字"应该用它，而不是自己压饱和度再猜阈值。
///
/// ## 为什么自己拉一份，不复用锁屏那条
///
/// 锁屏那条（`LockScreenArtworkResolver`）按**曲目**解析、产出"系统要的 3:4 短片"，
/// 中间还隔着 `MPMediaItemAnimatedArtwork`。艺人页要的是 16:9、进页面就播、跟页面
/// 一起停的东西；共用的只有最底下的 `HLSVideoDownloader`。
///
/// ## 纪律
///
/// · **只挂艺人页**（专辑 / 歌单页的封面是卡片，头图播动图会喧宾夺主）；
/// · **静音、循环、不碰 `AVAudioSession`** —— 碰了会把用户正在听的歌抢走；
/// · **一个艺人一份**：解析一次、下一次同艺人直接命中缓存；离开页面暂停（不解码）；
/// · 失败**不重试**：目录里没有就是没有，静默留在静态头图上；
/// · **没有独立开关**：它跟着艺人页那套重排一起走（关掉艺人页外观就没有头图，自然也没有动图）。
enum ArtistMotionArtwork {

    static let logTag = "ArtistMotion"

    private static let apiBase = "https://amp-api.music.apple.com"
    private static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        + " (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    private static let resolveDeadline: TimeInterval = 20

    // MARK: - 状态
    //
    // 全部只在主线程读写：`attach` / `detach` 是页头重排时调的，解析结果由 Task 回到
    // MainActor 再写。

    private static var nameBeingResolved: String?
    private static var readyVideo: URL?
    private static var failedNames: Set<String> = []
    private static var resolveTask: Task<Void, Never>?

    private static var playerView: ArtistMotionLayerView?
    private static var player: AVPlayer?
    private static var loopObserver: NSObjectProtocol?

    private struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    // MARK: - 对外入口

    /// 页头每拍调一次：挂上、摆正、按需开始解析 / 播放。
    ///
    /// - Parameters:
    ///   - name: 当前艺人名（`EntityPageHeaderManager.currentArtistName`）。
    ///   - host: 页头宿主 —— 也就是我们那张满幅照片（`sharpHero`）的父视图。
    ///   - frame: 动图在 `host` 里的框，与照片**完全一致**（它盖在同一位置）。
    ///   - maskStart/maskEnd: 照片下沿化开的两个落点；动图要用同一条渐变，否则两边
    ///     的接缝对不上。
    static func attach(
        name: String,
        host: UIView,
        frame: CGRect,
        maskStart: CGFloat,
        maskEnd: CGFloat
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if nameBeingResolved != trimmed {
            // 换人了：先把上一位的拆掉，再解析这一位（同一艺人只解析一次）。
            teardownPlayer()
            readyVideo = nil
            nameBeingResolved = trimmed
            guard !failedNames.contains(trimmed) else { return }
            startResolve(name: trimmed)
        }

        guard let video = readyVideo else { return }
        guard let view = ensureView(in: host, frame: frame, video: video) else { return }
        if view.frame != frame { view.frame = frame }
        view.applyMask(solidUntil: maskStart, goneAt: maskEnd)
        if let player, player.timeControlStatus != .playing, view.window != nil {
            player.play()
        }
    }

    /// 页面离开（不在屏上）时调：停止解码，但**保留解析结果**，同一艺人回来秒开。
    static func pause() {
        player?.pause()
    }

    /// 真的离开实体页（`EntityPageAppearance` 收尾时调）：连视图一起摘掉。
    static func detach() {
        teardownPlayer()
        readyVideo = nil
        nameBeingResolved = nil
    }

    // MARK: - 播放层

    private static func ensureView(
        in host: UIView,
        frame: CGRect,
        video: URL
    ) -> ArtistMotionLayerView? {
        if let playerView, playerView.superview === host, player != nil {
            return playerView
        }
        teardownPlayer()

        let view = ArtistMotionLayerView(frame: frame)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        // 照片在 `host` 的 index 0（见 `ensureHero`）。动图插在它**上面**、页头其它内容
        // 下面 —— 标题 / 按钮照旧压在动图上，层序与照片那一版一致。
        host.insertSubview(view, at: 1)
        playerView = view

        let item = AVPlayerItem(url: video)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        self.player = player

        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
        }
        loopObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { _ in
            player.seek(to: .zero)
            player.play()
        }
        player.play()
        writeDebugLog("[\(logTag)] playing \(video.lastPathComponent) in \(type(of: host))")
        return view
    }

    private static func teardownPlayer() {
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
            loopObserver = nil
        }
        player?.pause()
        player = nil
        playerView?.removeFromSuperview()
        playerView = nil
    }

    // MARK: - 解析

    private static func startResolve(name: String) {
        resolveTask?.cancel()
        resolveTask = Task.detached(priority: .utility) {
            do {
                let deadline = Date().addingTimeInterval(resolveDeadline)
                guard let token = try? AppleMusicOfficialTtmlLyricsRepository.webDeveloperToken(),
                      !token.isEmpty else {
                    throw Failure(reason: "no Apple Music developer token")
                }
                let storefront = Locale.current.region?.identifier.lowercased() ?? "us"
                guard let artistID = await artistID(
                    name: name,
                    storefront: storefront,
                    token: token
                ) else {
                    throw Failure(reason: "no catalog match")
                }
                guard let remote = await editorialVideo(
                    artistID: artistID,
                    storefront: storefront,
                    token: token,
                    deadline: deadline
                ) else {
                    throw Failure(reason: "artist \(artistID) has no motionArtist video")
                }
                let local = try await cachedFile(
                    for: remote,
                    key: "\(storefront)-\(artistID)-motion",
                    deadline: deadline
                )
                await MainActor.run {
                    guard nameBeingResolved == name else { return }
                    readyVideo = local
                    resolveTask = nil
                    writeDebugLog(
                        "[\(logTag)] ready — artist \(artistID),"
                            + " \(max(1, byteSize(local) / 1024)) KB, \"\(name)\""
                    )
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    guard nameBeingResolved == name else { return }
                    failedNames.insert(name)
                    // 只记名字做"别再试了"，别让它无限长（一个人刷几百个艺人页也不涨）。
                    if failedNames.count > 64 { failedNames.removeAll() }
                    resolveTask = nil
                    writeDebugLog("[\(logTag)] skipped \"\(name)\" — \(message)")
                }
            }
        }
    }

    private static func artistID(
        name: String,
        storefront: String,
        token: String
    ) async -> String? {
        var components = URLComponents(string: "\(apiBase)/v1/catalog/\(storefront)/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: name),
            URLQueryItem(name: "types", value: "artists"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = components?.url,
              let root = await json(url, token: token),
              let results = root["results"] as? [String: Any],
              let artists = results["artists"] as? [String: Any],
              let items = artists["data"] as? [[String: Any]] else { return nil }

        // 只认**归一化后名字相等**的那一条：`types=artists` 的结果里常有同名翻唱号 /
        // 合作艺人，取第一条就会把别人的头图放到这一页上。
        let wanted = LockScreenArtwork.normalized(name)
        for item in items {
            guard let attributes = item["attributes"] as? [String: Any],
                  let found = attributes["name"] as? String,
                  let id = item["id"] as? String,
                  LockScreenArtwork.normalized(found) == wanted else { continue }
            return id
        }
        return nil
    }

    private static func editorialVideo(
        artistID: String,
        storefront: String,
        token: String,
        deadline: Date
    ) async -> URL? {
        guard Date() < deadline,
              let url = URL(
                  string: "\(apiBase)/v1/catalog/\(storefront)/artists/\(artistID)?extend=editorialVideo"
              ),
              let root = await json(url, token: token),
              let items = root["data"] as? [[String: Any]],
              let attributes = items.first?["attributes"] as? [String: Any],
              let editorial = attributes["editorialVideo"] as? [String: Any] else {
            return nil
        }

        // **方档优先**：我们的页头是竖高的（铺满整个宿主），16:9 的素材铺进去只会剩下
        // 中间一条竖缝。AM 的页头本身接近 16:9，所以它用宽档才好看 —— 我们这里反过来。
        // 方档裁得最少；方档缺失才退到宽档 / 满屏档。
        for key in ["motionArtistSquare1x1", "motionArtistWide16x9", "motionArtistFullscreen16x9"] {
            guard let variant = editorial[key] as? [String: Any],
                  let video = variant["video"] as? String,
                  let url = URL(string: video) else { continue }
            return url
        }
        return nil
    }

    private static func json(_ url: URL, token: String) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.apple.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return object as? [String: Any]
    }

    // MARK: - 缓存

    /// 同一艺人只下一次。落在 Caches 里，HLS 由 `HLSVideoDownloader` 拼成 mp4。
    private static func cachedFile(
        for remote: URL,
        key: String,
        deadline: Date
    ) async throws -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EeveeArtistMotion", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory
            .appendingPathComponent(FNV1a.hex(key))
            .appendingPathExtension("mp4")
        if byteSize(destination) > 0 { return destination }

        // 1280 宽够铺 414pt 的页头（3x 屏）；再宽只是多占内存。
        try await HLSVideoDownloader.download(
            playlist: remote,
            to: destination,
            session: URLSession.shared,
            targetWidth: 1280,
            deadline: deadline
        )
        return destination
    }

    private static func byteSize(_ url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.intValue
    }
}

/// 只干一件事：把自己整个变成一层 `AVPlayerLayer`，并保住下沿化开的 mask。
final class ArtistMotionLayerView: UIView {

    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    private let dissolve = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        dissolve.colors = [UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
        dissolve.startPoint = CGPoint(x: 0.5, y: 0)
        dissolve.endPoint = CGPoint(x: 0.5, y: 1)
        layer.mask = dissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func applyMask(solidUntil: CGFloat, goneAt: CGFloat) {
        let height = max(1, bounds.height)
        let from = min(1, max(0, solidUntil / height))
        let to = min(1, max(from, goneAt / height))
        dissolve.frame = bounds
        dissolve.locations = [0, NSNumber(value: Double(from)), NSNumber(value: Double(to))]
    }
}
