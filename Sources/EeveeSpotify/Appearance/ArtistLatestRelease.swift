import Foundation

// 「最新发布」卡片的数据。
//
// AM 的艺人页在**三颗按钮下面**有一张"最新发布"小卡片（封面 / 日期 / 名称 / 曲数）。Spotify 的艺人页没有这一块 ⇒ 数据和卡片都得自己来。
//
// 数据源：iTunes Search API
// `GET https://itunes.apple.com/search?term=<艺人>&entity=album&limit=50&country=jp`
// 四个字段（日期 / 名称 / 曲数 / 封面）一次全给，而且不需要任何令牌 —— 不像官方 TTML 那条要 `media-user-token`。「最新发布」本来就是**苹果的目录**在 AM 里显示的东西，用苹果的目录最不容易对不上。封面把 `100x100bb` 换成 `600x600bb` 就是大图。
//
// ⚠️ 搜索是**按相关度**返回的、**不按日期** ⇒ 必须 `limit=50` 拉一批、自己按 `releaseDate` 取最新；并且要核对 `artistName` 与页面上那位艺人（同名不同人时不能直接采信）。
//
// 优先级：优先展示**艺人之选**，没有艺人之选再展示最新发布。艺人之选是 Spotify 自己的板块、不在苹果目录里，只能从页面里读（见 `EntityPageHeaderManager.captureArtistPick`）；本文件只管"最新发布"这一档。
struct ArtistLatestRelease {
    let title: String
    let date: Date?
    let trackCount: Int
    let artworkURL: URL?
    /// 取到它的时间（缓存用）。
    let fetchedAt: Date
}

enum ArtistLatestReleaseSource {

    /// 卡片上的日期。AM 用"2026年8月22日"这种**长日期**，跟随系统语言。
    static let cardDateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    // MARK: - 缓存

    private static var cache: [String: ArtistLatestRelease] = [:]
    private static var inFlight: Set<String> = []
    private static let lock = NSLock()
    private static let ttl: TimeInterval = 6 * 60 * 60

    private static var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// 已经取到过的那一份（同步、给 `layoutSubviews` 那一拍用）。
    static func cached(for artist: String) -> ArtistLatestRelease? {
        let key = normalized(artist)
        guard !key.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[key] else { return nil }
        guard Date().timeIntervalSince(entry.fetchedAt) < ttl else {
            cache[key] = nil
            return nil
        }
        return entry
    }

    // MARK: - 取数
    //
    // 取这位艺人的最新一条发布；已经有缓存 / 已经有请求在飞时不重复发。
    //
    // **只查"设备地区"那一家店是不够的**。
    //
    // ```
    // [Release] iTunes search — "Nanatsukaze"
    // [Release] "Nanatsukaze" — no usable release in the iTunes response   ← 4 秒后
    // [Release] no release for "Nanatsukaze" — the card stays hidden
    // ```
    //
    // 本机实测`entity=album&limit=10`）：
    //
    // | country | resultCount | artistName |
    // | `cn`（这台设备的地区） | **0** | — |
    // | `jp` | 10 | `ナナツカゼ`（假名，与页面上的 `Nanatsukaze` 对不上） |
    // | `us` | 10 | **`Nanatsukaze`** ✓ |
    //
    // ⇒ 按 **设备地区 → `us` → `jp`** 依次试，第一个能给出"艺人名对得上"的结果就用它。
    // 中国大陆的 iTunes 目录**根本没有这位艺人的东西**，这条链是唯一能出卡车的路。
    //
    // - Note: 回调**一定**在主队列上。
    static func fetch(artist: String, completion: @escaping (ArtistLatestRelease?) -> Void) {
        let key = normalized(artist)
        guard !key.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        if let cached = cached(for: artist) {
            DispatchQueue.main.async { completion(cached) }
            return
        }

        lock.lock()
        let alreadyRunning = !inFlight.insert(key).inserted
        lock.unlock()
        guard !alreadyRunning else { return }

        attempt(artist: artist, key: key, countries: countryChain(), index: 0, completion: completion)
    }

    /// 要试哪几家店（去重、顺序固定）。
    private static func countryChain() -> [String] {
        var list: [String] = []
        if let region = Locale.current.region?.identifier.lowercased(), !region.isEmpty {
            list.append(region)
        }
        for fallback in ["us", "jp"] where !list.contains(fallback) {
            list.append(fallback)
        }
        return list
    }

    /// 依次试 `countries[index...]`；拿到一条可用的就收工。
    private static func attempt(
        artist: String,
        key: String,
        countries: [String],
        index: Int,
        completion: @escaping (ArtistLatestRelease?) -> Void
    ) {
        guard index < countries.count else {
            finish(key: key, release: nil, completion: completion)
            return
        }
        let country = countries[index]

        guard let url = url(for: artist, country: country) else {
            attempt(artist: artist, key: key, countries: countries, index: index + 1, completion: completion)
            return
        }

        writeDebugLog("[Release] iTunes search — \"\(artist)\" @ \(country)")

        let task = session.dataTask(with: url) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, error == nil, status == 200 else {
                writeDebugLog(
                    "[Release] iTunes search failed for \"\(artist)\" @ \(country) —"
                        + " status \(status), error \(error.map { "\($0)" } ?? "-")"
                )
                attempt(artist: artist, key: key, countries: countries, index: index + 1, completion: completion)
                return
            }

            let parsed = parse(data: data, artist: artist)
            if let release = parsed.release {
                writeDebugLog(
                    "[Release] \"\(artist)\" @ \(country) → \(release.title)"
                        + " (\(release.trackCount) track(s),"
                        + " \(release.date.map { cardDateFormat.string(from: $0) } ?? "date ?"))"
                )
                finish(key: key, release: release, completion: completion)
                return
            }

            // **没对上的时候要把"对面写了什么"打出来** —— 上一轮的
            // `no usable release` 谁也答不了"是 0 条结果，还是艺人名对不上"。
            writeDebugLog(
                "[Release] \"\(artist)\" @ \(country) — no usable release (\(parsed.results) result(s),"
                    + " artistName(s): \(parsed.artistNames))"
            )
            attempt(artist: artist, key: key, countries: countries, index: index + 1, completion: completion)
        }
        task.resume()
    }

    private static func finish(
        key: String,
        release: ArtistLatestRelease?,
        completion: @escaping (ArtistLatestRelease?) -> Void
    ) {
        lock.lock()
        inFlight.remove(key)
        if let release { cache[key] = release }
        lock.unlock()
        DispatchQueue.main.async { completion(release) }
    }

    private static func url(for artist: String, country: String) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        // 国家/地区影响"这位艺人有哪些发布"（日区艺人只在 jp 目录里齐全）。
        components?.queryItems = [
            URLQueryItem(name: "term", value: artist),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "country", value: country),
        ]
        return components?.url
    }

    // MARK: - 解析
    //
    // 一次搜索的解析result：`release` 是要不要用，`results` / `artistNames` 只进日志
    // （"0 条结果"与"有结果但都对不上"是两件完全不同的事）。
    private static func parse(
        data: Data,
        artist: String
    ) -> (release: ArtistLatestRelease?, results: Int, artistNames: String) {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let root = raw as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            return (nil, 0, "-")
        }

        let wanted = normalized(artist)
        var newest: ArtistLatestRelease?
        var seenArtists: [String] = []
        var matched = 0
        var dated = 0

        for item in results {
            guard let name = item["collectionName"] as? String, !name.isEmpty else { continue }

            let artistName = item["artistName"] as? String ?? ""
            if !artistName.isEmpty, !seenArtists.contains(artistName), seenArtists.count < 3 {
                seenArtists.append(artistName)
            }

            // 歌手对不上的一律不要（同名不同人是这里唯一的坑）。
            let normalizedArtist = normalized(artistName)
            guard !normalizedArtist.isEmpty,
                  normalizedArtist.contains(wanted) || wanted.contains(normalizedArtist)
            else { continue }

            let date = parseDate(item["releaseDate"] as? String)
            matched += 1
            if date != nil { dated += 1 }
            let tracks = item["trackCount"] as? Int ?? 0
            let artwork = (item["artworkUrl100"] as? String).flatMap(upsizedArtwork)

            let release = ArtistLatestRelease(
                title: name,
                date: date,
                trackCount: tracks,
                artworkURL: artwork,
                fetchedAt: Date()
            )

            // 没日期的排在最后 —— 有日期里挑最新的。
            switch (newest?.date, release.date) {
            case let (existing?, candidate?):
                if candidate > existing { newest = release }
            case (nil, _?):
                newest = release
            case (_?, nil):
                break
            case (nil, nil):
                if newest == nil { newest = release }
            }
        }

        // **一条日期都解析不出来就别猜**。
        //
        // 搜索是**按相关度**返回的，「最新发布」这个名字要求按日期挑 ⇒ 没有日期时
        // "第一名"根本不是"最新的一张"（`Connect the World` 就是这么被选上的）。
        // 宁可这张卡先不出现（页面那一块读到之后会自己换上来），也不印一张错的专辑。
        if matched > 0, dated == 0, let fallback = newest {
            writeDebugLog(
                "[Release] \(matched) result(s) matched the artist but none carried a parseable"
                    + " releaseDate — refusing to guess (would have shown \"\(fallback.title)\")"
            )
            return (nil, results.count, seenArtists.isEmpty ? "-" : seenArtists.joined(separator: " | "))
        }

        return (newest, results.count, seenArtists.isEmpty ? "-" : seenArtists.joined(separator: " | "))
    }

    /// ```
    /// [Release] "Nanatsukaze" @ us → Connect the World - Single (1 track(s), date ?)
    /// ```
    ///
    /// 旧版**只**认 `MM/dd/yyyy HH:mm:ss`，而现在的 search 接口下发的是 **ISO-8601**
    /// ⇒ 每条结果的日期都是 nil ⇒ `newest` 落到「**搜索相关度第一名**」而不是「日期最新的一张」，
    /// 于是卡片显示的是另一位同名艺人的旧单曲，而不是页面上那张 `空耳 - Single`。
    /// 那一行里的 `date ?` 就是现场。
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = isoFormatter.date(from: raw) ?? fractionalISOFormatter.date(from: raw) {
            return date
        }
        for format in ["MM/dd/yyyy HH:mm:ss", "yyyy/MM/dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    /// `…/100x100bb.jpg` → `…/600x600bb.jpg`（同一张图的大图）。
    private static func upsizedArtwork(_ raw: String) -> URL? {
        URL(string: raw.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { character in
            character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        }
    }
}
