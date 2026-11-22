import Foundation

// 「听歌统计 → 导入的流媒体历史」的**封面补全**。
//
// 为什么需要这一层：Spotify 导出的 zip（`my_spotify_data.zip` / `Streaming_History_Audio_*.json`）
// 里**只有曲目 id + 歌名 + 歌手**，没有封面 —— `StreamingHistoryAccumulator` 只能写
// `artworkURL: nil`，于是榜单里导入的歌全是灰底音符占位（症状就是"用导入的 zip 包的歌，
// 没有歌曲封面"）。
//
// 本机正在播放的那一首有 `SPTPlayerTrack.metadata()` 可读封面（`LyricsArtworkResolver`）；
// 导入的歌没有播放上下文 ⇒ 只能问 Web API。
//
// 数据线：`GET https://api.spotify.com/v1/tracks?ids=…`（一次最多 50 个），Bearer token 由
// **调用方**传进来（页面侧给 `spotifyAccessTokenSnapshot()`，那是 `DataLoaderServiceHooks`
// 抓下来的那一个），与 `ArtistReleasesFromSpotify`（艺人页「最新发布」）走同一条线。
// 曲目接口里封面在 `album.images`；播客/单集在 `/v1/tracks` 里查不到，缺失的那批再按
// `/v1/episodes?ids=` 问一遍（那一层的 `images` 直接挂在条目上）。
//
// 本文件刻意做成 **Foundation-only**（令牌由参数进、日志走 `ListeningStatsLog`）：
// 本机没有 Swift 工具链，只有这样才能进 `tests.yml` 的 CI 步骤被 `swiftc` 真编一遍
// （见 `Tests/ListeningStatsArtwork`）—— 否则它要等到打包 IPA 那一轮才第一次编译。
//
// 三条纪律：
// · **只认曲目 id**。`ListeningStatsTrackKey.fallbackPrefix`（`fnv1a:`，没有 Spotify id 时
//   的稳定哈希）与本地文件那种不是 22 位 base62 的 id 一律不查 —— 拿歌名去搜、把别的
//   版本的封面贴上来，比没有封面更糟；
// · **结果落盘**（`UserDefaults` 的 `ngzhwm_statsArtworkCache`）：键是统计里的曲目 id、
//   值是封面 URL，**空串 = 问过了、确实没有**（负缓存，避免每翻一次页重问同一批）；
// · **没问到 ≠ 没有**：没抓到令牌 / 网络失败**不写**负缓存，下次打开页面还会再试。
//
// ⚠️ 这一层只负责"补 URL"；写回统计文件由 `ListeningStatsStore.backfillArtwork` 做，
// 数据模型本身不认识网络。

enum ListeningStatsArtwork {

    /// `UserDefaults` 里的缓存键（与设置项分开：它是一份"id → URL"的字典，不是开关）。
    static let cacheKey = "ngzhwm_statsArtworkCache"

    /// 缓存上限。封面的 URL 只有几十字节，600 条也就是几十 KB，够覆盖若干年的榜单；
    /// 超了就丢一半（见 `persistCache`），丢了也只是下次再问一遍。
    private static let cacheLimit = 600

    /// 一次 Web API 调用最多带多少个 id（接口硬上限 50）。
    private static let batchLimit = 50

    /// 所有缓存读写都在这一条私有串行队列上（`URLSession` 会阻塞它，但它不影响别的队列）。
    private static let queue = DispatchQueue(
        label: "com.eevee.listening-stats.artwork",
        qos: .utility
    )

    private static var cache: [String: String] = [:]
    private static var didLoadCache = false

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 14
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    // MARK: - 读缓存

    /// 这一批里缓存已经给出封面的那些（同步、零网络；页面首帧就靠它）。
    static func cachedURLs(for trackIDs: [String]) -> [String: String] {
        queue.sync {
            loadCacheIfNeeded()
            var result: [String: String] = [:]
            for trackID in trackIDs {
                guard let url = cache[trackID], !url.isEmpty else { continue }
                result[trackID] = url
            }
            return result
        }
    }

    // MARK: - 联网补

    /// 给缺封面的曲目补 URL。
    ///
    /// - Parameter trackIDs: 统计里的曲目 id（裸 Spotify id 或 `spotify:track:<id>`）。
    /// - Parameter token: Web API 的 Bearer token（调用方给 `spotifyAccessTokenSnapshot()`）。
    ///   为空时整次跳过、**不写负缓存** —— 那只是"这会儿还没抓到令牌"。
    /// - Parameter completion: **主队列**回调，只包含真的取到的那几条（`id → URL`）。
    static func resolve(
        trackIDs: [String],
        token: String?,
        completion: @escaping ([String: String]) -> Void
    ) {
        // 去重 + 排序：同一批 id 永远发同一串请求，日志也能复现。
        let unique = Array(Set(trackIDs)).sorted()
        guard !unique.isEmpty else {
            DispatchQueue.main.async { completion([:]) }
            return
        }

        let trimmedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usableToken = (trimmedToken?.isEmpty == false) ? trimmedToken : nil

        queue.async {
            loadCacheIfNeeded()

            var resolved: [String: String] = [:]
            var pending: [(key: String, spotifyID: String)] = []
            for key in unique {
                if let cached = cache[key] {
                    if !cached.isEmpty { resolved[key] = cached }
                    continue
                }
                guard let id = spotifyID(from: key) else {
                    // 不是 Spotify 曲目 id：这个判定永远成立，直接记成"没有"。
                    cache[key] = ""
                    continue
                }
                pending.append((key: key, spotifyID: id))
            }

            if !pending.isEmpty, usableToken == nil {
                ListeningStatsLog.write(
                    "[Stats] artwork — no Spotify token yet, \(pending.count) cover(s) postponed"
                )
            }

            if !pending.isEmpty, let usableToken {
                let ids = pending.map(\.spotifyID)
                let tracksResult = request(path: "/v1/tracks", ids: ids, token: usableToken)
                var urls = tracksResult.urls
                // 播客单集在 `/v1/tracks` 里查不到（返回 null）⇒ 缺的那批再问一遍单集接口。
                var authoritative = tracksResult.authoritative
                let missing = ids.filter { urls[$0] == nil }
                if !missing.isEmpty {
                    let episodesResult = request(
                        path: "/v1/episodes",
                        ids: missing,
                        token: usableToken
                    )
                    urls.merge(episodesResult.urls) { first, _ in first }
                    // 两个接口**都**答了 200 才敢说"确实没有封面"。
                    authoritative = authoritative && episodesResult.authoritative
                }

                for entry in pending {
                    if let url = urls[entry.spotifyID] {
                        cache[entry.key] = url
                        resolved[entry.key] = url
                    } else if authoritative {
                        cache[entry.key] = ""
                    }
                }

                if resolved.isEmpty {
                    ListeningStatsLog.write(
                        "[Stats] artwork — no cover for \(pending.count)/\(unique.count) track(s)"
                            + " (Web API \(tracksResult.authoritative ? "answered" : "failed"))"
                    )
                } else {
                    ListeningStatsLog.write(
                        "[Stats] artwork — resolved \(resolved.count)/\(unique.count) cover(s)"
                            + " via the Web API"
                    )
                }
            }

            persistCache()
            let answer = resolved
            DispatchQueue.main.async { completion(answer) }
        }
    }

    /// 统计里的曲目 id → Web API 的曲目 id；认不出返回 `nil`。
    ///
    /// 录音器与导入层存的都是**裸 id**（`SPTURL.spt_trackIdentifier` /
    /// `StreamingHistoryRecord.trackIdentifier(fromURI:)`），但旧数据里也可能带着前缀，
    /// 所以前缀也认一下。`fnv1a:` 兜底 id（没有 Spotify id 时才算出来的）明确拒绝。
    static func spotifyID(from identifier: String) -> String? {
        var value = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.hasPrefix(ListeningStatsTrackKey.fallbackPrefix) else {
            return nil
        }

        for prefix in ["spotify:track:", "spotify:episode:"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }

        // 曲目 id 是定长 22 位 base62。长度不对的一律不查：本地文件（`spotify:local:` 的
        // 尾巴是 "歌手|标题|时长"）与各种历史遗留 id 都在这一步被挡掉。
        guard value.count == 22 else { return nil }
        let allowed: Set<Character> = Set(
            "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        )
        guard value.allSatisfy({ allowed.contains($0) }) else { return nil }
        return value
    }

    // MARK: - HTTP

    private struct BatchResult {
        var urls: [String: String]
        /// `true` = 服务器答了 200（那么"没给封面"就是事实，可以写负缓存）。
        var authoritative: Bool
    }

    /// 一次批量请求（调用方已经按 `batchLimit` 切好、也确认过令牌非空）。
    ///
    /// 失败一律返回空结果且 `authoritative == false` —— 那只是这次没问到，
    /// 不能当成"这首歌没有封面"。
    private static func request(path: String, ids: [String], token: String) -> BatchResult {
        guard !ids.isEmpty else { return BatchResult(urls: [:], authoritative: true) }

        var urls: [String: String] = [:]
        var authoritative = true
        var index = 0

        while index < ids.count {
            let upperBound = min(index + batchLimit, ids.count)
            let chunk = Array(ids[index..<upperBound])
            index = upperBound

            guard var components = URLComponents(
                string: "https://api.spotify.com" + path
            ) else {
                authoritative = false
                continue
            }
            components.queryItems = [
                URLQueryItem(name: "ids", value: chunk.joined(separator: ",")),
            ]
            guard let url = components.url else {
                authoritative = false
                continue
            }

            let (status, data) = fetchJSON(url: url, token: token)
            guard status == 200, let data else {
                ListeningStatsLog.write("[Stats] artwork — \(path) answered \(status)")
                authoritative = false
                continue
            }
            urls.merge(artworkURLs(in: data)) { first, _ in first }
        }

        return BatchResult(urls: urls, authoritative: authoritative)
    }

    /// 同步 GET（只在这条私有串行队列上调用）。
    ///
    /// 为什么敢阻塞：这条队列只做封面补全，阻塞它不影响 UI / 录音器 / store；
    /// 而信号来自 `URLSession` 自己的回调线程，不存在互相等待。
    ///
    /// ⚠️ 函数名**不要**叫 `get`：`swift_member_check.py` 会把「只以 private 形式声明过的
    /// 名字」当成跨文件的裸引用去查，而 `get` 还是计算属性的访问器关键字 ⇒ 一个 `private
    /// static func get` 能让它把全仓 31 处 `get {` 全报成错（踩过一次）。
    private static func fetchJSON(url: URL, token: String) -> (status: Int, data: Data?) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var status = 0
        var payload: Data?

        session.dataTask(with: request) { data, response, error in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if error == nil, status == 200 {
                payload = data
            }
            semaphore.signal()
        }.resume()

        // 比 URLSession 自己的超时（10s）多留一点：等不到就按失败处理，绝不堵死队列。
        _ = semaphore.wait(timeout: .now() + 15)
        return (status, payload)
    }

    // MARK: - 解析

    /// `{"tracks": [{id, album: {images}}, …]}` / `{"episodes": [{id, images}, …]}`。
    ///
    /// ⚠️ 数组里**会夹 `null`**（查不到的 id 就是 `null`），所以不能整份转成
    /// `[[String: Any]]` —— 那样一个查不到的 id 就能让整批封面全丢。逐个 `compactMap`。
    /// （`Tests/ListeningStatsArtwork` 钉着这一条。）
    static func artworkURLs(in data: Data) -> [String: String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return [:]
        }

        var items: [[String: Any]] = []
        if let tracks = root["tracks"] as? [Any] {
            items = tracks.compactMap { $0 as? [String: Any] }
        } else if let episodes = root["episodes"] as? [Any] {
            items = episodes.compactMap { $0 as? [String: Any] }
        }

        var result: [String: String] = [:]
        for item in items {
            guard let id = item["id"] as? String, !id.isEmpty,
                  let url = bestImageURL(in: item) else { continue }
            result[id] = url
        }
        return result
    }

    /// 榜单行只有 44pt（3x ≈ 132px）⇒ 挑"够大里最小的那张"：640px 的封面一屏十行没必要。
    private static func bestImageURL(in item: [String: Any]) -> String? {
        // 曲目：`album.images`；播客单集：`images` 直接挂在条目上。
        var images: [[String: Any]] = []
        if let album = item["album"] as? [String: Any],
           let albumImages = album["images"] as? [[String: Any]] {
            images = albumImages
        } else if let episodeImages = item["images"] as? [[String: Any]] {
            images = episodeImages
        }
        guard !images.isEmpty else { return nil }

        var smallestEnough: (width: Int, url: String)?
        var largest: (width: Int, url: String)?

        for image in images {
            guard let raw = image["url"] as? String, !raw.isEmpty else { continue }
            let width = (image["width"] as? NSNumber)?.intValue ?? 0

            if width > (largest?.width ?? -1) {
                largest = (width, raw)
            }
            if width >= 160, width < (smallestEnough?.width ?? Int.max) {
                smallestEnough = (width, raw)
            }
        }

        return smallestEnough?.url ?? largest?.url
    }

    // MARK: - 缓存落盘

    private static func loadCacheIfNeeded() {
        guard !didLoadCache else { return }
        didLoadCache = true
        guard let stored = UserDefaults.standard.dictionary(forKey: cacheKey) else { return }
        for (key, value) in stored {
            guard let url = value as? String else { continue }
            cache[key] = url
        }
    }

    private static func persistCache() {
        guard didLoadCache else { return }

        // 超上限时按 key 排序丢一半：确定性、可复现，丢了也只是下次再问。
        if cache.count > cacheLimit {
            let keep = cache.keys.sorted().suffix(cacheLimit / 2)
            var trimmed: [String: String] = [:]
            for key in keep {
                trimmed[key] = cache[key]
            }
            cache = trimmed
        }

        UserDefaults.standard.set(cache, forKey: cacheKey)
    }
}
