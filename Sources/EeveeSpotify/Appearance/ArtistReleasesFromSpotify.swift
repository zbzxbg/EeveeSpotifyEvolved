import Foundation

// MARK: - 「最新发布」：Spotify 自己的 Web API 那条数据线
//
// 艺人页那张卡片一直不出现 —— 页面里「热门新歌 / 最新发行」那一行是
// `RetrievalRowLoadingElementUI` 的**骨架**，Spotify 懒加载，不滚到就永远不建 ⇒
// 只读页面的那条路（`EntityPageHeaderManager.captureLatestRelease`）**进页必然读不到**。
//
// ⇒ 这里补一条**不依赖页面**的数据线：用 `DataLoaderServiceHooks` 抓下来的 Bearer token
// 直接问 `api.spotify.com`。三条纪律：
//
// · **只认名字对得上的艺人**（目录原名逐字相等；大小写敏感、不去变音符号 ——
//   `MIMI` 与 `Mimì` 是两个人）。仍有多位同名时，用**页面上看得见的歌名**投票
//   （`ArtistReleaseDisambiguation`）：哪位的 top tracks 在页面上出现过就选哪位；
//   一票没有 / 并列就返回 nil 并留一行日志，**绝不猜**；
// · 解析全部走 `Any` 转换 + 状态码判断，**不信任何字段一定存在、没有 force unwrap**；
// · 回调**永远在主队列**（布局 / 视图那一侧都在主线程）。
//
// ⚠️ 令牌**绝不进日志**：`writeDebugLog` 会落盘、还会进系统统一日志（清不掉），
// 所以这里连"令牌有多长"都不打。
struct SpotifyArtistRelease {
    let title: String
    /// 已经排好版的日期文字（`2026年8月22日` / `2026年8月` / `2026`）—— 直接交给卡片画。
    let dateText: String?
    let trackCount: Int
    let artworkURL: URL?
    /// `spotify:album:…` —— 卡片的点击目标（交给 `SpotifyURIOpener.open`）。
    let albumURI: String
    /// 接口回的**主艺人**名（与页面上那一位相等）。
    let artistName: String
}

enum ArtistReleasesFromSpotify {

    // MARK: - 缓存 / 在飞 / 回调

    private final class Entry {
        let release: SpotifyArtistRelease
        let fetchedAt: Date

        init(release: SpotifyArtistRelease, fetchedAt: Date) {
            self.release = release
            self.fetchedAt = fetchedAt
        }
    }

    /// 每位艺人缓存 6 小时。
    private static let ttl: TimeInterval = 6 * 60 * 60

    private static var cache: [String: Entry] = [:]
    private static var inFlight: Set<String> = []
    /// 同一个 key 上挂着的回调 —— 已经有一个请求在飞时**不丢调用方**（后来者排队等同一个结果）。
    private static var pending: [String: [(SpotifyArtistRelease?) -> Void]] = [:]
    private static let lock = NSLock()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 14
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    // MARK: - 名字归一化
    //
    // 归一化：去掉变音符号、转小写、只留字母与数字。
    //
    // ⚠️ 页面那边 `ArtistLatestReleaseSource.normalized` 是 `private`，**这里另写一份**
    // 两份判据一致就够，不需要为了共用去动那个旧文件。
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        return folded.filter { character in
            character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        }
    }

    // MARK: - 对外的两个入口
    //
    // 已经取到过的那一份（同步；给"每一拍都要看一眼"的布局侧用）。
    static func cached(for artist: String) -> SpotifyArtistRelease? {
        let key = catalogName(artist)
        // 去掉首尾空白之后为空 = 页面上还没有艺人名；只可能来自 `fetch`，
        // 而它在门口已经记过一行了 —— 这里再记一行就是重复。
        guard !key.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[key] else { return nil }
        guard Date().timeIntervalSince(entry.fetchedAt) < ttl else {
            cache[key] = nil
            return nil
        }
        return entry.release
    }

    /// 取这位艺人的最新一张发布。
    ///
    /// 令牌缺失 / 名字对不上 / 接口失败一律给 `nil`（并且各留一行日志），**不猜**。
    /// - Parameter pageText: 页面上现在看得见的文字（多位同名艺人时用来投票；见
    ///   `ArtistReleaseDisambiguation`）。别的档位不用它。
    /// - Note: 回调**一定**在主队列上。
    static func fetch(
        artist: String,
        pageText: String = "",
        completion: @escaping (SpotifyArtistRelease?) -> Void
    ) {
        let key = catalogName(artist)
        guard !key.isEmpty else {
            writeDebugLog("[Release] spotify — the artist name is empty after normalization, not asking")
            DispatchQueue.main.async { completion(nil) }
            return
        }

        if let alreadyCached = cached(for: artist) {
            writeDebugLog("[Release] spotify — \"\(artist)\": already cached as \(alreadyCached.title)")
            DispatchQueue.main.async { completion(alreadyCached) }
            return
        }

        lock.lock()
        if inFlight.contains(key) {
            pending[key, default: []].append(completion)
            lock.unlock()
            writeDebugLog("[Release] spotify — \"\(artist)\": a request is already in flight, joining it")
            return
        }
        inFlight.insert(key)
        pending[key] = [completion]
        lock.unlock()

        guard let token = spotifyAccessTokenSnapshot(), !token.isEmpty else {
            writeDebugLog(
                "[Release] spotify — \"\(artist)\": no access token captured yet, cannot ask the Web API"
            )
            finish(key: key, release: nil)
            return
        }

        writeDebugLog("[Release] spotify — \"\(artist)\": searching the Web API for the artist")
        searchArtist(named: artist, key: key, token: token, pageText: pageText)
    }

    // MARK: - 第一步：搜索艺人（名字必须逐字对得上）

    private static func searchArtist(
        named artist: String,
        key: String,
        token: String,
        pageText: String
    ) {
        guard let url = searchURL(for: artist) else {
            writeDebugLog("[Release] spotify — \"\(artist)\": could not build the search URL")
            finish(key: key, release: nil)
            return
        }

        let task = session.dataTask(with: makeRequest(url: url, token: token)) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, error == nil, status == 200 else {
                let reason = error.map { String(describing: $0) } ?? "-"
                writeDebugLog(
                    "[Release] spotify — \"\(artist)\": search failed, status \(status), \(reason)"
                )
                finish(key: key, release: nil)
                return
            }

            let candidates = matchedArtistCandidates(in: data, artist: artist)
            guard let first = candidates.first else {
                // 具体原因（看到了哪些名字）已经在 `matchedArtistCandidates` 里记过一行。
                finish(key: key, release: nil)
                return
            }
            if candidates.count == 1 {
                writeDebugLog(
                    "[Release] spotify — \"\(artist)\": matched artist id \(first.id), asking for its albums"
                )
                albums(artistID: first.id, artist: artist, key: key, token: token, withMarket: true)
                return
            }
            writeDebugLog(
                "[Release] spotify — \"\(artist)\": \(candidates.count) artists carry that exact name,"
                    + " voting with the page's own tracks"
            )
            disambiguate(
                candidates: candidates,
                artist: artist,
                pageText: pageText,
                key: key,
                token: token
            )
        }
        task.resume()
    }

    /// 目录里的原名：只做 Unicode 预组合 + 去首尾空白，**大小写敏感、不去变音符号**。
    ///
    /// 页面上的名字就是目录里的原名 ⇒ 这是最可靠的那一半判据。
    /// `Mimì` / `MIMI` 只差一个变音符号；折叠掉它就会把两位歌手当成同一个。
    private static func catalogName(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 在 `artists.items` 里找**目录原名逐字相等**的候选（可能不止一位）。
    private static func matchedArtistCandidates(
        in data: Data,
        artist: String
    ) -> [(id: String, name: String)] {
        guard let root = jsonObject(data),
              let artists = root["artists"] as? [String: Any],
              let items = artists["items"] as? [[String: Any]] else {
            writeDebugLog("[Release] spotify — \"\(artist)\": the search answer carried no artists.items")
            return []
        }

        let wanted = catalogName(artist)
        var seen: [String] = []
        var matches: [(id: String, name: String)] = []

        for item in items {
            guard let name = item["name"] as? String,
                  let id = item["id"] as? String,
                  !id.isEmpty else { continue }
            if seen.count < 5, !seen.contains(name) { seen.append(name) }
            if catalogName(name) == wanted { matches.append((id: id, name: name)) }
        }

        guard !matches.isEmpty else {
            let seenText = seen.isEmpty ? "-" : seen.joined(separator: " | ")
            writeDebugLog(
                "[Release] spotify — \"\(artist)\": no artist with that exact name in the search"
                    + " answer (saw \(seenText))"
            )
            return []
        }
        return matches
    }

    /// 多位同名艺人：用**页面上看得见的歌名**给每位候选的 top tracks 投票。
    ///
    /// 逐位顺序问（最多 5 位），全都回来之后由 `ArtistReleaseDisambiguation.bestIndex` 选：
    /// 唯一最高且至少命中 2 首才算数；一票没有 / 并列 ⇒ `nil`（**不猜**）。
    private static func disambiguate(
        candidates: [(id: String, name: String)],
        artist: String,
        pageText: String,
        key: String,
        token: String
    ) {
        guard !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            writeDebugLog(
                "[Release] spotify — \"\(artist)\": \(candidates.count) artists share that exact name"
                    + " and the page has no tracks to compare with — not guessing"
            )
            finish(key: key, release: nil)
            return
        }

        let limited = Array(candidates.prefix(5))
        var titles: [[String]] = []
        var index = 0

        func askNext() {
            guard index < limited.count else {
                let scores = titles.map {
                    ArtistReleaseDisambiguation.score(titles: $0, pageText: pageText)
                }
                writeDebugLog(
                    "[Release] spotify — \"\(artist)\": track overlap \(scores)"
                        + " across \(limited.count) candidate(s)"
                )
                guard let best = ArtistReleaseDisambiguation.bestIndex(scores: scores, minimum: 2) else {
                    writeDebugLog(
                        "[Release] spotify — \"\(artist)\": the page's tracks do not single out one"
                            + " candidate — not guessing"
                    )
                    finish(key: key, release: nil)
                    return
                }
                let chosen = limited[best]
                writeDebugLog(
                    "[Release] spotify — \"\(artist)\": picked artist id \(chosen.id)"
                        + " (\(scores[best]) track(s) found on the page)"
                )
                albums(artistID: chosen.id, artist: artist, key: key, token: token, withMarket: true)
                return
            }
            let candidate = limited[index]
            index += 1
            topTrackTitles(artistID: candidate.id, token: token) { list in
                titles.append(list)
                askNext()
            }
        }

        askNext()
    }

    /// 这位艺人的 top tracks（只取歌名，给消歧投票用）。
    ///
    /// 失败给空数组：那一位只是"没有票"，不连累别的候选。
    private static func topTrackTitles(
        artistID: String,
        token: String,
        completion: @escaping ([String]) -> Void
    ) {
        var components = URLComponents(
            string: "https://api.spotify.com/v1/artists/" + artistID + "/top-tracks"
        )
        if let market = storefront() {
            components?.queryItems = [URLQueryItem(name: "market", value: market)]
        }
        guard let url = components?.url else {
            completion([])
            return
        }
        let task = session.dataTask(with: makeRequest(url: url, token: token)) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, error == nil, status == 200,
                  let root = jsonObject(data),
                  let tracks = root["tracks"] as? [[String: Any]] else {
                writeDebugLog(
                    "[Release] spotify — top tracks for \(artistID) unavailable, status \(status)"
                )
                completion([])
                return
            }
            completion(tracks.compactMap { $0["name"] as? String })
        }
        task.resume()
    }

    // MARK: - 第二步：这位艺人的专辑 / 单曲
    //
    // - Parameter withMarket: 第一次带设备地区；400 / 401 时**去掉 market 重试一次**
    // （有的令牌 / 地区组合不接受 `market`，去掉之后同一个接口照样能用）。
    private static func albums(
        artistID: String,
        artist: String,
        key: String,
        token: String,
        withMarket: Bool
    ) {
        guard let url = albumsURL(artistID: artistID, withMarket: withMarket) else {
            writeDebugLog("[Release] spotify — \"\(artist)\": could not build the albums URL")
            finish(key: key, release: nil)
            return
        }

        let task = session.dataTask(with: makeRequest(url: url, token: token)) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            // 带 `market` 的第一次请求在这台设备上（地区 CN）直接 404。400/401 原来的重试
            // 覆盖不到它 ⇒ 这里把 404 也算进"去掉 market 再问一次"。
            if withMarket, status == 400 || status == 401 || status == 404 {
                writeDebugLog(
                    "[Release] spotify — \"\(artist)\": albums answered \(status) with a market,"
                        + " asking once more without it"
                )
                albums(artistID: artistID, artist: artist, key: key, token: token, withMarket: false)
                return
            }

            guard let data, error == nil, status == 200 else {
                let reason = error.map { String(describing: $0) } ?? "-"
                writeDebugLog(
                    "[Release] spotify — \"\(artist)\": albums failed, status \(status), \(reason)"
                )
                // `/artists/{id}/albums` 整条不通时还有一条**同一个令牌能走通**的路
                // （搜索接口在这台设备上已经证明返回 200）⇒ 去按专辑搜索里挑最新一张。
                // 只在"已经去掉 market 仍失败"时走，避免同一个 404 问两遍。
                if !withMarket {
                    searchAlbums(artist: artist, artistID: artistID, key: key, token: token)
                    return
                }
                finish(key: key, release: nil)
                return
            }

            guard let release = latestRelease(in: data, artist: artist, expectedArtistID: artistID) else {
                // 具体原因已经在 `latestRelease` 里记过一行。
                finish(key: key, release: nil)
                return
            }
            writeDebugLog(
                "[Release] spotify — \"\(artist)\": picked \(release.title) / \(release.albumURI)"
                    + " (\(release.trackCount) track(s))"
            )
            finish(key: key, release: release)
        }
        task.resume()
    }

    /// 兜底数据线：`/v1/search?type=album`。
    ///
    /// `/artists/{id}/albums` 在有的地区 / 令牌组合下会直接 404，而**同一个令牌**问
    /// `/v1/search` 是 200（它刚刚就在同一个会话里返回过 artist id）⇒ 用歌手名搜一批专辑，
    /// 仍然按"主艺人逐字相等 + 日期最新"来挑，并且**专辑上的 `artists[0].id` 必须就是那一位**
    /// （解析复用 `latestRelease`，它同时认 `items` 与 `albums.items` 两种形状）。
    private static func searchAlbums(artist: String, artistID: String, key: String, token: String) {
        guard var components = URLComponents(string: "https://api.spotify.com/v1/search") else {
            writeDebugLog("[Release] spotify — \"\(artist)\": could not build the album search URL")
            finish(key: key, release: nil)
            return
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: artist),
            URLQueryItem(name: "type", value: "album"),
            URLQueryItem(name: "limit", value: "50"),
        ]
        guard let url = components.url else {
            writeDebugLog("[Release] spotify — \"\(artist)\": could not build the album search URL")
            finish(key: key, release: nil)
            return
        }
        writeDebugLog(
            "[Release] spotify — \"\(artist)\": falling back to the album search endpoint"
        )
        let task = session.dataTask(with: makeRequest(url: url, token: token)) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, error == nil, status == 200 else {
                let reason = error.map { String(describing: $0) } ?? "-"
                writeDebugLog(
                    "[Release] spotify — \"\(artist)\": album search failed, status \(status), \(reason)"
                )
                finish(key: key, release: nil)
                return
            }
            guard let release = latestRelease(in: data, artist: artist, expectedArtistID: artistID) else {
                // 具体原因已经在 `latestRelease` 里记过一行。
                finish(key: key, release: nil)
                return
            }
            writeDebugLog(
                "[Release] spotify — \"\(artist)\": picked \(release.title) / \(release.albumURI)"
                    + " (\(release.trackCount) track(s)) through the album search"
            )
            finish(key: key, release: release)
        }
        task.resume()
    }

    /// 从 `items` 里挑出"主艺人就是这一位 + 日期最新"的那一张。
    ///
    /// 过滤：`album_type == compilation` 丢掉、`uri` 不是 `spotify:album:` 的丢掉、
    /// 主艺人（`artists[0]`）对不上的丢掉（合作曲 / 群星合辑都在这里出局）。
    ///
    /// - Parameter expectedArtistID: 已经确定下来的那位的 id。专辑上带 `artists[0].id` 时
    ///   必须与它相等 —— 名字比较是启发式，id 才是同一性的判据。
    private static func latestRelease(
        in data: Data,
        artist: String,
        expectedArtistID: String? = nil
    ) -> SpotifyArtistRelease? {
        guard let root = jsonObject(data) else {
            writeDebugLog("[Release] spotify — \"\(artist)\": the answer was not a JSON object")
            return nil
        }
        // `artists/{id}/albums` 给的是根上的 `items`；`search?type=album` 把它包在
        // `albums.items` 里 ⇒ 两种形状都认（兜底数据线用同一个解析）。
        let items = (root["items"] as? [[String: Any]])
            ?? ((root["albums"] as? [String: Any])?["items"] as? [[String: Any]])
        guard let items else {
            writeDebugLog("[Release] spotify — \"\(artist)\": the answer carried no items")
            return nil
        }

        let wanted = normalized(artist)
        var total = 0
        var matched = 0
        var withoutDate = 0
        var best: SpotifyArtistRelease?
        var bestDate: Date?

        for item in items {
            total += 1
            if let type = item["album_type"] as? String, type.lowercased() == "compilation" {
                continue
            }
            guard let title = item["name"] as? String, !title.isEmpty,
                  let uri = item["uri"] as? String, uri.hasPrefix("spotify:album:"),
                  let primary = primaryArtistName(of: item),
                  normalized(primary) == wanted else {
                continue
            }
            if let expectedArtistID,
               let id = primaryArtistID(of: item),
               !id.isEmpty,
               id != expectedArtistID {
                continue
            }

            matched += 1
            let parsed = parse(releaseDate: item["release_date"] as? String)
            if parsed.date == nil { withoutDate += 1 }

            let release = SpotifyArtistRelease(
                title: title,
                dateText: parsed.text,
                trackCount: item["total_tracks"] as? Int ?? 0,
                artworkURL: artworkURL(of: item),
                albumURI: uri,
                artistName: primary
            )

            // 有日期的按日期取最新；没日期的排在最后（只有"一条日期都没有"时才可能被选上）。
            let isBetter: Bool
            switch (bestDate, parsed.date) {
            case (nil, nil):
                isBetter = best == nil
            case (nil, _?):
                isBetter = true
            case (_?, nil):
                isBetter = false
            case let (current?, candidate?):
                isBetter = candidate > current
            }
            if isBetter {
                best = release
                bestDate = parsed.date
            }
        }

        guard let best else {
            writeDebugLog(
                "[Release] spotify — \"\(artist)\": none of the \(total) item(s) has that artist as its"
                    + " primary artist (or had a usable album uri)"
            )
            return nil
        }
        if matched > 0, withoutDate == matched {
            writeDebugLog(
                "[Release] spotify — \"\(artist)\": \(matched) item(s) matched but none carried a"
                    + " parseable release_date, using the first one"
            )
        }
        return best
    }

    // MARK: - 解析小工具（全部防御式）

    private static func primaryArtistName(of item: [String: Any]) -> String? {
        guard let artists = item["artists"] as? [[String: Any]],
              let first = artists.first,
              let name = first["name"] as? String,
              !name.isEmpty else { return nil }
        return name
    }

    private static func primaryArtistID(of item: [String: Any]) -> String? {
        guard let artists = item["artists"] as? [[String: Any]],
              let first = artists.first,
              let id = first["id"] as? String,
              !id.isEmpty else { return nil }
        return id
    }

    private static func artworkURL(of item: [String: Any]) -> URL? {
        guard let images = item["images"] as? [[String: Any]],
              let first = images.first,
              let raw = first["url"] as? String,
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return raw as? [String: Any]
    }

    // MARK: - 日期（`YYYY-MM-DD` / `YYYY-MM` / `YYYY` 三种精度）

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy"
        return formatter
    }()

    /// 卡片上的"日 / 月 / 年"三档文字。
    ///
    /// "日"这一档与页面旧卡片（`ArtistLatestReleaseSource.cardDateFormat`）**长得一样**
    /// （`dateStyle = .long`，跟随系统语言）—— 但这里**自己造一份**：解析跑在 URLSession 的
    /// 回调队列上，不复用别的文件里那个共享 `DateFormatter` 实例。
    private static let dayCardFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    private static let monthCardFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        return formatter
    }()

    private static let yearCardFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("y")
        return formatter
    }()

    /// `` / `2026-08` / `2026`。
    ///
    /// Spotify 的 `release_date` **只给到它有的那位精度**（单曲常常只到年）⇒ 三种都认，
    /// 解析不出日期就给 `(nil, nil)`（排序时排最后）。
    private static func parse(releaseDate raw: String?) -> (date: Date?, text: String?) {
        guard let raw else { return (nil, nil) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil) }

        if let date = dayFormatter.date(from: trimmed) {
            return (date, dayCardFormatter.string(from: date))
        }
        if let date = monthFormatter.date(from: trimmed) {
            return (date, monthCardFormatter.string(from: date))
        }
        if let date = yearFormatter.date(from: trimmed) {
            return (date, yearCardFormatter.string(from: date))
        }
        return (nil, nil)
    }

    // MARK: - 请求

    private static func searchURL(for artist: String) -> URL? {
        var components = URLComponents(string: "https://api.spotify.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: artist),
            URLQueryItem(name: "type", value: "artist"),
            URLQueryItem(name: "limit", value: "20"),
        ]
        return components?.url
    }

    private static func albumsURL(artistID: String, withMarket: Bool) -> URL? {
        var components = URLComponents(
            string: "https://api.spotify.com/v1/artists/" + artistID + "/albums"
        )
        var items = [
            URLQueryItem(name: "include_groups", value: "album,single"),
            URLQueryItem(name: "limit", value: "50"),
        ]
        if withMarket, let market = storefront() {
            items.append(URLQueryItem(name: "market", value: market))
        }
        components?.queryItems = items
        return components?.url
    }

    /// 设备地区（两位字母）—— 只是"优先这一家店"，拿不到就不带 `market`。
    private static func storefront() -> String? {
        guard let region = Locale.current.region?.identifier, region.count == 2 else { return nil }
        return region.uppercased()
    }

    private static func makeRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - 收尾
    //
    // 清在飞、写缓存、**在主队列**把结果交给所有等着的人。
    private static func finish(key: String, release: SpotifyArtistRelease?) {
        lock.lock()
        inFlight.remove(key)
        if let release { cache[key] = Entry(release: release, fetchedAt: Date()) }
        let callbacks = pending[key] ?? []
        pending[key] = nil
        lock.unlock()

        // 契约：回调**永远在主队列**（卡片 / 页头都在主线程上改）。
        DispatchQueue.main.async {
            for callback in callbacks { callback(release) }
        }
    }
}
