import AVFoundation
import Foundation
import UIKit

/// 实体页（**艺人 / 专辑**）的**动效头图** —— Apple Music 的 `motionArtist*` / `motionDetail*`。
///
/// ## 素材从哪来
///
/// Apple 的目录接口里，**艺人**和专辑一样带 `editorialVideo`，只是档位名不同
/// （MJ 的 `32940`、Thriller 的 `269572838` 两条地址上就能看到这两套字段）：
///
/// ```
/// 艺人  GET /v1/catalog/us/artists/32940?extend=editorialVideo
///   motionArtistSquare1x1       ← 我们优先用它：页头是竖高的，方档裁得最少
///   motionArtistWide16x9        ← AM 自己的页头接近 16:9，它用这档
///   motionArtistFullscreen16x9
///
/// 专辑  GET /v1/catalog/us/albums/269572838?extend=editorialVideo
///   motionDetailSquare          ← 方档：我们的页头宽高比 ≈ 1:1.15，方档只切掉两侧一点点
///   motionSquareVideo1x1
///   motionDetailTall            ← 3:4，切得更多，只当兜底
///   motionTallVideo3x4
/// ```
///
/// 每一档都是 `{ previewFrame, video }`，`video` 是一条 HLS 地址（**结尾没有 `.m3u8`**，
/// 别拿扩展名判 HLS）。`previewFrame` 里还带 `bgColor` / `textColor1…4` —— 那是 Apple
/// 按可读性算好的配色，将来做"浅底黑字"应该用它，而不是自己压饱和度再猜阈值。
///
/// ## 两条解析路，匹配判据不一样
///
/// · **艺人**：`/search?types=artists` → 名字**归一化后严格相等** → 再查一次详情。
///   （同名翻唱号很多，取第一条就会把别人的头图放上来。）
/// · **专辑**：`/search?types=albums` → 结果的 `editorialVideo` 直接可用（一次请求）。
///   但必须过 `LockArtworkMatch` 那两道：**专辑名相等**（不是包含 —— `REVIVE+` ≠ `REVIVE`）
///   + **艺人至少有一个词相同**。`REVIVE` 被认成 IVE《REVIVE+》就是"只按名字、互相包含"
///   造成的，而这一页比锁屏更危险（整页头图都会是别人的）。
///
/// ## 为什么自己拉一份，不复用锁屏那条
///
/// 锁屏那条（`LockScreenArtworkResolver`）按**曲目**解析、产出"系统要的 3:4 / 1:1 短片"，
/// 中间还隔着 `MPMediaItemAnimatedArtwork`。实体页要的是"进页面就播、跟着页头一起停"的东西；
/// 共用的只有最底下的 `HLSVideoDownloader`。
///
/// ## 纪律
///
/// · **只挂艺人 / 专辑页**（歌单页的头图是拼出来的四宫格，播动图会喧宾夺主）；
/// · **静音、循环、不碰 `AVAudioSession`** —— 碰了会把用户正在听的歌抢走；
/// · **一个主体一份**：解析一次、下一次同主体直接命中缓存；离开页面暂停（不解码）；
/// · 失败**不重试**：目录里没有就是没有，静默留在静态头图上；
/// · **没有独立开关**：它跟着实体页那套重排一起走（关掉满幅页头就没有头图，自然也没有动图）。
enum EntityMotionArtwork {

    static let logTag = "EntityMotion"

    /// 这一页要动的是谁。
    enum Subject: Equatable {
        /// 艺人页：按艺人名解析（`motionArtist*`）。
        case artist(name: String)
        /// 专辑页：按「专辑名 + 艺人」解析（`motionDetail*`），两道校验都过才认。
        case album(name: String, artist: String)

        /// 解析过一次就按它记账（失败也记在这里，避免同一个页面每拍重试）。
        var identity: String {
            switch self {
            case .artist(let name):
                return "artist|" + Self.trimmed(name)
            case .album(let name, let artist):
                return "album|" + Self.trimmed(name) + "|" + Self.trimmed(artist)
            }
        }

        /// 名字还没读到的那几拍**什么都不做**（下一拍有了再解析）。
        ///
        /// 专辑这一支**要求艺人也读到**：只有专辑名时 `album()` 那两道校验只剩一道，
        /// 同名不同专辑就会串台（`REVIVE` 那次就是这道闸没守住）。宁可这一页没有动图，
        /// 也不要把别人的头图放上来 —— 专辑页每一行都会画艺人，读不到只是"还没到"。
        var isUsable: Bool {
            switch self {
            case .artist(let name):
                return !Self.trimmed(name).isEmpty
            case .album(let name, let artist):
                return !Self.trimmed(name).isEmpty && !Self.trimmed(artist).isEmpty
            }
        }

        private static func trimmed(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static let apiBase = "https://amp-api.music.apple.com"
    private static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        + " (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    private static let resolveDeadline: TimeInterval = 20

    /// 档位优先序（见文件头）。方档在前：我们的页头宽高比 1 : 1.15，方档切掉的最少。
    private static let artistKeys = [
        "motionArtistSquare1x1",
        "motionArtistWide16x9",
        "motionArtistFullscreen16x9",
    ]
    private static let albumKeys = [
        "motionDetailSquare",
        "motionSquareVideo1x1",
        "motionDetailTall",
        "motionTallVideo3x4",
    ]

    // MARK: - 状态
    //
    // 全部只在主线程读写：`attach` / `detach` 是页头重排时调的，解析结果由 Task 回到
    // MainActor 再写。

    private static var subjectBeingResolved: Subject?
    private static var readyVideo: URL?
    private static var failedSubjects: Set<String> = []
    private static var resolveTask: Task<Void, Never>?

    private static var playerView: EntityMotionLayerView?
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
    ///   - subject: 这一页要动的是谁（艺人名 / 专辑名 + 艺人）。
    ///   - host: 页头宿主 —— 也就是我们那张满幅照片（`sharpHero`）的父视图。
    ///   - photo: 那张满幅照片本身。动图**紧贴在它上面**插进去（见 `ensureView`）。
    ///   - frame: 动图在 `host` 里的框，与照片**完全一致**（它盖在同一位置）。
    ///   - maskStart/maskEnd: 照片下沿化开的两个落点；动图要用同一条渐变，否则两边
    ///     的接缝对不上。
    static func attach(
        subject: Subject,
        host: UIView,
        photo: UIView,
        frame: CGRect,
        maskStart: CGFloat,
        maskEnd: CGFloat
    ) {
        guard subject.isUsable else { return }
        let identity = subject.identity

        if subjectBeingResolved != subject {
            // 换页 / 换主体：先把上一位的拆掉，再解析这一位（同一个主体只解析一次）。
            teardownPlayer()
            readyVideo = nil
            subjectBeingResolved = subject
            guard !failedSubjects.contains(identity) else { return }
            startResolve(subject: subject)
        }

        guard let video = readyVideo else { return }
        guard let view = ensureView(in: host, above: photo, frame: frame, video: video) else {
            return
        }
        if view.frame != frame { view.frame = frame }
        view.applyMask(solidUntil: maskStart, goneAt: maskEnd)
        if let player, player.timeControlStatus != .playing, view.window != nil {
            player.play()
        }
    }

    /// 页面离开（不在屏上）时调：停止解码，但**保留解析结果**，同一主体回来秒开。
    static func pause() {
        player?.pause()
    }

    /// 真的离开实体页（`EntityPageAppearance` 收尾时调）：连视图一起摘掉。
    static func detach() {
        teardownPlayer()
        readyVideo = nil
        subjectBeingResolved = nil
    }

    // MARK: - 播放层

    private static func ensureView(
        in host: UIView,
        above photo: UIView,
        frame: CGRect,
        video: URL
    ) -> EntityMotionLayerView? {
        if let playerView, playerView.superview === host, player != nil {
            return playerView
        }
        teardownPlayer()

        let view = EntityMotionLayerView(frame: frame)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        // **紧贴照片上面**插进去：照片在宿主里的位置由 Spotify 自己决定（专辑页是头容器的
        // index 0、歌单页是 wash plane 里），按固定 index 猜就会压到别的层上或漏在它下面。
        // 贴照片上面则"最坏也只是和照片同层"：页头文字 / 按钮这些本来就在照片之上，照旧在上。
        host.insertSubview(view, aboveSubview: photo)
        playerView = view

        let item = AVPlayerItem(url: video)
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
        player.play()
        writeDebugLog("[\(logTag)] playing \(video.lastPathComponent) in \(type(of: host))")
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
    }

    // MARK: - 解析

    private static func startResolve(subject: Subject) {
        resolveTask?.cancel()
        resolveTask = Task.detached(priority: .utility) {
            do {
                let deadline = Date().addingTimeInterval(resolveDeadline)
                guard let token = try? AppleMusicOfficialTtmlLyricsRepository.webDeveloperToken(),
                      !token.isEmpty else {
                    throw Failure(reason: "no Apple Music developer token")
                }
                let storefronts = storefrontCandidates(for: subject)
                var lastReason = "no catalog match"
                for storefront in storefronts {
                    guard Date() < deadline else {
                        lastReason = "over budget"
                        break
                    }
                    guard let match = await resolve(
                        subject: subject,
                        storefront: storefront,
                        token: token,
                        deadline: deadline
                    ) else {
                        lastReason = "no catalog match in \(storefront)"
                        continue
                    }
                    let local = try await cachedFile(
                        for: match.video,
                        key: match.cacheKey,
                        deadline: deadline
                    )
                    await MainActor.run {
                        guard subjectBeingResolved == subject else { return }
                        readyVideo = local
                        resolveTask = nil
                        writeDebugLog(
                            "[\(logTag)] ready — \(match.kind) \(match.entityID),"
                                + " \(max(1, byteSize(local) / 1024)) KB,"
                                + " \(match.logDescription)"
                        )
                    }
                    return
                }
                throw Failure(reason: lastReason)
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    guard subjectBeingResolved == subject else { return }
                    let identity = subject.identity
                    failedSubjects.insert(identity)
                    // 只记"别再试了"，别让它无限长（一个人刷几百个页面也不涨）。
                    if failedSubjects.count > 64 { failedSubjects.removeAll() }
                    resolveTask = nil
                    writeDebugLog("[\(logTag)] skipped \"\(identity)\" — \(message)")
                }
            }
        }
    }

    /// 一次解析的产物：视频地址 + 缓存 key 的原料 + 一行日志。
    private struct Match {
        let video: URL
        let cacheKey: String
        let kind: String
        let entityID: String
        let logDescription: String
    }

    private static func resolve(
        subject: Subject,
        storefront: String,
        token: String,
        deadline: Date
    ) async -> Match? {
        switch subject {
        case .artist(let name):
            guard let matchedID = await artistID(name: name, storefront: storefront, token: token),
                  let video = await editorialVideo(
                      path: "artists/\(matchedID)",
                      storefront: storefront,
                      keys: artistKeys,
                      token: token,
                      deadline: deadline
                  ) else { return nil }
            // 缓存 key 与上一版逐字一致（`<storefront>-<artistID>-motion`）⇒ 已经下过的艺人
            // 不会因为这次改动再下一次。
            return Match(
                video: video,
                cacheKey: "\(storefront)-\(matchedID)-motion",
                kind: "artist",
                entityID: matchedID,
                logDescription: "\"\(name)\""
            )

        case .album(let name, let artist):
            guard let match = await album(
                name: name,
                artist: artist,
                storefront: storefront,
                token: token,
                deadline: deadline
            ) else { return nil }
            return Match(
                video: match.video,
                cacheKey: "\(storefront)-album-\(match.albumID)-motion",
                kind: "album",
                entityID: match.albumID,
                logDescription: "\"\(match.name)\" by \"\(match.artistName)\""
            )
        }
    }

    /// 设备 region 优先；另一个只当兜底（`editorialVideo` 跟着目录条目走，同一张专辑
    /// 不一定每个店面都带）。日文歌在 cn/us 店里查不到时 jp 店往往有 —— 与锁屏那条同一个配方。
    private static func storefrontCandidates(for subject: Subject) -> [String] {
        let primary = Locale.current.region?.identifier.lowercased() ?? "us"
        let preferred = mentionsKana(subject.identity) ? "jp" : "us"
        return preferred == primary ? [primary] : [primary, preferred]
    }

    private static func mentionsKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - 艺人

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

    // MARK: - 专辑

    private static func album(
        name: String,
        artist: String,
        storefront: String,
        token: String,
        deadline: Date
    ) async -> (video: URL, albumID: String, name: String, artistName: String)? {
        var components = URLComponents(string: "\(apiBase)/v1/catalog/\(storefront)/search")
        // 有艺名就一起带上（检索排序会更准），但**判据**在下面那两道，不靠检索本身。
        let term = artist.isEmpty ? name : "\(artist) \(name)"
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "types", value: "albums"),
            URLQueryItem(name: "limit", value: "6"),
            URLQueryItem(name: "extend", value: "editorialVideo"),
        ]
        guard Date() < deadline,
              let url = components?.url,
              let root = await json(url, token: token),
              let results = root["results"] as? [String: Any],
              let albums = results["albums"] as? [String: Any],
              let items = albums["data"] as? [[String: Any]] else { return nil }

        for item in items {
            guard let attributes = item["attributes"] as? [String: Any],
                  let id = item["id"] as? String else { continue }

            let found = attributes["name"] as? String ?? ""
            let foundArtist = attributes["artistName"] as? String ?? ""
            // ① 专辑名**相等**（不是包含）。`REVIVE+` 是另一张专辑。
            guard LockArtworkMatch.sameAlbumName(found, name) else { continue }
            // ② 艺人**至少有一个词相同**。页面上那行可能是 "A, B" 或 "A feat. B"，
            //    Apple 那边通常只给主艺人 ⇒ 用"交集"而不是"相等"。
            guard artist.isEmpty || foundArtist.isEmpty
                || LockArtworkMatch.sharesArtistName(foundArtist, artist) else { continue }
            guard let editorial = attributes["editorialVideo"] as? [String: Any],
                  let video = firstVideo(in: editorial, keys: albumKeys) else { continue }

            writeDebugLog(
                "[\(logTag)] album matched — \"\(found)\" by \"\(foundArtist)\""
                    + " (album \(id), \(storefront))"
            )
            return (video: video, albumID: id, name: found, artistName: foundArtist)
        }
        return nil
    }

    // MARK: - 详情 / 档位

    private static func editorialVideo(
        path: String,
        storefront: String,
        keys: [String],
        token: String,
        deadline: Date
    ) async -> URL? {
        guard Date() < deadline,
              let url = URL(string: "\(apiBase)/v1/catalog/\(storefront)/\(path)?extend=editorialVideo"),
              let root = await json(url, token: token),
              let items = root["data"] as? [[String: Any]],
              let attributes = items.first?["attributes"] as? [String: Any],
              let editorial = attributes["editorialVideo"] as? [String: Any] else {
            return nil
        }
        return firstVideo(in: editorial, keys: keys)
    }

    private static func firstVideo(in editorial: [String: Any], keys: [String]) -> URL? {
        for key in keys {
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

    /// 同一个主体只下一次。落在 Caches 里，HLS 由 `HLSVideoDownloader` 拼成 mp4。
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
final class EntityMotionLayerView: UIView {

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
