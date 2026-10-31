import Foundation
import UIKit

/// ## 为什么是 Genius
///
/// 本仓库**已经有** Genius 这条线（`Lyrics/Repositories/GeniusLyricsRepository.swift`：`api.genius.com`，
/// 用的是**免 key** 的那套头部 —— `X-Genius-Logged-Out: true` + iOS 版 User-Agent）⇒ 这里复用同一套：
/// 不新增 key、不新增账号、用户不用配置任何东西 ✓。
///
/// 它补的是 Spotify 那边**读不到**的情况（正文为空 / 被截断 / 那一块没建出来）：
/// · `GET /search?q=<艺人名>` —— 取 `type == artist` 且**名字对得上**的那个命中；没有就退到歌命中的主艺人；
/// · `GET /artists/<id>` —— `response.artist.description.plain` 就是简介。
///
/// ⚠️ 两点如实说：
/// ① Genius 的艺人简介**基本是英文**（Spotify 那边是跟着 app 语言的）⇒ **只在 Spotify 读不到时才用**
/// （见 `ArtistBioSheet.present`），而且要**署名**（`artist_bio_from_genius` 那一行）。
/// ② 维基百科**不做正文**：CC BY-SA 要署名 + 许可链接，而且你听的那批日系独立艺人命中率很低
/// ⇒ 只做成一个**链接**（`ArtistBioSheet` 底部那颗 Wikipedia 按钮）。
/// Spotify 自己的 About 页也是这么干的：`SPTArtistAbout:sArtistWikipediaButtonTitle`（dump:21079）。
enum ArtistBioSource {

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "X-Genius-iOS-Version": "6.21.0",
            "X-Genius-Logged-Out": "true",
            "User-Agent": "Genius/1109 iOS/\(UIDevice.current.systemVersion)",
        ]
        configuration.timeoutIntervalForRequest = 12
        return URLSession(configuration: configuration)
    }()

    /// 维基百科那条线**另开一个 session**：它的 API 要求一个**能认出调用方**的 User-Agent
    /// （拿 Genius 的 UA 去请求既失礼、也可能被 403）✓。
    private static let wikipediaSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "User-Agent": "EeveeSpotifyEvolved/1.0 (https://github.com/zbzxbg/EeveeSpotifyEvolved)",
        ]
        configuration.timeoutIntervalForRequest = 12
        return URLSession(configuration: configuration)
    }()

    /// 用哪个语言的维基（按 app 语言挑 zh / ja / en，其余落 en）→ **完整的主机名**。
    ///
    /// ⚠️⚠️**不是，它是坏的**。
    /// 这里原来只返回**语言码**（`"zh"`），而三处 URL 都是 `https://\(host)/…` 拼出来的
    /// ⇒ 拼成 `https://zh/wiki/Special:Search` —— 主机名只有一个 `zh`，DNS 都解析不了。
    /// 也就是说：那颗「在维基百科中打开」**从来没打开过**，`.wikipedia` 那一档也**从来没取到过词**
    /// （而且失败得无声无息，因为请求压根没发出去）。
    /// 主机名补全成 `<语言>.wikipedia.org` 才是维基。
    ///
    /// ⚠️ 仍然**共用同一个**判据（取词那条线与那颗按钮），免得两处漂。
    static func wikipediaHost() -> String {
        let language = String(Locale.preferredLanguages.first?.prefix(2) ?? "en").lowercased()
        return ["zh", "ja", "en"].contains(language)
            ? "\(language).wikipedia.org"
            : "en.wikipedia.org"
    }

    /// 维基百科那一版：`action=query&list=search` 找条目 → `rest_v1/page/summary` 取**首段**。
    ///
    /// ⚠️ 正文是 **CC BY-SA**：用了它**必须**署名 + 给许可链接（卡片右下角那行 + 那颗 Wikipedia 按钮）✓。
    /// 也因此它只是**选项之一**（默认见 `ArtistBioSourceKind.automatic`），不是主源。
    static func wikipediaBio(for artist: String, completion: @escaping (String?) -> Void) {
        let name = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              var components = URLComponents(string: "https://\(wikipediaHost())/w/api.php") else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: name),
            URLQueryItem(name: "srlimit", value: "1"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        fetchJSON(url, using: wikipediaSession, tag: "wikipedia search") { search in
            let hits = (search?["query"] as? [String: Any])?["search"] as? [[String: Any]]
            guard let title = hits?.first?["title"] as? String,
                  let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let summary = URL(string: "https://\(wikipediaHost())/api/rest_v1/page/summary/\(encoded)")
            else {
                writeDebugLog(
                    "[ArtistBio] wikipedia search → no article for this artist"
                        + " (\(hits?.count ?? 0) hit(s) in the response)"
                )
                completion(nil)
                return
            }
            writeDebugLog("[ArtistBio] wikipedia search → article \"\(title)\"")
            fetchJSON(summary, using: wikipediaSession, tag: "wikipedia summary") { payload in
                let extract = (payload?["extract"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                writeDebugLog("[ArtistBio] wikipedia summary → \(extract?.count ?? 0) char")
                completion((extract?.isEmpty ?? true) ? nil : extract)
            }
        }
    }

    /// 取这位艺人的简介（回调一律在**主线程**；取不到就是 nil）。
    static func geniusBio(for artist: String, completion: @escaping (String?) -> Void) {
        let name = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var components = URLComponents(string: "https://api.genius.com/search") else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        components.queryItems = [URLQueryItem(name: "q", value: name)]
        guard let url = components.url else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        fetchJSON(url, using: session, tag: "genius search") { search in
            guard let hits = (search?["response"] as? [String: Any])?["hits"] as? [[String: Any]] else {
                writeDebugLog("[ArtistBio] genius search → no hits in the response")
                completion(nil)
                return
            }
            writeDebugLog("[ArtistBio] genius search → \(hits.count) hit(s)")
            var artistID: Int?
            var fallbackID: Int?
            for hit in hits {
                guard let result = hit["result"] as? [String: Any] else { continue }
                if (hit["type"] as? String) == "artist",
                   let id = result["id"] as? Int,
                   let hitName = result["name"] as? String,
                   hitName.compare(name, options: .caseInsensitive) == .orderedSame {
                    artistID = id
                    break
                }
                if fallbackID == nil, let primary = result["primary_artist"] as? [String: Any] {
                    fallbackID = primary["id"] as? Int
                }
            }
            guard let id = artistID ?? fallbackID,
                  let detail = URL(string: "https://api.genius.com/artists/\(id)") else {
                writeDebugLog("[ArtistBio] genius search → no artist to ask for (name mismatch)")
                completion(nil)
                return
            }
            writeDebugLog(
                "[ArtistBio] genius → artist \(id)"
                    + (artistID == nil ? " (fell back to a song hit's primary artist)" : " (exact name match)")
            )
            fetchJSON(detail, using: session, tag: "genius artist \(id)") { payload in
                let artist = (payload?["response"] as? [String: Any])?["artist"] as? [String: Any]
                let description = artist?["description"] as? [String: Any]
                let plain = (description?["plain"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                writeDebugLog("[ArtistBio] genius artist \(id) → description \(plain?.count ?? 0) char")
                completion((plain?.isEmpty ?? true) ? nil : plain)
            }
        }
    }

    /// **找 `fetchArtistAboutForArtist:withCompletion:` 的宿主类**（一次性诊断，只为下一轮铺路）。
    ///
    /// 为什么要它： 是**按字母排的选择器表**（`:24502` 那一行只有选择器名），
    /// **没有"选择器 → 类"的映射** ✗ ⇒ 猜不出来。而运行时有 `objc_getClassList`：扫一遍、只读、
    /// 找到就打一行日志 ✓（零副作用）。
    ///
    /// 就能 hook 它 —— 把**完整正文**收下来（而不是像现在这样读收起态那个
    /// 大概被截断过的 label；`biographyText:withStyle:`（`dump:22624`）说明"收起/展开"是**样式**，
    /// 而 flag 里那条 `is_async_biography_truncation_enabled` 也说明截断是真实存在的）。
    static func reportArtistAboutFetcher() {
        let selector = NSSelectorFromString("fetchArtistAboutForArtist:withCompletion:")
        let count = objc_getClassList(nil, 0)
        guard count > 0 else { return }
        let buffer = UnsafeMutablePointer<AnyClass>.allocate(capacity: Int(count))
        defer { buffer.deallocate() }
        let filled = objc_getClassList(AutoreleasingUnsafeMutablePointer<AnyClass>(buffer), count)

        var instanceHits: [String] = []
        var classHits: [String] = []
        for index in 0..<Int(filled) {
            let candidate: AnyClass = buffer[index]
            if class_getInstanceMethod(candidate, selector) != nil {
                instanceHits.append(NSStringFromClass(candidate))
            } else if class_getClassMethod(candidate, selector) != nil {
                classHits.append(NSStringFromClass(candidate))
            }
        }
        let detail = instanceHits + classHits.map { $0 + " (class method)" }
        writeDebugLog(
            "[ArtistBio] artist-about fetcher — \(Int(filled)) class(es) scanned, "
                + (detail.isEmpty ? "no host found" : detail.joined(separator: ", "))
        )
    }

    /// 一次 GET → JSON。**日志与回调都在主线程**（底色/界面那边只认主线程；日志文件也不从后台线程写）。
    ///
    /// ⚠️ 名字**不能叫 `get`** —— `swift_member_check.py` 会把这种通用名当成"不该私有的短名"
    /// （实测一次白跑：25 条 `get` 报错，连别的文件的都一起翻出来）。
    /// - Parameter tag: 这一跳**是谁**（`genius search` / `genius artist 123` / `wikipedia search` …）。
    ///
    /// 这一行以前把前缀**写死成 "genius"**，于是维基百科那条失败
    /// 打出来是 `[ArtistBio] genius /w/api.php → HTTP 0` —— **指错了来源**（`/w/api.php` 是 MediaWiki）；
    /// 而且只在 `status != 200` 时才打、还把 URLSession 的 `error` **丢掉**（`{ data, response, _ in`）
    /// ⇒ `HTTP 0`（一个响应都没拿到）到底是 DNS、超时还是 TLS 失败，
    /// 现在：**每一次都打**（200 也打，带字节数），失败时带上 `error.localizedDescription`。
    private static func fetchJSON(
        _ url: URL,
        using client: URLSession = session,
        tag: String,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        client.dataTask(with: url) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var json: [String: Any]?
            if let data, let object = try? JSONSerialization.jsonObject(with: data) {
                json = object as? [String: Any]
            }
            let bytes = data?.count ?? 0
            let failure = error?.localizedDescription
            let host = url.host ?? "?"
            DispatchQueue.main.async {
                var line = "[ArtistBio] \(tag) \(host)\(url.path) → HTTP \(status), \(bytes) byte(s)"
                if let failure {
                    line += " — transport error: \(failure)"
                } else if status != 200 {
                    line += " — no usable response"
                }
                writeDebugLog(line)
                completion(json)
            }
        }.resume()
    }
}
