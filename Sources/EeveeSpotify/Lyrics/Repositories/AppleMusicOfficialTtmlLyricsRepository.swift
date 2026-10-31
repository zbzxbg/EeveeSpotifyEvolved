import Foundation

// Apple Music **官方** TTML 歌词源 —— 「实验 → 启用 Apple Music 官方 TTML 歌词」。
//
// 与 `AmllTtmlLyricsRepository` 的区别：那个走 AMLL 社区库（api.amll.dev），格式同样是 Apple 的 TTML，但内容是网友整理搬运的，覆盖率和逐词质量参差。这里拿的是 **Apple 自己**给的那份：逐词（`syllable-lyrics`）与逐行（`lyrics`）都取、译文/音译来自 `<iTunesMetadata>` 旁挂、背景人声是 `ttm:role="x-bg"`。这三样 `AmllTtmlParser` 本来就认（AMLL 的格式就是照 Apple 长的），所以不新增第二套解析/映射，只补"怎么把官方 TTML 拿到手"。
//
// 认证是唯一的硬门槛：Apple 没有公开歌词 API。实测 `search` 只要网页播放器的 developer token，而 `/lyrics` 未登录返回 **404**、`/me/storefront` 返回 **403** ⇒ 歌词那一步必须有**用户自己的 Apple Music 登录态**（浏览器 Cookie 里的 `media-user-token`）。所以只做两件事：
// ① developer token **自动**从 music.apple.com 的 JS bundle 里抓（JWT，约 70 天过期，带 `exp`，过期前 1 天重抓）；
// ② media-user-token 由**用户在设置里粘贴**（`UserDefaults.appleMusicMediaUserToken`，见 `AppleMusicTtml+UserDefaults.swift`）。
// 抓 token 参照 `zhaarey/apple-music-downloader` 的 `amp-api/token.go`，取歌词参照 `dropcreations/Manzana-Apple-Music-Lyrics` 的 `api/api.py`（`include[songs]=lyrics,syllable-lyrics` + `media-user-token` 头）。`amp-api.music.apple.com` 国内可直连，不需要换 host。
//
// 失败语义（与其它源一致）：404 / 没取到 ttml → `.noSuchSong`（静默降级，不弹窗）；400 → `.invalidSource`（include 写法不被接受，换第二种写法重试）；401/403 → `.invalidAppleMusicToken`（用户令牌坏了或过期，这个必须让用户看见一次）。

final class AppleMusicOfficialTtmlLyricsRepository: LyricsRepository {

    static let shared = AppleMusicOfficialTtmlLyricsRepository()

    // MARK: - 端点与常量

    private static let webBase = "https://music.apple.com"
    private static let apiBase = "https://amp-api.music.apple.com"

    /// 网页播放器的 JS bundle 路径（`/assets/index~bc39edf62f.js` 这种）。
    ///
    /// ⚠️ 刻意写成 `index[^/]+\.js` 而不是 `index~…`：`~` 那个分隔符是苹果当前 webpack 的
    /// 习惯（`apple-music-downloader` 的 `token.go` 就是按 `index~` 写的），但换一次打包器
    /// 就会变成 `index-abcdef.js`。`[^/]` 保证不会跨到别的路径，`+\.js` 靠回溯收口。
    private static let bundlePathPattern = "/assets/index[^/]+\\.js"
    /// 那个 bundle 里硬编码的 developer token（JWT，`iss` = `AMPWebPlay`）。
    private static let jwtPattern = "eyJ[A-Za-z0-9-_=]+\\.[A-Za-z0-9-_=]+\\.[A-Za-z0-9-_=]+"

    private static let developerTokenKey = "ngzhwm_appleMusicDeveloperToken"
    private static let developerTokenExpiryKey = "ngzhwm_appleMusicDeveloperTokenExpiry"
    private static let storefrontKey = "ngzhwm_appleMusicStorefront"
    private static let languageKey = "ngzhwm_appleMusicLanguage"
    private static let tokenFingerprintKey = "ngzhwm_appleMusicTokenFingerprint"

    /// 网页播放器用的 UA。Apple 对 `amp-api` 不做 UA 校验，但带上更接近"真的网页"。
    private static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        + " (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    /// 重试预算：与 AMLL 那条线一致（2 次、退避 0.6s）。单源模式下这是阻塞路径。
    private static let maxAttempts = 2
    private static let retryDelay: TimeInterval = 0.6

    /// developer token 提前多久算过期（秒）。JWT 的 `exp` 是苹果签的，按它减一天。
    private static let tokenExpirySafetyMargin: Double = 60 * 60 * 24

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    private class CachedLyrics {
        let dto: LyricsDto
        init(dto: LyricsDto) { self.dto = dto }
    }

    /// 按 Spotify Track ID 缓存**最终** DTO（含质检结论）：
    /// 换歌再换回来、或者同一首被两个入口同时问到时都不必再打三次请求。
    private let lyricsCache = NSCache<NSString, CachedLyrics>()

    // MARK: - LyricsRepository

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let mediaUserToken = UserDefaults.appleMusicMediaUserToken
        guard !mediaUserToken.isEmpty else {
            writeDebugLog(
                "[AMTTML] no media-user-token — the Apple Music official TTML source needs one"
                    + " (Settings > Experiments). Falling back to \"no lyrics\"."
            )
            throw LyricsError.missingAppleMusicToken
        }

        let cacheKey = query.spotifyTrackId as NSString
        if let cached = lyricsCache.object(forKey: cacheKey) {
            writeDebugLog("[AMTTML] cache hit for \(query.spotifyTrackId)")
            return cached.dto
        }

        writeDebugLog(
            "[AMTTML] fetching \"\(query.title)\" - \(query.primaryArtist)"
                + " (spotify \(query.spotifyTrackId))"
        )

        let context = try accountContext(mediaUserToken: mediaUserToken)
        writeDebugLog("[AMTTML] storefront=\(context.storefront) language=\(context.language)")

        let candidate = try pickCandidate(
            for: query,
            context: context,
            mediaUserToken: mediaUserToken
        )
        writeDebugLog(
            "[AMTTML] picked apple song \(candidate.id) \"\(candidate.title)\" — \(candidate.artist)"
                + " (\(candidate.durationMs)ms, word-timed=\(candidate.hasTimeSyncedLyrics ? "Y" : "N"))"
        )

        let ttml = try fetchTtml(
            songId: candidate.id,
            context: context,
            mediaUserToken: mediaUserToken
        )

        // ⚠️ 解析/映射这两段是**与 AMLL 共用**的代码（`AmllTtmlParser` / `AmllLyricsMapper`），
        // 所以它们自己的日志仍然打成 `[AMLL]` —— 看到 `[AMTTML]` 之后紧跟几行 `[AMLL]`
        // 属于正常，那是同一份 Apple 格式 TTML 在走同一条解析管线。
        writeDebugLog(
            "[AMTTML] parsing \(ttml.count) char of Apple TTML"
                + " (the [AMLL]-tagged lines that follow come from the shared TTML parser)"
        )
        let parsed = try AmllTtmlParser.parse(ttml)
        let dto = AmllLyricsMapper.makeDto(parsed, logTag: "AMTTML")

        guard !dto.lines.isEmpty else {
            writeDebugLog("[AMTTML] mapped to zero line — noSuchSong")
            throw LyricsError.noSuchSong
        }

        logSummary(parsed: parsed, dto: dto)
        lyricsCache.setObject(CachedLyrics(dto: dto), forKey: cacheKey)
        return dto
    }

    // MARK: - 账号上下文（storefront / 语言）

    private struct AccountContext {
        let storefront: String
        let language: String
    }

    /// `GET /v1/me/storefront` —— 用 `media-user-token` 问出这个账号的 storefront 与默认语言。
    ///
    /// 为什么必须先问：搜索与取词都要 `storefront`，而用户的账号可能在任意一区
    /// （`us` / `jp` / `cn` …）。写死一个区会导致"搜不到 / 搜到的是别的区的版本"。
    /// 这一步同时是**令牌有效性**的判据（无效 → 403）。
    ///
    /// 结果按"令牌指纹"缓存在 UserDefaults 里，避免**每次冷启动**都多打一次请求。
    private func accountContext(mediaUserToken: String) throws -> AccountContext {
        let fingerprint = Self.fingerprint(mediaUserToken)

        if let cached = Self.cachedAccountContext(fingerprint: fingerprint) {
            return cached
        }

        guard let url = URL(string: "\(Self.apiBase)/v1/me/storefront") else {
            throw LyricsError.invalidSource
        }

        let headers = try apiHeaders(mediaUserToken: mediaUserToken)
        let response = try perform(url, headers: headers, label: "/v1/me/storefront")
        let json = try jsonObject(response, label: "/v1/me/storefront")

        guard let data = json["data"] as? [[String: Any]],
              let first = data.first,
              let storefront = first["id"] as? String,
              !storefront.isEmpty else {
            writeDebugLog("[AMTTML] /v1/me/storefront answered without a storefront id")
            throw LyricsError.decodingError
        }

        let language = (first["attributes"] as? [String: Any])?["defaultLanguageTag"] as? String
        let context = AccountContext(
            storefront: storefront,
            language: (language?.isEmpty == false ? language! : Self.fallbackLanguage())
        )

        Self.storeAccountContext(context, fingerprint: fingerprint)
        return context
    }

    private static func cachedAccountContext(fingerprint: String) -> AccountContext? {
        let defaults = UserDefaults.container
        guard let storedFingerprint = defaults.string(forKey: tokenFingerprintKey),
              storedFingerprint == fingerprint,
              let storefront = defaults.string(forKey: storefrontKey),
              !storefront.isEmpty else { return nil }

        let language = defaults.string(forKey: languageKey)
            .flatMap { $0.isEmpty ? nil : $0 } ?? fallbackLanguage()
        return AccountContext(storefront: storefront, language: language)
    }

    private static func storeAccountContext(_ context: AccountContext, fingerprint: String) {
        let defaults = UserDefaults.container
        defaults.set(fingerprint, forKey: tokenFingerprintKey)
        defaults.set(context.storefront, forKey: storefrontKey)
        defaults.set(context.language, forKey: languageKey)
    }

    /// 令牌变了（设置页的 `onChange` 调的）⇒ 丢掉 storefront 缓存**与**歌词缓存。
    ///
    /// 歌词缓存也要丢：换账号后 storefront 可能从 `us` 变成 `jp`，同一首 Spotify 曲目
    /// 在新区里能拿到的是**另一个版本**的 TTML —— 留着旧缓存就等于"换了区还在放旧的词"。
    static func invalidateAccountCache() {
        UserDefaults.container.removeObject(forKey: tokenFingerprintKey)
        shared.lyricsCache.removeAllObjects()
    }

    /// 拿不到默认语言时的兜底：系统首选语言（iOS 上是 `zh-Hans-CN` 这种形态，Apple 也认）。
    private static func fallbackLanguage() -> String {
        let preferred = Locale.preferredLanguages.first
        guard let preferred, !preferred.isEmpty else { return "en-US" }
        return preferred
    }

    // MARK: - developer token（网页播放器，抓取 + 缓存）
    //
    // 网页播放器的 developer token。缓存里那份没到期就直接用。
    private func developerToken(forceRefresh: Bool) throws -> String {
        if !forceRefresh, let cached = Self.cachedDeveloperToken() {
            return cached
        }

        writeDebugLog("[AMTTML] scraping the web player developer token from music.apple.com")

        var page = try fetchText(Self.webBase, label: "music.apple.com")
        var assetPath = Self.firstMatch(Self.bundlePathPattern, in: page)

        if assetPath == nil {
            // 部分地区（本机实测是中国大陆出口）首页会先 302 到 `/<region>/new`；
            // 那个页面同样带 bundle 路径，但保险起见再用 `/us/browse` 试一次。
            page = try fetchText("\(Self.webBase)/us/browse", label: "music.apple.com/us/browse")
            assetPath = Self.firstMatch(Self.bundlePathPattern, in: page)
        }

        guard let assetPath else {
            writeDebugLog("[AMTTML] no /assets/index~*.js path in the music.apple.com HTML")
            throw LyricsError.unknownError
        }

        let script = try fetchText(Self.webBase + assetPath, label: assetPath)
        guard let token = Self.firstMatch(Self.jwtPattern, in: script), token.count > 100 else {
            writeDebugLog("[AMTTML] no JWT in \(assetPath) (\(script.count) char scanned)")
            throw LyricsError.unknownError
        }

        let expiry = Self.jwtExpiryUnix(token)
            ?? (Date().timeIntervalSince1970 + 60 * 60 * 24)
        let defaults = UserDefaults.container
        defaults.set(token, forKey: Self.developerTokenKey)
        defaults.set(expiry, forKey: Self.developerTokenExpiryKey)

        let formatted = Date(timeIntervalSince1970: expiry)
            .formatted(date: .numeric, time: .shortened)
        writeDebugLog(
            "[AMTTML] developer token acquired (\(token.count) char, expires \(formatted))"
        )
        return token
    }

    private static func cachedDeveloperToken() -> String? {
        let defaults = UserDefaults.container
        guard let token = defaults.string(forKey: developerTokenKey), !token.isEmpty,
              let expiry = defaults.object(forKey: developerTokenExpiryKey) as? Double,
              expiry - Date().timeIntervalSince1970 > tokenExpirySafetyMargin else {
            return nil
        }
        return token
    }

    /// 读 JWT 的 `payload.exp`（unix 秒）。解不出来返回 nil（调用方按"一天"兜底）。
    private static func jwtExpiryUnix(_ token: String) -> Double? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 {
            payload.append("=")
        }

        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiry = object["exp"] as? Double else {
            return nil
        }
        return expiry
    }

    /// 令牌指纹（FNV-1a）：只用来判断"缓存还是同一个账号的"，不写令牌本身。
    private static func fingerprint(_ token: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in token.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    // MARK: - 候选搜索

    private struct Candidate {
        let id: String
        let title: String
        let artist: String
        let album: String
        let durationMs: Int
        let hasTimeSyncedLyrics: Bool
    }

    /// 按「歌名 + 主艺人」搜 Apple Music，再在本地按歌名/艺人/时长打分挑一条。
    ///
    /// 官方搜索是**宽松**的（`term` 里塞两个词也可能只按其中一个检索），所以候选必须自己
    /// 打分才敢用 —— 口径与 `AmllTtmlLyricsRepository.fuzzySearchItem` 一致：
    /// **宁可没有词，也不能拿别的歌冒充**。
    private func pickCandidate(
        for query: LyricsSearchQuery,
        context: AccountContext,
        mediaUserToken: String
    ) throws -> Candidate {
        let title = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            writeDebugLog("[AMTTML] this track has no title — cannot search Apple Music")
            throw LyricsError.noSuchSong
        }

        var candidates = try search(
            term: Self.searchTerm(title: title, artist: query.primaryArtist),
            context: context,
            mediaUserToken: mediaUserToken
        )

        // 第二种搜索词：把 `(feat. …)` / `- Remastered` 这类后缀去掉再搜一次。
        // 只有第一次**一个候选都没有**时才走 —— 有候选就不该换搜索词（换了反而挑错）。
        let stripped = title.strippedTrackTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if candidates.isEmpty, !stripped.isEmpty, stripped != title {
            writeDebugLog("[AMTTML] no candidate for the exact title — searching \"\(stripped)\"")
            candidates = try search(
                term: Self.searchTerm(title: stripped, artist: query.primaryArtist),
                context: context,
                mediaUserToken: mediaUserToken
            )
        }

        guard !candidates.isEmpty else {
            writeDebugLog("[AMTTML] Apple Music returned no song for \"\(title)\"")
            throw LyricsError.noSuchSong
        }

        let wantedTitles = [Self.normalized(title), Self.normalized(stripped)]
            .filter { !$0.isEmpty }
        let wantedArtists = query.allArtistNames.map(Self.normalized).filter { !$0.isEmpty }
        let wantedDuration = query.durationMs

        var best: (candidate: Candidate, score: Int)?

        for candidate in candidates {
            let candidateTitles = [
                Self.normalized(candidate.title),
                Self.normalized(candidate.title.strippedTrackTitle)
            ].filter { !$0.isEmpty }

            let titleExact = candidateTitles.contains { wantedTitles.contains($0) }
            let titlePartial = !titleExact && candidateTitles.contains { candidateTitle in
                wantedTitles.contains { wanted in
                    candidateTitle.contains(wanted) || wanted.contains(candidateTitle)
                }
            }

            let artistName = Self.normalized(candidate.artist)
            let artistMatched = !wantedArtists.isEmpty && wantedArtists.contains { wanted in
                artistName.contains(wanted) || wanted.contains(artistName)
            }

            var score = 0
            var reasons: [String] = []

            if titleExact {
                score += 50
                reasons.append("title exact")
            } else if titlePartial {
                score += 20
                reasons.append("title partial")
            }
            if artistMatched {
                score += 25
                reasons.append("artist")
            }

            // 时长：Apple 与我们都会给 millisecond，拿它区分"同曲异版"（原版 / remaster / live）。
            // 差超过 15 秒直接判为另一版 —— 这一条比歌名可靠得多。
            if let wantedDuration, candidate.durationMs > 0 {
                let delta = abs(candidate.durationMs - wantedDuration)
                if delta <= 2_000 {
                    score += 15
                    reasons.append("duration ±\(delta)ms")
                } else if delta <= 6_000 {
                    score += 8
                    reasons.append("duration ±\(delta)ms")
                } else if delta <= 15_000 {
                    score += 2
                    reasons.append("duration ±\(delta)ms")
                } else {
                    writeDebugLog(
                        "[AMTTML] candidate \(candidate.id) rejected — duration off by \(delta)ms"
                            + " (\"\(candidate.title)\" / \(candidate.artist))"
                    )
                    continue
                }
            }

            // 敢用的门槛与 AMLL 那条线同一套：**歌名完全一致**，或者
            // 「歌名部分重合 **且** 歌手对得上」。只靠歌手、或只靠部分歌名都不够。
            let usable = titleExact || (titlePartial && artistMatched)
            writeDebugLog(
                "[AMTTML] candidate \(candidate.id) score=\(score)"
                    + (reasons.isEmpty ? " (rejected)" : " [\(reasons.joined(separator: ", "))]")
                    + " — \(candidate.title) / \(candidate.artist)"
            )

            guard usable else { continue }
            if score > (best?.score ?? Int.min) {
                best = (candidate, score)
            }
        }

        guard let best else {
            writeDebugLog("[AMTTML] no candidate passed the title/artist gate — noSuchSong")
            throw LyricsError.noSuchSong
        }

        writeDebugLog(
            "[AMTTML] best match \(best.candidate.id) (score \(best.score))"
        )
        return best.candidate
    }

    private static func searchTerm(title: String, artist: String) -> String {
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return artist.isEmpty ? title : "\(title) \(artist)"
    }

    private func search(
        term: String,
        context: AccountContext,
        mediaUserToken: String
    ) throws -> [Candidate] {
        var components = URLComponents(
            string: "\(Self.apiBase)/v1/catalog/\(context.storefront)/search"
        )
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "l", value: context.language)
        ]

        guard let url = components?.url else {
            writeDebugLog("[AMTTML] failed to build the search URL")
            throw LyricsError.invalidSource
        }

        let headers = try apiHeaders(mediaUserToken: mediaUserToken)
        let response = try perform(url, headers: headers, label: "search \"\(term)\"")
        let json = try jsonObject(response, label: "search")

        guard let results = json["results"] as? [String: Any],
              let songs = results["songs"] as? [String: Any],
              let data = songs["data"] as? [[String: Any]] else {
            return []
        }

        return data.compactMap { item in
            guard let id = item["id"] as? String,
                  let attributes = item["attributes"] as? [String: Any] else { return nil }

            return Candidate(
                id: id,
                title: attributes["name"] as? String ?? "",
                artist: attributes["artistName"] as? String ?? "",
                album: attributes["albumName"] as? String ?? "",
                durationMs: attributes["durationInMillis"] as? Int ?? 0,
                hasTimeSyncedLyrics: attributes["hasTimeSyncedLyrics"] as? Bool ?? false
            )
        }
    }

    // MARK: - 取 TTML
    //
    // 取这首 Apple 歌曲的 TTML。逐词优先，逐行兜底。
    //
    // `include` 的写法苹果那边两种都出现过（单资源的 `include=` 与类型化的
    // `include[songs]=`），所以两种都试；某种写法被拒（400）也算"换下一种"，不是致命错误。
    private func fetchTtml(
        songId: String,
        context: AccountContext,
        mediaUserToken: String
    ) throws -> String {
        // 第三种是**纯逐行**兜底：万一苹果把 `syllable-lyrics` 当成非法 include 值（400），
        // 前两种会一起失败 —— 那时至少还能拿到逐行 TTML，而不是"这首歌没词"。
        let variants: [(name: String, value: String)] = [
            ("include", "lyrics,syllable-lyrics"),
            ("include[songs]", "lyrics,syllable-lyrics"),
            ("include", "lyrics")
        ]
        let headers = try apiHeaders(mediaUserToken: mediaUserToken)

        for variant in variants {
            var components = URLComponents(
                string: "\(Self.apiBase)/v1/catalog/\(context.storefront)/songs/\(songId)"
            )
            components?.queryItems = [
                URLQueryItem(name: variant.name, value: variant.value),
                URLQueryItem(name: "l", value: context.language)
            ]

            guard let url = components?.url else { throw LyricsError.invalidSource }

            do {
                let response = try perform(
                    url,
                    headers: headers,
                    label: "songs/\(songId)"
                )
                let json = try jsonObject(response, label: "songs/\(songId)")

                if let ttml = Self.extractTtml(from: json, language: context.language) {
                    return ttml
                }
                writeDebugLog(
                    "[AMTTML] no ttml with \(variant.name)=\(variant.value) — trying the next form"
                )
            } catch let error as LyricsError {
                switch error {
                case .invalidSource, .noSuchSong:
                    // 400（写法不被接受）或 404（该区没有这首）—— 换下一种写法再试。
                    writeDebugLog(
                        "[AMTTML] \(variant.name)=\(variant.value) failed (\(error)) — trying the next form"
                    )
                    continue
                default:
                    throw error
                }
            }
        }

        writeDebugLog("[AMTTML] Apple returned no lyrics ttml for song \(songId) — noSuchSong")
        throw LyricsError.noSuchSong
    }

    /// 从 song 资源的 `relationships` 里取 TTML：`syllable-lyrics`（逐词）优先，`lyrics` 兜底。
    ///
    /// ⚠️ 载荷形态有**三种**（都见过/都有实现可对照，
    /// ① `attributes.ttml` —— 单语串（`dropcreations/Manzana...` 那个年代就是它）；
    /// ② `attributes.ttmlLocalizations` 是**字符串** —— 单语；
    /// ③ `attributes.ttmlLocalizations` 是 **`locale → ttml` 字典** —— 多语。
    /// 这一条是照 `Takpap/apple-music-lyrics` 的缓存模型定性的：它把
    /// `syllable-lyrics.data[0].attributes.ttmlLocalizations` 解成
    /// `String` **或** `[String: String]` 两种可能（见那边的 `TTMLLocalizations`）。
    /// 只认 ① 的话，新形态响应会"200 但取不到词" ⇒ 必须三种都试。
    private static func extractTtml(from json: [String: Any], language: String) -> String? {
        guard let data = json["data"] as? [[String: Any]],
              let song = data.first,
              let relationships = song["relationships"] as? [String: Any] else {
            return nil
        }

        for key in ["syllable-lyrics", "lyrics"] {
            guard let relationship = relationships[key] as? [String: Any],
                  let entries = relationship["data"] as? [[String: Any]] else { continue }

            for entry in entries {
                guard let attributes = entry["attributes"] as? [String: Any],
                      let ttml = pickTtml(from: attributes, language: language) else { continue }

                writeDebugLog("[AMTTML] using \(key) TTML (\(ttml.count) char)")
                return ttml
            }
        }

        return nil
    }

    /// 从一条 lyric 资源的 `attributes` 里取出 TTML（三种形态，见 `extractTtml`）。
    private static func pickTtml(from attributes: [String: Any], language: String) -> String? {
        if let raw = attributes["ttml"] as? String, !raw.isEmpty {
            return raw
        }

        guard let localizations = attributes["ttmlLocalizations"] else { return nil }

        if let raw = localizations as? String, !raw.isEmpty {
            return raw
        }

        guard let map = localizations as? [String: String], !map.isEmpty else { return nil }

        // ① 精确语言 → ② 前缀互相包含（`zh-Hans-CN` ↔ `zh-Hans`）→ ③ 字典序第一个非空。
        // ③ 必须有确定顺序：字典本身无序，直接取 `values.first` 会让同一首歌两次拿到不同语言。
        if let exact = map[language], !exact.isEmpty {
            writeDebugLog("[AMTTML] ttmlLocalizations exact locale \(language)")
            return exact
        }

        let lowered = language.lowercased()
        if let matched = map
            .sorted(by: { $0.key < $1.key })
            .first(where: { entry in
                let candidate = entry.key.lowercased()
                return candidate.hasPrefix(lowered) || lowered.hasPrefix(candidate)
            }),
           !matched.value.isEmpty {
            writeDebugLog("[AMTTML] ttmlLocalizations prefix locale \(matched.key)")
            return matched.value
        }

        if let fallback = map.sorted(by: { $0.key < $1.key }).first(where: { !$0.value.isEmpty }) {
            writeDebugLog("[AMTTML] ttmlLocalizations fallback locale \(fallback.key)")
            return fallback.value
        }

        return nil
    }

    // MARK: - 网络

    private struct RawResponse {
        let statusCode: Int
        let data: Data

        var bodyPreview: String {
            String(data: data, encoding: .utf8).map { String($0.prefix(240)) }
                ?? "<non-utf8 \(data.count) bytes>"
        }
    }

    private enum Outcome {
        case success(RawResponse)
        /// 服务侧问题（网络 / 超时 / 429 / 5xx）：值得退避重试，最终失败也不代表「没有歌词」。
        case retryable(reason: String, cause: LyricsError)
        /// 确定性错误（404 / 401 / 403 / 400）：已定性，不重试。
        case fatal(LyricsError)
    }

    /// 带 Bearer 的 JSON GET。重试判定与错误映射写在同一个地方 ——
    /// 否则"哪些错误值得再试"会散落在两层之间，很容易把 5xx 当成「查无此歌」。
    private func perform(
        _ url: URL,
        headers: [String: String],
        label: String
    ) throws -> RawResponse {
        var lastError: LyricsError = .unknownError

        for attempt in 0..<Self.maxAttempts {
            if attempt > 0 {
                writeDebugLog("[AMTTML] retrying in \(Self.retryDelay)s (attempt \(attempt + 1)/\(Self.maxAttempts))")
                Thread.sleep(forTimeInterval: Self.retryDelay)
            }

            switch attemptOnce(url, headers: headers, label: label) {
            case .success(let response):
                return response
            case .fatal(let error):
                throw error
            case .retryable(let reason, let cause):
                writeDebugLog(
                    "[AMTTML] \(label) attempt \(attempt + 1)/\(Self.maxAttempts) failed: \(reason)"
                )
                lastError = cause
            }
        }

        writeDebugLog(
            "[AMTTML] \(label) — giving up after \(Self.maxAttempts) attempts"
                + " (service-side problem, not \"no lyrics\")"
        )
        throw lastError
    }

    private func attemptOnce(
        _ url: URL,
        headers: [String: String],
        label: String
    ) -> Outcome {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?
        var statusCode = 0

        let task = session.dataTask(with: request) { data, response, error in
            responseData = data
            responseError = error
            if let http = response as? HTTPURLResponse { statusCode = http.statusCode }
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 20) == .timedOut {
            task.cancel()
            writeDebugLog("[AMTTML] request timed out for \(label)")
            return .retryable(reason: "timeout", cause: .unknownError)
        }

        if let responseError {
            writeDebugLog("[AMTTML] network error for \(label): \(responseError)")
            return .retryable(reason: "network", cause: .unknownError)
        }

        guard let data = responseData else {
            writeDebugLog("[AMTTML] empty response body for \(label)")
            return .retryable(reason: "empty body", cause: .unknownError)
        }

        let response = RawResponse(statusCode: statusCode, data: data)

        switch statusCode {
        case 200:
            return .success(response)
        case 404:
            // 注意：**未登录**时苹果对歌词资源也回 404（它不告诉你"这是权限问题"）。
            // 这里不把它当令牌错误 —— 令牌缺失在入口就挡掉了，走到这条 404 的多半是
            // 该区确实没有这首歌 / 没有歌词。
            writeDebugLog("[AMTTML] 404 for \(label)")
            return .fatal(.noSuchSong)
        case 401, 403:
            writeDebugLog(
                "[AMTTML] \(statusCode) for \(label) — media-user-token rejected or expired"
            )
            return .fatal(.invalidAppleMusicToken)
        case 400:
            writeDebugLog("[AMTTML] 400 Bad Request for \(label): \(response.bodyPreview)")
            return .fatal(.invalidSource)
        case 429:
            writeDebugLog("[AMTTML] 429 rate limited on \(label)")
            return .retryable(reason: "429 rate limited", cause: .unknownError)
        default:
            if (500...599).contains(statusCode) {
                writeDebugLog("[AMTTML] \(statusCode) server error for \(label): \(response.bodyPreview)")
                return .retryable(reason: "\(statusCode) server error", cause: .unknownError)
            }
            writeDebugLog("[AMTTML] unexpected status \(statusCode) for \(label): \(response.bodyPreview)")
            return .fatal(.unknownError)
        }
    }

    /// 抓 HTML/JS 用（token 那两步）。不走 `attemptOnce` 的状态码语义：
    /// 那边 403 = 令牌坏了，而这里 403 只可能是苹果的机器人防护/地区跳转。
    private func fetchText(_ urlString: String, label: String) throws -> String {
        guard let url = URL(string: urlString) else {
            writeDebugLog("[AMTTML] bad URL for \(label): \(urlString)")
            throw LyricsError.invalidSource
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?
        var statusCode = 0

        let task = session.dataTask(with: request) { data, response, error in
            responseData = data
            responseError = error
            if let http = response as? HTTPURLResponse { statusCode = http.statusCode }
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 20) == .timedOut {
            task.cancel()
            writeDebugLog("[AMTTML] \(label) timed out")
            throw LyricsError.unknownError
        }
        if let responseError {
            writeDebugLog("[AMTTML] \(label) network error: \(responseError)")
            throw LyricsError.unknownError
        }
        guard let data = responseData else {
            writeDebugLog("[AMTTML] \(label) returned nothing")
            throw LyricsError.unknownError
        }
        guard statusCode == 200 else {
            writeDebugLog("[AMTTML] \(label) HTTP \(statusCode)")
            throw LyricsError.unknownError
        }

        writeDebugLog("[AMTTML] \(label) -> \(data.count) bytes")
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func jsonObject(_ response: RawResponse, label: String) throws -> [String: Any] {
        guard let raw = try? JSONSerialization.jsonObject(with: response.data),
              let object = raw as? [String: Any] else {
            writeDebugLog("[AMTTML] \(label) did not decode as JSON: \(response.bodyPreview)")
            throw LyricsError.decodingError
        }
        return object
    }

    /// `amp-api` 的公共头。`Authorization` 是**开发者令牌**（抓来的），
    /// `media-user-token` 是**用户账号令牌**（设置里粘的）—— 两个不是一回事。
    private func apiHeaders(mediaUserToken: String) throws -> [String: String] {
        let developerToken = try self.developerToken(forceRefresh: false)

        return [
            "Authorization": "Bearer \(developerToken)",
            "Origin": Self.webBase,
            "Referer": "\(Self.webBase)/",
            "Accept": "application/json",
            "User-Agent": Self.userAgent,
            "media-user-token": mediaUserToken
        ]
    }

    // MARK: - 文本工具

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let matchedRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matchedRange])
    }

    /// 归一化：小写 + 只留字母与数字（丢掉空格、标点、全角符号）。
    /// CJK 与假名在 Unicode 里都算"字母" ⇒ 日文歌名不会被抹掉。
    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { character in
            character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        }
    }

    // MARK: - 日志

    private func logSummary(parsed: AmllTtmlResult, dto: LyricsDto) {
        let wordLines = dto.lines.filter { ($0.words?.count ?? 0) >= 2 }.count
        let translationCount = dto.translation?.lines.filter { !$0.isEmpty }.count ?? 0
        writeDebugLog(
            "[AMTTML] \(dto.lines.count) line(s), \(wordLines) word-level, "
                + "\(translationCount) translated, lang=\(dto.languageCode ?? parsed.language ?? "?")"
        )
        if let declared = parsed.declaredDurationMs, let lastEnd = parsed.lastLineEndMs {
            writeDebugLog(
                "[AMTTML] declared body dur \(declared)ms, last line end \(lastEnd)ms"
                    + " (neither is the audio length)"
            )
        }
    }
}
