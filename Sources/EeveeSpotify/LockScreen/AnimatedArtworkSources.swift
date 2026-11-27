import Foundation

/// 一首歌在某个画幅下的动态封面素材。`videoURL` 可能是 mp4，也可能是 HLS。
struct AnimatedArtworkAsset {

    enum Source: String {
        case canvas
        case appleMusic
    }

    let source: Source
    let videoURL: URL
    let isHLS: Bool
}

/// Apple Music 一次专辑查询能同时给出方版与竖版，所以两条都带回来 —— 两个 now-playing 键
/// 共用同一次请求。竖版缺的时候由方版顶替，转码那一步会把它裁成 3:4。
struct AppleMusicEditorialAssets {
    let square: AnimatedArtworkAsset?
    let tall: AnimatedArtworkAsset?

    static let empty = AppleMusicEditorialAssets(square: nil, tall: nil)

    func asset(for aspect: LockScreenArtwork.Aspect) -> AnimatedArtworkAsset? {
        switch aspect {
        case .square: return square ?? tall
        case .tall: return tall ?? square
        }
    }
}

/// Canvas：Spotify 自己给这首歌的循环短片。
///
/// 读 track metadata 里的 `canvas.url`（账号属性 `canvas-disabled` 被压成 false 后，
/// 播放核心才会把它填进来；见 `DynamicPremium` 的 `modifyAttributes`）。播放页那一层
/// Canvas 由 `NowPlayingIOS27` 用静态封面盖住，锁屏这段短片不受影响。
///
/// `canvas.type` 决定这是不是一段视频：IMAGE / GIF 类型的 Canvas 交给系统的播放器会
/// 立刻失败，所以这里先按类型挡掉，别让下载去浪费时间。
enum CanvasArtworkSource {

    private static let urlKey = "canvas.url"
    private static let typeKey = "canvas.type"

    static func asset(metadata: [String: String]) -> AnimatedArtworkAsset? {
        guard let raw = metadata[urlKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              url.scheme != nil else {
            return nil
        }

        let kind = (metadata[typeKey] ?? "").uppercased()
        if !kind.isEmpty, !kind.hasPrefix("VIDEO") {
            return nil
        }

        return AnimatedArtworkAsset(source: .canvas, videoURL: url, isHLS: isHLS(url))
    }
}

/// Apple Music 的 editorial video（苹果给唱片公司做的方版/竖版动态封面）。
///
/// 只用到网页播放器的 developer token —— 目录搜索不需要用户登录，所以这条源对
/// 没填 `media-user-token` 的人也能用。
///
/// 关键事实：`editorialVideo` 挂在**专辑**上，不挂在歌曲上。所以先按"艺人 + 专辑"搜专辑
/// （一次请求就能带 `extend=editorialVideo`）；搜不到再退回"按曲名搜歌 → 取所属专辑"。
/// 单曲（`- Single`）通常没有动态封面，只有正式专辑才有 —— 拿不到就返回空。
///
/// 两个补命中的口子：店面先用设备 region，失败再试一个回退店面（日文歌 jp，其余 us）；
/// 专辑名强匹配时允许一次**不带艺人**的搜索（跨文字写法时带艺人的那条会被过滤掉）。
enum AppleMusicArtworkSource {

    private static let apiBase = "https://amp-api.music.apple.com"
    private static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        + " (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    private static let squareKeys = ["motionDetailSquare", "motionSquareVideo1x1"]
    private static let tallKeys = ["motionDetailTall", "motionTallVideo3x4"]
    private static var didReportMissingToken = false

    static func assets(
        title: String,
        artist: String,
        album: String,
        session: URLSession,
        deadline: Date
    ) async -> AppleMusicEditorialAssets {
        guard let token = try? AppleMusicOfficialTtmlLyricsRepository.webDeveloperToken(),
              !token.isEmpty else {
            reportMissingTokenOnce()
            return .empty
        }

        let storefronts = storefrontCandidates(title: title, artist: artist)
        let primary = storefronts[0]

        // ① 首选店面：先按"艺人 + 专辑"搜；专辑名强匹配时再允许一次不带艺人的宽松搜索
        //    （Spotify 显示罗马字、Apple Music 用原生写法时，带艺人那条会被自己的过滤掉）。
        if let direct = await albumSearch(
            storefront: primary,
            title: title,
            artist: artist,
            album: album,
            requireArtist: true,
            token: token,
            session: session
        ) {
            return direct
        }

        if !album.isEmpty, Date() < deadline,
           let loose = await albumSearch(
               storefront: primary,
               title: title,
               artist: artist,
               album: album,
               requireArtist: false,
               token: token,
               session: session
           ) {
            return loose
        }

        // ② 首选店面：搜歌 → 取所属专辑 → 查 editorialVideo。
        guard Date() < deadline else { return .empty }
        if let songID = await songID(
            storefront: primary,
            title: title,
            artist: artist,
            token: token,
            session: session
        ) {
            guard Date() < deadline else { return .empty }
            for albumID in await albumIDs(
                storefront: primary,
                songID: songID,
                token: token,
                session: session
            ) {
                guard Date() < deadline else { return .empty }
                if let editorial = await editorialVideo(
                    storefront: primary,
                    albumID: albumID,
                    token: token,
                    session: session
                ) {
                    return editorial
                }
            }
        }

        // ③ 回退店面：只做一次专辑搜索，别把预算花在第二家店的完整链路上。
        for storefront in storefronts.dropFirst() {
            guard Date() < deadline else { return .empty }
            if let direct = await albumSearch(
                storefront: storefront,
                title: title,
                artist: artist,
                album: album,
                requireArtist: true,
                token: token,
                session: session
            ) {
                return direct
            }
        }

        return .empty
    }

    /// 要查哪些店面：设备 region 优先，再给一个**只查一次**的回退。
    ///
    /// 为什么需要：`editorialVideo` 跟着目录条目走，不同店面的同一张专辑不一定都带；
    /// 日文歌在 cn/us 店里查不到时，jp 店往往有。只回退一个，别让失败路径把 12 秒预算吃光。
    private static func storefrontCandidates(title: String, artist: String) -> [String] {
        let primary = Locale.current.region?.identifier.lowercased() ?? "us"
        let preferred = containsKana(title) || containsKana(artist) ? "jp" : "us"
        return preferred == primary ? [primary] : [primary, preferred]
    }

    private static func containsKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - ① 按专辑搜（首选）

    private static func albumSearch(
        storefront: String,
        title: String,
        artist: String,
        album: String,
        requireArtist: Bool,
        token: String,
        session: URLSession
    ) async -> AppleMusicEditorialAssets? {
        var components = URLComponents(string: "\(apiBase)/v1/catalog/\(storefront)/search")
        let term: String
        if album.isEmpty {
            term = artist.isEmpty ? title : "\(title) \(artist)"
        } else if requireArtist, !artist.isEmpty {
            term = "\(artist) \(album)"
        } else {
            term = album
        }
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "types", value: "albums"),
            URLQueryItem(name: "limit", value: "6"),
            URLQueryItem(name: "extend", value: "editorialVideo"),
        ]

        guard let url = components?.url,
              let root = await json(url, token: token, session: session),
              let results = root["results"] as? [String: Any],
              let albums = results["albums"] as? [String: Any],
              let items = albums["data"] as? [[String: Any]] else {
            return nil
        }

        for item in items {
            guard let attributes = item["attributes"] as? [String: Any] else { continue }

            if requireArtist {
                let artistName = attributes["artistName"] as? String ?? ""
                guard artist.isEmpty || artistName.isEmpty
                    || LockScreenArtwork.looksLikeSameSong(artistName, artist) else {
                    continue
                }
            }

            if !album.isEmpty {
                let name = attributes["name"] as? String ?? ""
                guard name.isEmpty || LockScreenArtwork.looksLikeSameSong(name, album) else {
                    continue
                }
            }

            guard let editorial = attributes["editorialVideo"] as? [String: Any],
                  let assets = buildAssets(in: editorial) else {
                continue
            }
            return assets
        }

        return nil
    }

    // MARK: - ② 搜歌

    private static func songID(
        storefront: String,
        title: String,
        artist: String,
        token: String,
        session: URLSession
    ) async -> String? {
        var components = URLComponents(string: "\(apiBase)/v1/catalog/\(storefront)/search")
        let term = artist.isEmpty ? title : "\(title) \(artist)"
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "limit", value: "6"),
        ]

        guard let url = components?.url,
              let root = await json(url, token: token, session: session),
              let results = root["results"] as? [String: Any],
              let songs = results["songs"] as? [String: Any],
              let items = songs["data"] as? [[String: Any]] else {
            return nil
        }

        let match = items.first { item in
            guard let attributes = item["attributes"] as? [String: Any],
                  let name = attributes["name"] as? String else {
                return false
            }
            let artistName = attributes["artistName"] as? String ?? ""
            return LockScreenArtwork.looksLikeSameSong(name, title)
                && (artist.isEmpty
                    || artistName.isEmpty
                    || LockScreenArtwork.looksLikeSameSong(artistName, artist))
        }

        return match?["id"] as? String
    }

    // MARK: - ③ 歌 → 专辑

    private static func albumIDs(
        storefront: String,
        songID: String,
        token: String,
        session: URLSession
    ) async -> [String] {
        guard let url = URL(
            string: "\(apiBase)/v1/catalog/\(storefront)/songs/\(songID)?include=albums"
        ), let root = await json(url, token: token, session: session),
           let items = root["data"] as? [[String: Any]],
           let relationships = items.first?["relationships"] as? [String: Any],
           let albums = relationships["albums"] as? [String: Any],
           let data = albums["data"] as? [[String: Any]] else {
            return []
        }

        return data.prefix(3).compactMap { $0["id"] as? String }
    }

    // MARK: - ④ 专辑 → editorialVideo

    private static func editorialVideo(
        storefront: String,
        albumID: String,
        token: String,
        session: URLSession
    ) async -> AppleMusicEditorialAssets? {
        guard let url = URL(
            string: "\(apiBase)/v1/catalog/\(storefront)/albums/\(albumID)?extend=editorialVideo"
        ), let root = await json(url, token: token, session: session),
           let items = root["data"] as? [[String: Any]],
           let attributes = items.first?["attributes"] as? [String: Any],
           let editorial = attributes["editorialVideo"] as? [String: Any] else {
            return nil
        }

        return buildAssets(in: editorial)
    }

    private static func buildAssets(in editorial: [String: Any]) -> AppleMusicEditorialAssets? {
        let square = asset(in: editorial, keys: squareKeys)
        var tall = asset(in: editorial, keys: tallKeys)
        if tall == nil { tall = square }
        guard square != nil || tall != nil else { return nil }
        return AppleMusicEditorialAssets(square: square, tall: tall)
    }

    private static func asset(
        in editorial: [String: Any],
        keys: [String]
    ) -> AnimatedArtworkAsset? {
        for key in keys {
            guard let variant = editorial[key] as? [String: Any],
                  let video = variant["video"] as? String,
                  let videoURL = URL(string: video) else {
                continue
            }
            return AnimatedArtworkAsset(
                source: .appleMusic,
                videoURL: videoURL,
                isHLS: isHLS(videoURL)
            )
        }
        return nil
    }

    // MARK: - 请求

    private static func json(
        _ url: URL,
        token: String,
        session: URLSession
    ) async -> [String: Any]? {
        var request = URLRequest(url: url)
        // 单请求压到 4 秒：目录查询整段只有 12 秒，宁可让一步失败也别让一个慢请求
        // 把后面的歌曲搜索/回退店面全吃掉。
        request.timeoutInterval = 4
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.apple.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return object as? [String: Any]
    }

    private static func reportMissingTokenOnce() {
        guard !didReportMissingToken else { return }
        didReportMissingToken = true
        writeDebugLog(
            "[\(LockScreenArtwork.logTag)] Apple Music skipped — no developer token"
        )
    }
}

private func isHLS(_ url: URL) -> Bool {
    url.pathExtension.lowercased() == "m3u8" || url.absoluteString.contains(".m3u8")
}
