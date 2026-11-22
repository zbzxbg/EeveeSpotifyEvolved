import Foundation

// AMLL 逐词歌词源（amll.dev）。
//
// 数据来源：`https://api.amll.dev/v1/lyrics/get?spotifyId=<trackID>`，**精确匹配优先** —— Spotify Track ID 是唯一入口，拿不到就抛 `.noSuchSong` 交给既有的 `geniusFallback`，猜错比没有更糟。
//
// 「歌词 → AMLL 模糊搜索」（默认**关**）：打开后精确那步失败时**再按歌名搜一次**（`/v1/lyrics/search?q=<歌名>` → 候选里挑一条 → `/v1/lyrics/get?id=<候选 id>`）。官方搜索很宽松（`q=あのね` 会把"風色Letter"也返回），所以候选要**自己打分**：登记过本曲 spotifyId 最强；其次歌名归一化后完全一致；"部分重合 + 歌手也对得上"才过闸。只靠歌手对得上、或只靠歌名部分重合**一律不要** —— 宁可没有词，也不能拿别的歌冒充。关掉时这一整条路不存在。
//
// 为什么用官方 API 而不是社区镜像：AMLL 的镜像站（bikonoo / stevexmh / dimeta / GDBA）都按**网易云 / QQ 音乐 ID** 建索引，而本项目播放上下文里只有 Spotify Track ID，没有可用的 URL 模板。
//
// 不做「按 TTML 自己的 dur 比时长」：TTML 的 `<body dur>` 与 lrclib 的 `duration` 都是
// 「最后一个歌词时间戳」，不是音频时长（末句唱完到歌曲结束差几十秒属正常），拿它做等值
// 比较是方法错误。精确那一步的身份判据只保留可声明的信号：文件内嵌的 spotifyId 命中本曲。
//
// 模糊那一步多一道**版本闸门**：搜索接口不返回时长，但条目里登记的网易云 id 查得到时长，
// 拿它和本曲比 ±8 秒（见 `durationMatches`）。同一首歌的对唱版 / 独唱版 / TV size 时长
// 差得很多，名字却完全一样 —— 只靠"歌名对上"会把另一个编曲的词套到本曲上。
//
// 错误分类：404 → 库里真没有 → `.noSuchSong`，静默降级不弹窗；429（官方限流，单 IP 均值 50 req/s）与 502（数据源不稳定或索引更新失败）是服务问题、不是「没有歌词」，退避重试、连续失败才抛错。这两个状态码不能混进 `.noSuchSong`，否则一次网络抖动就会被当成"这首歌没歌词"。
//
// 缓存：官方文档说通过 id / filename 取得的内容永久固定不变，建议长期缓存。这里按 `spotifyTrackId` 缓存最终 DTO（含质检结论），命中即跳过网络与解析。

class AmllTtmlLyricsRepository: LyricsRepository {

    static let shared = AmllTtmlLyricsRepository()

    /// API 基址。self-host 或走反代时可在设置里改（独立 UserDefault key，
    /// 因为 LyricsOptions 整体存在一个 key 里，加字段会破坏旧数据的解码）。
    static let defaultApiUrl = "https://api.amll.dev"
    static let apiUrlUserDefaultsKey = "ngzhwm_amllApiUrl"

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    private let session: URLSession

    private var apiUrl: String {
        let configured = UserDefaults.standard.string(forKey: Self.apiUrlUserDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configured, !configured.isEmpty else { return Self.defaultApiUrl }
        // 去掉结尾斜杠，避免拼出 //v1/lyrics/get。
        return configured.hasSuffix("/") ? String(configured.dropLast()) : configured
    }

    private class CachedLyrics {
        let dto: LyricsDto
        init(dto: LyricsDto) { self.dto = dto }
    }

    private let lyricsCache = NSCache<NSString, CachedLyrics>()

    /// 重试策略：最多 2 次尝试，退避 0.5s。
    /// 单源模式下这次调用发生在歌词加载的阻塞路径上（与其它源一致），
    /// 因此重试预算压到最小：只有网络/服务侧错误才重试，404 立即返回。
    private static let maxAttempts = 2
    private static let retryDelays: [TimeInterval] = [0.5]

    /// 模糊搜索最多试几条候选。每条可能多一次取词请求，单源预算只有几秒。
    private static let maxFuzzyCandidates = 3

    /// 模糊命中的版本闸门容差（毫秒）。与酷狗挑条目的 `lengthSlackMs` 同一把尺子。
    private static let fuzzyDurationSlackMs = 8000

    // MARK: - LyricsRepository

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let trackId = query.spotifyTrackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trackId.isEmpty else {
            writeDebugLog("[AMLL] empty Spotify track ID — noSuchSong")
            throw LyricsError.noSuchSong
        }

        // 译文语言：设置里填了就用它，留空则**跟设备语言**（见
        // `UserDefaults.amllEffectiveTranslationLanguage`）。
        // ⚠️ 必须进缓存键：同一首歌换语言时，命中旧缓存就会一直显示旧语言那一轨。
        let preferredTranslationLanguage = UserDefaults.amllEffectiveTranslationLanguage
        // 模糊开关也要进键：关掉之后，之前按模糊搜到的那一份不该再从缓存里被端出来。
        let fuzzyEnabled = UserDefaults.experimentsOptions.amllFuzzySearch ? "1" : "0"
        let cacheKey = "\(trackId)|\(preferredTranslationLanguage)|fuzzy\(fuzzyEnabled)" as NSString
        if let cached = lyricsCache.object(forKey: cacheKey) {
            writeDebugLog("[AMLL] cache hit for \(trackId)")
            return cached.dto
        }

        writeDebugLog("[AMLL] fetching \"\(query.title)\" - \(query.primaryArtist) (spotifyId \(trackId))")

        // ① **精确**：Spotify Track ID 是官方 API 的入口，这一段与以前逐字一致。
        do {
            let item = try fetchLyricsItem(trackId: trackId)
            let dto = try makeDto(
                item: item,
                trackId: trackId,
                enforceIdentity: true,
                translationLanguage: preferredTranslationLanguage
            )
            lyricsCache.setObject(CachedLyrics(dto: dto), forKey: cacheKey)
            return dto
        } catch let exactError {
            // ② **模糊**（「歌词 → AMLL 模糊搜索」，默认关）：精确查不到时按歌名再搜一次。
            //
            // ⚠️ 判据放在**仓库层**而不是调用方：这个仓库只在两种情况被叫到 ——
            // 「AMLL 优先」那一跳，或者用户把来源直接选成 AMLL ⇒ 设置页那句
            // "需要开启 AMLL 优先或歌词来源选择 AMLL"自动成立，不用再判一次。
            guard UserDefaults.experimentsOptions.amllFuzzySearch else { throw exactError }

            writeDebugLog("[AMLL] exact lookup failed (\(exactError)) — fuzzy search is ON, searching by name")

            let hits = (try? fuzzySearchCandidates(for: query)) ?? []
            var picked: (item: AmllSongItem, verified: Bool)?
            for hit in hits {
                let check = durationCheck(hit, trackMs: query.durationMs)
                if check == .mismatch {
                    writeDebugLog(
                        "[AMLL] fuzzy candidate id=\(hit.id) is a different arrangement"
                            + " (duration gate) — trying the next one"
                    )
                    continue
                }
                if let fetched = try? fetchLyricsItem(id: hit.id) {
                    picked = (fetched, check == .matches)
                    break
                }
            }
            guard let picked else {
                writeDebugLog("[AMLL] fuzzy search produced no usable candidate — noSuchSong")
                throw exactError
            }

            // ⚠️ 模糊命中是**按名字**认的 ⇒ 身份复核要关掉（那个文件当然不带本曲的 spotifyId）。
            // 换来的是 `fuzzySearchCandidates` 的打分闸门与 `durationCheck` 的版本闸门：
            // 歌名对不上、或者时长对不上（另一个编曲）就根本不会被选中。
            var dto = try makeDto(
                item: picked.item,
                trackId: trackId,
                enforceIdentity: false,
                translationLanguage: preferredTranslationLanguage
            )
            // 时长闸门**查到并对上**的，不再是"猜的"：它是按曲目时长验证过的同一版本，
            // 自动优选里与"源自己的曲目 id 命中"同档。只有查不到时长（没有 ncm id /
            // 网络失败）的模糊命中才保留"猜的"标记（见 `LyricsDto.isFuzzyMatch`）。
            dto.isFuzzyMatch = !picked.verified
            if picked.verified {
                writeDebugLog("[AMLL] fuzzy hit verified by duration — treating it as an exact match")
            }
            lyricsCache.setObject(CachedLyrics(dto: dto), forKey: cacheKey)
            return dto
        }
    }

    /// 一条拿到的条目 → DTO。三条"没有可用歌词"的判定集中在这里（精确 / 模糊共用）。
    ///
    /// - Parameter enforceIdentity: 精确那一跳传 true —— TTML 里若明确登记了 spotifyIds
    /// 却不含本曲，说明后端匹配错了，宁可不要；模糊那一跳传 false（见调用点）。
    /// - Parameter translationLanguage: 用户指定的译文语言（空 = 解析层原来那套优先级）。
    private func makeDto(
        item: AmllSongItem,
        trackId: String,
        enforceIdentity: Bool,
        translationLanguage: String
    ) throws -> LyricsDto {
        guard let ttml = item.lyrics, !ttml.isEmpty else {
            writeDebugLog("[AMLL] response carried no lyrics payload — noSuchSong")
            throw LyricsError.noSuchSong
        }

        let parsed = try AmllTtmlParser.parse(ttml, translationLanguage: translationLanguage)

        // 身份复核：官方 API 已按 spotifyId 匹配，理论上必然命中；但后端存在
        // 「数据源不稳定 / 索引更新失败」的已知问题，若返回的条目明确登记了
        // Spotify ID 却不含本曲，说明匹配错了 —— 宁可不要。
        if enforceIdentity, !parsed.spotifyIds.isEmpty, !parsed.spotifyIds.contains(trackId) {
            writeDebugLog(
                "[AMLL] identity check failed — file declares spotifyIds=\(parsed.spotifyIds.prefix(3)) but track is \(trackId)"
            )
            throw LyricsError.noSuchSong
        }

        // （Q6 清点第 ① 条）：把**歌词作者**（AMLL 的 `authorUsernames.first`）交给
        // mapper 去写署名 —— 这一路以前只进日志，的署名永远是裸的源名。
        let dto = AmllLyricsMapper.makeDto(parsed, authorUsername: item.primaryAuthorUsername)

        guard !dto.lines.isEmpty else {
            writeDebugLog("[AMLL] mapped to zero line — noSuchSong")
            throw LyricsError.noSuchSong
        }

        logSummary(item: item, parsed: parsed, dto: dto)
        return dto
    }

    // MARK: - 网络
    //
    // 一次请求的结果。重试判定必须和错误映射写在同一个地方 ——
    // 否则「哪些错误值得再试」会散落在两层之间，很容易把 502 当成「查无此歌」。
    private enum FetchOutcome {
        case success(AmllSongItem)
        /// 服务侧问题（网络 / 超时 / 429 / 5xx）：值得退避重试，最终失败也不代表「没有歌词」。
        case retryable(reason: String, cause: LyricsError)
        /// 确定性错误（404 / 参数错误 / 解析失败）：已抛出，不重试。
        case fatal(LyricsError)
    }

    private func fetchLyricsItem(trackId: String) throws -> AmllSongItem {
        try fetchItem(
            queryItems: [URLQueryItem(name: "spotifyId", value: trackId)],
            label: trackId
        )
    }

    /// 模糊搜索命中的那一条。官方 API 也接受按 `id` 取（`GET /v1/lyrics/get?id=…`，
    /// 与 `spotifyId` 那条返回同一个 `data` 结构）—— 不新增第二套取词/解析路径。
    private func fetchLyricsItem(id: Int) throws -> AmllSongItem {
        try fetchItem(
            queryItems: [URLQueryItem(name: "id", value: String(id))],
            label: "id \(id)"
        )
    }

    private func fetchItem(queryItems: [URLQueryItem], label: String) throws -> AmllSongItem {
        var lastError: LyricsError = .unknownError

        for attempt in 0..<Self.maxAttempts {
            if attempt > 0 {
                let delay = Self.retryDelays[min(attempt - 1, Self.retryDelays.count - 1)]
                writeDebugLog("[AMLL] retrying in \(delay)s (attempt \(attempt + 1)/\(Self.maxAttempts))")
                Thread.sleep(forTimeInterval: delay)
            }

            switch performGet(queryItems: queryItems, label: label) {
            case .success(let item):
                return item
            case .fatal(let error):
                throw error
            case .retryable(let reason, let cause):
                writeDebugLog("[AMLL] attempt \(attempt + 1)/\(Self.maxAttempts) failed: \(reason)")
                lastError = cause
            }
        }

        writeDebugLog("[AMLL] giving up after \(Self.maxAttempts) attempts — service unavailable, not \"no lyrics\"")
        throw lastError
    }

    private func performGet(queryItems: [URLQueryItem], label: String) -> FetchOutcome {
        guard var components = URLComponents(string: "\(apiUrl)/v1/lyrics/get") else {
            writeDebugLog("[AMLL] invalid API base URL: \(apiUrl)")
            return .fatal(.invalidSource)
        }
        // 用 queryItems 而不是字符串拼接：自建镜像的基址可能自带 query，
        // 直接拼会把参数塞进错误的位置。
        components.queryItems = queryItems

        guard let url = components.url else {
            writeDebugLog("[AMLL] failed to build request URL from base: \(apiUrl)")
            return .fatal(.invalidSource)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "EeveeSpotify v\(EeveeSpotify.version) https://github.com/zbzxbg/EeveeSpotifyEvolved",
            forHTTPHeaderField: "User-Agent"
        )

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

        if semaphore.wait(timeout: .now() + 15) == .timedOut {
            task.cancel()
            writeDebugLog("[AMLL] request timed out for \(label)")
            return .retryable(reason: "timeout", cause: .unknownError)
        }

        if let responseError {
            writeDebugLog("[AMLL] network error for \(label): \(responseError)")
            return .retryable(
                reason: "network \(responseError.localizedDescription)",
                cause: .unknownError
            )
        }

        guard let data = responseData else {
            writeDebugLog("[AMLL] empty response body for \(label)")
            return .retryable(reason: "empty body", cause: .unknownError)
        }

        let bodyPreview = String(data: data, encoding: .utf8)?.prefix(200)
            ?? "<non-utf8 \(data.count) bytes>"

        switch statusCode {
        case 200:
            break
        case 404:
            writeDebugLog("[AMLL] 404 — no lyrics for \(label)")
            return .fatal(.noSuchSong)
        case 400:
            // 参数校验失败（例如自建镜像不接受 spotifyId）。配置问题，重试无用。
            writeDebugLog("[AMLL] 400 Bad Request for \(label): \(bodyPreview)")
            return .fatal(.invalidSource)
        case 429:
            writeDebugLog("[AMLL] 429 rate limited")
            return .retryable(reason: "429 rate limited", cause: .unknownError)
        case 502, 503, 504:
            writeDebugLog("[AMLL] \(statusCode) backend unstable: \(bodyPreview)")
            return .retryable(reason: "\(statusCode) backend unstable", cause: .unknownError)
        default:
            if (500...599).contains(statusCode) {
                writeDebugLog("[AMLL] \(statusCode) server error: \(bodyPreview)")
                return .retryable(reason: "\(statusCode) server error", cause: .unknownError)
            }
            writeDebugLog("[AMLL] unexpected status \(statusCode): \(bodyPreview)")
            return .fatal(.unknownError)
        }

        // 成功响应结构：{"status":200,"data":{...}}
        struct GetEnvelope: Decodable {
            var status: Int?
            var data: AmllSongItem?
        }

        let envelope: GetEnvelope
        do {
            envelope = try JSONDecoder().decode(GetEnvelope.self, from: data)
        } catch {
            writeDebugLog("[AMLL] failed to decode envelope: \(error); body: \(bodyPreview)")
            return .fatal(.decodingError)
        }

        guard let item = envelope.data else {
            writeDebugLog("[AMLL] 200 but no data field: \(bodyPreview)")
            return .fatal(.decodingError)
        }

        writeDebugLog(
            "[AMLL] matched id=\(item.id.map(String.init) ?? "?") file=\(item.filename ?? "?") author=\(item.primaryAuthorUsername ?? "?")"
        )
        return .success(item)
    }

    // MARK: - 模糊搜索（「歌词 → AMLL 模糊搜索」）
    //
    // `/v1/lyrics/search?q=<歌名>` 的一条候选。
    //
    // 官方搜索是**宽松**的（`q=あのね` 会连"風色Letter"一起返回）⇒ 候选必须自己打分挑
    // （见 `fuzzySearchCandidates`），不能拿了就用。
    struct AmllSearchItem: Decodable {
        let id: Int
        let filename: String?
        let musicNames: [String]?
        let artistNames: [String]?
        let albumNames: [String]?
        /// 这一条登记过的 Spotify 曲目 id —— 命中本曲是最强证据（+100）。
        let spotifyIds: [String]?
        /// 这一条登记过的网易云歌曲 id —— 用来查"这首歌到底多长"（版本闸门，见 `durationMatches`）。
        let ncmMusicIds: [String]?
    }

    /// 按歌名搜一次（同步，与 `performGet` 同一套 URLSession / 15s 上限）。
    private func searchItems(query: String) throws -> [AmllSearchItem] {
        guard var components = URLComponents(string: "\(apiUrl)/v1/lyrics/search") else {
            writeDebugLog("[AMLL] invalid API base URL: \(apiUrl)")
            throw LyricsError.invalidSource
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]

        guard let url = components.url else {
            writeDebugLog("[AMLL] failed to build the search URL from base: \(apiUrl)")
            throw LyricsError.invalidSource
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "EeveeSpotify v\(EeveeSpotify.version) https://github.com/zbzxbg/EeveeSpotifyEvolved",
            forHTTPHeaderField: "User-Agent"
        )

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

        if semaphore.wait(timeout: .now() + 15) == .timedOut {
            task.cancel()
            writeDebugLog("[AMLL] fuzzy search timed out")
            throw LyricsError.unknownError
        }
        if let responseError {
            writeDebugLog("[AMLL] fuzzy search network error: \(responseError)")
            throw LyricsError.unknownError
        }
        guard let data = responseData else {
            writeDebugLog("[AMLL] fuzzy search returned an empty body")
            throw LyricsError.unknownError
        }
        guard statusCode == 200 else {
            let body = String(data: data, encoding: .utf8)?.prefix(200) ?? "<non-utf8 \(data.count) bytes>"
            writeDebugLog("[AMLL] fuzzy search HTTP \(statusCode): \(body)")
            throw LyricsError.unknownError
        }

        // 搜索的响应外壳与取词那条同形：{"status":200,"data":{"items":[…]}}
        struct SearchEnvelope: Decodable {
            struct Payload: Decodable {
                var items: [AmllSearchItem]?
            }
            var status: Int?
            var data: Payload?
        }

        guard let envelope = try? JSONDecoder().decode(SearchEnvelope.self, from: data) else {
            writeDebugLog("[AMLL] fuzzy search response did not decode")
            throw LyricsError.decodingError
        }
        return envelope.data?.items ?? []
    }

    /// 从搜索候选里挑出**敢用**的几条（按分数从高到低）。
    ///
    /// 打分（阈值 20）：
    /// · 登记过本曲 spotifyId ............ +100（最强，直接用）
    /// · 歌名归一化后**完全相同** ........ +20（单这一条就够）
    /// · 歌名只是**部分**重合 ............ +12
    /// · 任一歌手名对得上 ................. +10
    ///
    /// ⇒ 只有"歌名完全对上"或"部分重合 **且** 歌手也对上"才过闸；光歌手对得上（10）
    /// 或光歌名部分重合（12）**不够** —— 模糊搜索可以找得宽，但不能拿别的歌冒充本曲。
    /// （`q` 那边不支持"歌名 + 歌手"一次给两样：`q=あのね ナナツカゼ` 返回 0 条，
    /// 所以只能取歌名、在本地按歌手打分。）
    ///
    /// 返回**多条**而不是一条：同名的另一个编曲/版本可能排在前面，由调用方用
    /// `durationMatches` 的版本闸门逐条筛（见 `getLyrics` 的模糊分支）。
    private func fuzzySearchCandidates(for query: LyricsSearchQuery) throws -> [AmllSearchItem] {
        let title = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            writeDebugLog("[AMLL] fuzzy search skipped — this track has no title to search by")
            return []
        }

        let items = try searchItems(query: title)
        writeDebugLog("[AMLL] fuzzy search \"\(title)\" → \(items.count) candidate(s)")
        guard !items.isEmpty else { return [] }

        let trackId = query.spotifyTrackId.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantedTitle = Self.normalized(title)
        let wantedArtists = query.allArtistNames.map(Self.normalized).filter { !$0.isEmpty }

        var scored: [(item: AmllSearchItem, score: Int, order: Int)] = []

        for (order, item) in items.enumerated() {
            var score = 0
            var reasons: [String] = []

            if !trackId.isEmpty, let ids = item.spotifyIds, ids.contains(trackId) {
                score += 100
                reasons.append("same spotifyId")
            }

            let names = (item.musicNames ?? []).map(Self.normalized)
            let titleExact = !wantedTitle.isEmpty && names.contains(wantedTitle)
            let titlePartial = !wantedTitle.isEmpty
                && names.contains { $0.contains(wantedTitle) || wantedTitle.contains($0) }

            if titleExact {
                score += 20
                reasons.append("title exact")
            } else if titlePartial {
                score += 12
                reasons.append("title partial")
            }

            var artistMatched = false
            if !wantedArtists.isEmpty {
                let artists = (item.artistNames ?? []).map(Self.normalized)
                artistMatched = artists.contains { artist in
                    wantedArtists.contains { wanted in
                        artist.contains(wanted) || wanted.contains(artist)
                    }
                }
                if artistMatched {
                    score += 10
                    reasons.append("artist match")
                }
            }

            let usable = score >= 20
            writeDebugLog(
                "[AMLL] candidate id=\(item.id) score=\(score)"
                    + (reasons.isEmpty ? " (rejected)" : " [\(reasons.joined(separator: ", "))]")
                    + " — \(item.musicNames?.first ?? "?") / \(item.artistNames?.first ?? "?")"
            )

            guard usable else { continue }
            scored.append((item, score, order))
        }

        let ranked = scored
            .sorted { left, right in
                if left.score != right.score { return left.score > right.score }
                return left.order < right.order
            }
            .prefix(Self.maxFuzzyCandidates)
            .map { $0.item }
        guard !ranked.isEmpty else { return [] }
        writeDebugLog("[AMLL] fuzzy picks \(ranked.count): ids \(ranked.map { $0.id })")
        return ranked
    }

    /// 模糊命中的版本校验结果。
    private enum DurationCheck: Equatable {
        /// 查到了时长，且和本曲在容差内。
        case matches
        /// 查到了时长，但对不上 —— 另一个编曲/版本。
        case mismatch
        /// 查不到（没有网易云 id / 网络失败）：不拦，但也不能当成"验证过".
        case unknown
    }

    /// 模糊命中要不要因为"版本对不上"被丢掉。
    ///
    /// AMLL 的搜索接口不返回时长，TTML 的 `<body dur>` 又只是"最后一句歌词的时间戳"
    /// （不是音频长度）—— 所以拿 TTML 自己比是方法错误。但 AMLL 收下的条目几乎都登记了
    /// 一个网易云 id，那首歌的时长是公开可查的：拿它和本曲比 ±8 秒
    /// （与 `KuGouLyricsRepository` 挑条目的 `lengthSlackMs` 同一把尺子）。
    /// 对不上 = 另一个编曲/版本，宁可不给词也不要把时间轴对不上的词套上去。
    ///
    /// 查不到时长时返回 `.unknown`：**不拦**（宁可保留"按名字猜"），同时保留
    /// `isFuzzyMatch = true` —— 它只是没被验证过，不该和验证过的命中同档。
    private func durationCheck(_ item: AmllSearchItem, trackMs: Int?) -> DurationCheck {
        guard let trackMs, trackMs > 0,
              let songId = item.ncmMusicIds?.first, !songId.isEmpty else { return .unknown }
        guard let remoteMs = NeteaseSongDuration.durationMs(forSongId: songId) else { return .unknown }
        let matches = abs(remoteMs - trackMs) <= Self.fuzzyDurationSlackMs
        if !matches {
            writeDebugLog(
                "[AMLL] duration \(remoteMs)ms vs track \(trackMs)ms — this entry is another version"
            )
        }
        return matches ? .matches : .mismatch
    }

    /// 归一化：小写 + 只留字母与数字（丢掉空格、标点、全角符号）。
    /// CJK 与假名在 Unicode 里都算"字母" ⇒ 日文名不会被抹掉。
    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { character in
            character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        }
    }

    // MARK: - 日志

    private func logSummary(item: AmllSongItem, parsed: AmllTtmlResult, dto: LyricsDto) {
        let wordLines = dto.lines.filter { ($0.words?.count ?? 0) >= 2 }.count
        let translationCount = dto.translation?.lines.filter { !$0.isEmpty }.count ?? 0
        // 官方罗马字现在是**独立一行**（`officialRomanizedLines`），不再替换正文 ——
        // 只按 `dto.romanization` 判会把"已经收下"说成"没生效"。
        let hasOfficialRow = !dto.officialRomanizedLines.isEmpty
        let romanizationState: String
        if hasOfficialRow {
            romanizationState = "official row"
        } else if dto.romanization == .romanized {
            romanizationState = "official (merged into the text)"
        } else if dto.romanization == .canBeRomanized {
            romanizationState = "deferred"
        } else {
            romanizationState = "none"
        }
        writeDebugLog(
            "[AMLL] \(dto.lines.count) line(s), \(wordLines) word-level, "
                + "\(translationCount) translated, romanization=\(romanizationState), "
                + "lang=\(dto.languageCode ?? "?")"
        )
        if parsed.hasRomanization, !hasOfficialRow, dto.romanization != .romanized {
            writeDebugLog(
                "[AMLL] TTML carries x-roman but it was not kept — covered less than half,"
                    + " the Japanese romanization switch is off, or the song is not Japanese"
            )
        }
        if let declared = parsed.declaredDurationMs, let lastEnd = parsed.lastLineEndMs {
            writeDebugLog("[AMLL] declared dur \(declared)ms, last line end \(lastEnd)ms (neither is audio length)")
        }
    }
}

/// AMLL 模糊命中的版本校验：查一个网易云歌曲 id 的时长。
///
/// 只用于"同名不同编曲"这一种错配。走公开的 `api/song/detail`（不需要登录，也不走
/// `NeteaseLyricsRepository` 那套 weapi 加密），只读 `duration` 一个字段。
/// 一个 id 一份内存缓存；查不到（网络/结构变化）就返回 nil —— 调用方把 nil 当成
/// "无法校验、不拦"，网络问题不能把模糊搜索本身废掉。
enum NeteaseSongDuration {

    private static let cache = NSCache<NSString, NSNumber>()

    /// 只查一个 id 的时长，所以超时压到 3 秒：这条请求在模糊搜索的链路上，
    /// 不能让一个慢接口把整条取词预算吃掉。
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static func durationMs(forSongId songId: String) -> Int? {
        let key = songId as NSString
        if let cached = cache.object(forKey: key) {
            return cached.intValue
        }
        // ids 是数组字面量，方括号必须百分号编码。
        guard let url = URL(
            string: "https://music.163.com/api/song/detail/?id=\(songId)&ids=%5B\(songId)%5D"
        ) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")

        let semaphore = DispatchSemaphore(value: 0)
        var duration: Int?
        session.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            guard let data,
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let root = object as? [String: Any],
                  let songs = root["songs"] as? [[String: Any]],
                  let first = songs.first,
                  let milliseconds = (first["duration"] as? NSNumber)?.intValue,
                  milliseconds > 0 else { return }
            duration = milliseconds
        }.resume()

        if semaphore.wait(timeout: .now() + 3) == .timedOut {
            return nil
        }
        guard let duration, duration > 0 else { return nil }
        cache.setObject(NSNumber(value: duration), forKey: key)
        return duration
    }
}
