import Foundation

// 「听歌统计 → 导入的流媒体历史」的**封面补全**。
//
// 为什么需要这一层：Spotify 导出的 zip（`my_spotify_data.zip` / `Streaming_History_Audio_*.json`）
// 里**只有曲目 id + 歌名 + 歌手**，没有封面 —— `StreamingHistoryAccumulator` 只能写
// `artworkURL: nil`，于是榜单里导入的歌全是灰底音符占位（症状就是"用导入的 zip 包的歌，
// 没有歌曲封面"）。
//
// 本机正在播放的那一首有 `SPTPlayerTrack.metadata()` 可读封面（`LyricsArtworkResolver`）；
// 导入的歌没有播放上下文 ⇒ 只能按曲目 id 问接口。
//
// 数据线有两条：
//
// 1. **Web API**：`GET https://api.spotify.com/v1/tracks?ids=…`（一次最多 50 个），Bearer
//    token 由**调用方**传进来（页面侧给 `spotifyAccessTokenSnapshot()`，那是
//    `DataLoaderServiceHooks` 抓下来的那一个）。曲目接口里封面在 `album.images`；
//    播客/单集在 `/v1/tracks` 里查不到，缺失的那批再按 `/v1/episodes?ids=` 问一遍。
// 2. **oEmbed**（兜底，**不需要令牌**）：`GET https://open.spotify.com/oembed?url=…`。
//    有的设备/账号组合上 `api.spotify.com` 对所有 `/v1/*` 都回 404（同一台机器上
//    open.spotify.com 却是 200），只靠第 1 条就会永远没有封面。oEmbed 按曲目/单集 id
//    回一张 300px 封面（`thumbnail_url`）。第一次 Web API 失败后整场会话不再试它。
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

    /// 每一批 oEmbed 最多花多久（整体窗口，不是单个请求）。oEmbed 是一条 id 一次请求，
    /// 十条全走完通常 3~5 秒；窗口到点就交已经拿到的那些，剩下的下次再试。
    private static let oEmbedBudget: TimeInterval = 12

    /// 所有缓存读写都在这一条私有串行队列上（`URLSession` 会阻塞它，但它不影响别的队列）。
    private static let queue = DispatchQueue(
        label: "com.eevee.listening-stats.artwork",
        qos: .utility
    )

    private static var cache: [String: String] = [:]
    private static var didLoadCache = false
    /// Web API 在这台设备上还能用吗。第一次拿到非 200 就置 false（见 `resolve`）。
    private static var webApiUsable = true
    /// 「没抓到令牌」只提示一次，别每次翻页都写一行。
    private static var didLogMissingToken = false

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

            if !pending.isEmpty {
                let ids = pending.map(\.spotifyID)
                var urls: [String: String] = [:]
                /// 已证实"这条 id 没有封面"：oEmbed 的曲目与单集两种 kind 都 404。
                /// 只有它们才写负缓存；Web API 的 null 不算证据（见下面那段说明）。
                var absent = Set<String>()
                var webHits = 0

                if let usableToken, webApiUsable {
                    let tracksResult = request(path: "/v1/tracks", ids: ids, token: usableToken)
                    urls.merge(tracksResult.urls) { first, _ in first }
                    let missing = ids.filter { urls[$0] == nil }
                    if !missing.isEmpty {
                        // 播客单集在 `/v1/tracks` 里查不到（返回 null）⇒ 缺的那批再问一遍。
                        let episodesResult = request(
                            path: "/v1/episodes",
                            ids: missing,
                            token: usableToken
                        )
                        urls.merge(episodesResult.urls) { first, _ in first }
                    }
                    if !tracksResult.authoritative {
                        // 这台设备/这份令牌上 Web API 整体不通（真机上见过 404）：
                        // 之后整场会话别再白花这两次请求，直接走 oEmbed。
                        webApiUsable = false
                        ListeningStatsLog.write(
                            "[Stats] artwork — the web API is not answering, falling back to oEmbed"
                        )
                    }
                    webHits = urls.count
                } else if usableToken == nil, !didLogMissingToken {
                    didLogMissingToken = true
                    ListeningStatsLog.write(
                        "[Stats] artwork — no Spotify token yet, going straight to oEmbed"
                    )
                }

                // oEmbed 不需要令牌：Web API 不通（或没令牌）时它就是唯一能拿到封面的路。
                //
                // ⚠️ **Web API 没给出封面的那几条，也要再问一次 oEmbed**：它整体 404 时
                // 自然没图；就算它答了 200，也可能因为市场不匹配把条目回成 null —— 那都
                // 不等于"这首歌没有封面"。只有 oEmbed 的两种 kind 都 404 才写负缓存。
                let missingCover = ids.filter { urls[$0] == nil }
                var oEmbedHits = 0
                if !missingCover.isEmpty {
                    let deadline = Date().addingTimeInterval(oEmbedBudget)
                    for id in missingCover {
                        guard Date() < deadline else { break }
                        let result = oEmbedArtwork(for: id)
                        if let url = result.url {
                            urls[id] = url
                            oEmbedHits += 1
                        } else if result.absent {
                            absent.insert(id)
                        }
                    }
                }

                for entry in pending {
                    if let url = urls[entry.spotifyID] {
                        cache[entry.key] = url
                        resolved[entry.key] = url
                    } else if absent.contains(entry.spotifyID) {
                        cache[entry.key] = ""
                    }
                }

                if resolved.isEmpty {
                    ListeningStatsLog.write(
                        "[Stats] artwork — no cover for \(pending.count)/\(unique.count) track(s)"
                            + " (web API \(webHits), oEmbed \(oEmbedHits))"
                    )
                } else {
                    ListeningStatsLog.write(
                        "[Stats] artwork — resolved \(resolved.count)/\(unique.count) cover(s)"
                            + " (web API \(webHits), oEmbed \(oEmbedHits))"
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

    // MARK: - oEmbed（不需要令牌的兜底）
    //
    // 为什么需要它：有的设备/令牌组合上 `api.spotify.com` 对所有 `/v1/*` 都回 404
    // （同一台机器上 `open.spotify.com` 的 oEmbed 却是 200）。oEmbed 按曲目/单集 id
    // 回一张 300px 封面，不需要令牌、也不需要 client id。
    //
    // 代价是"一条 id 一次请求"（Web API 是 50 个一批），所以只在 Web API 拿不到的那批上跑，
    // 并且整批共用一个 `oEmbedBudget` 窗口。

    /// oEmbed 的请求地址。`episode` 只影响 URL 里那段路径。
    static func oEmbedRequestURL(for trackID: String, episode: Bool) -> URL? {
        var components = URLComponents(string: "https://open.spotify.com/oembed")
        components?.queryItems = [
            URLQueryItem(
                name: "url",
                value: "https://open.spotify.com/\(episode ? "episode" : "track")/\(trackID)"
            ),
        ]
        return components?.url
    }

    /// 一条 id 的 oEmbed 结果。
    ///
    /// · `url` 非空 = 拿到封面；
    /// · `absent == true` = 曲目与单集**两种 kind 都答 404**（这条 id 确实没有可画的图）；
    /// · 两者都空 = 这次没问到（网络 / 5xx）⇒ 不写负缓存，下次再试。
    private static func oEmbedArtwork(for trackID: String) -> (url: String?, absent: Bool) {
        var notFound = 0
        var failures = 0

        // 曲目在前、单集在后：库里绝大多数是曲目，单集只在曲目 404 时多花一次请求。
        for isEpisode in [false, true] {
            guard let url = oEmbedRequestURL(for: trackID, episode: isEpisode) else {
                failures += 1
                continue
            }
            let (status, data) = fetchJSON(url: url, token: nil, timeout: 5)
            if status == 200 {
                if let data, let thumbnail = thumbnailURL(in: data) {
                    return (thumbnail, false)
                }
                // 200 却没有 `thumbnail_url`：这一种 kind 没有图，换下一种。
                notFound += 1
                continue
            }
            if status == 404 {
                notFound += 1
            } else {
                failures += 1
            }
        }

        // 两种 kind 都明确 404、且没有任何一次网络失败，才敢说"这条 id 没有封面"。
        return (nil, notFound == 2 && failures == 0)
    }

    /// oEmbed 回包里的 `thumbnail_url`（`image-cdn-ak.spotifycdn.com` 那一档 300px 封面）。
    static func thumbnailURL(in data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = root["thumbnail_url"] as? String else { return nil }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            return nil
        }
        return trimmed
    }

    // MARK: - HTTP

    private struct BatchResult {
        var urls: [String: String]
        /// `true` = 服务器答了 200。只用来判断"这条数据线还通不通"（见 `resolve` 里的
        /// `webApiUsable`）；负缓存不看它 —— 那由 oEmbed 的 404 决定。
        var authoritative: Bool
    }

    /// 一次批量请求（调用方已经按 `batchLimit` 切好、也确认过令牌非空）。
    ///
    /// 失败一律返回空结果且 `authoritative == false` —— 那只是这次没问到。
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
                ListeningStatsLog.write(
                    "[Stats] artwork — \(path) answered \(status)\(bodyHint(data))"
                )
                authoritative = false
                continue
            }
            urls.merge(artworkURLs(in: data)) { first, _ in first }
        }

        return BatchResult(urls: urls, authoritative: authoritative)
    }

    /// 失败时把回包的头一段带进日志。
    ///
    /// 4xx/5xx 的**谁答的**比状态码更重要：Spotify 的 JSON 说"令牌无效"和中间设备返回一页
    /// HTML 是两件完全不同的事，而状态码可能都是 404。回包里没有令牌，可以原样记。
    private static func bodyHint(_ data: Data?) -> String {
        guard let data, !data.isEmpty,
              let text = String(data: data.prefix(160), encoding: .utf8) else {
            return ""
        }
        let flat = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.isEmpty ? "" : " — \(flat)"
    }

    /// 同步 GET（只在这条私有串行队列上调用）。
    ///
    /// - Parameter token: 非空时才带 `Authorization`。oEmbed 那条路传 nil —— **绝不能**
    ///   把 Spotify 的令牌发给 `open.spotify.com` 之外的任何主机，oEmbed 也不需要它。
    /// - Parameter timeout: 单次请求的等待上限（秒）。
    ///
    /// 为什么敢阻塞：这条队列只做封面补全，阻塞它不影响 UI / 录音器 / store；
    /// 而信号来自 `URLSession` 自己的回调线程，不存在互相等待。
    ///
    /// ⚠️ 函数名**不要**叫 `get`：`swift_member_check.py` 会把「只以 private 形式声明过的
    /// 名字」当成跨文件的裸引用去查，而 `get` 还是计算属性的访问器关键字 ⇒ 一个 `private
    /// static func get` 能让它把全仓 31 处 `get {` 全报成错（踩过一次）。
    private static func fetchJSON(
        url: URL,
        token: String?,
        timeout: TimeInterval = 10
    ) -> (status: Int, data: Data?) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        if let token, !token.isEmpty {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var status = 0
        var payload: Data?

        session.dataTask(with: request) { data, response, error in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if error == nil {
                // 非 200 也把回包留下：失败日志要能看出是谁答的（见 `bodyHint`）。
                payload = data
            }
            semaphore.signal()
        }.resume()

        // 比 URLSession 自己的超时多留一点：等不到就按失败处理，绝不堵死队列。
        _ = semaphore.wait(timeout: .now() + timeout + 5)
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
