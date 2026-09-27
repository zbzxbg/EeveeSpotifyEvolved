import Foundation

class GeniusLyricsRepository: LyricsRepository {
    private let jsonDecoder: JSONDecoder
    private let apiUrl = "https://api.genius.com"
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "X-Genius-iOS-Version": "6.21.0",
            "X-Genius-Logged-Out": "true",
            "User-Agent": "Genius/1109 \(URLSessionHelper.CFNetworkVersion) \(URLSessionHelper.DarwinVersion)"
        ]

        session = URLSession(configuration: configuration)

        jsonDecoder = JSONDecoder()
        jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    /// 一次请求的产物。
    ///
    /// 为什么要带着 `statusCode` / `bodyHead` 一起回传：`Search returned 0 hit(s)`
    /// 这一句以前既可能是"Genius 真没这首歌"，也可能是"接口根本没答上来（401/429/5xx）
    /// 或返回了别的形状"。2026-09-27 日志 15 的两首 0 命中（Inferno Rise、MONTAGEM NUAR）
    /// 就没法判断是哪一种 —— 只有状态码能分开这两件事。
    private struct GeniusHTTPResult {
        let response: GeniusDataResponse?
        let statusCode: Int
        let bodyHead: String
    }

    private func perform(
        _ path: String,
        query: [String:Any] = [:]
    ) throws -> GeniusHTTPResult {
        var stringUrl = "\(apiUrl)\(path)"

        if !query.isEmpty {
            let queryString = query.queryString
            stringUrl += "?\(queryString)"
        }

        // 以前这里是 `URL(string:)!` —— 查询里带空格/特殊字符时崩在设备上，
        // 日志里什么都没有。改成显式抛错，至少留一行。
        guard let url = URL(string: stringUrl) else {
            writeDebugLog("[Genius] Invalid URL for \(path): \(stringUrl)")
            throw LyricsError.decodingError
        }

        let request = URLRequest(url: url)

        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var httpResponse: HTTPURLResponse?
        var error: Error?

        let task = session.dataTask(with: request) { body, response, err in
            error = err
            data = body
            httpResponse = response as? HTTPURLResponse
            semaphore.signal()
        }

        task.resume()

        // Bound every request so a hung Genius connection cannot stall lyrics
        // loading forever (and, with candidate fallback, never yields lyrics).
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            task.cancel()
            writeDebugLog("[Genius] \(path) timed out after 10s")
            throw LyricsError.unknownError
        }

        if let error = error {
            writeDebugLog("[Genius] \(path) transport error: \(error)")
            throw error
        }

        let statusCode = httpResponse?.statusCode ?? 0
        let bodyHead = data.flatMap {
            String(data: $0.prefix(300), encoding: .utf8)
        } ?? "<no body>"

        // 非 200 一定要留痕（断言被限流 / 需要 token / 网关错误都长这样）。
        if statusCode != 200 {
            writeDebugLog(
                "[Genius] \(path) HTTP \(statusCode) len=\(data?.count ?? 0) body=\(bodyHead)"
            )
        }

        guard let data = data,
              let rootResponse = try? jsonDecoder.decode(GeniusRootResponse.self, from: data) else {
            writeDebugLog(
                "[Genius] \(path) decode failed — HTTP \(statusCode) len=\(data?.count ?? 0) body=\(bodyHead)"
            )
            throw LyricsError.decodingError
        }

        return GeniusHTTPResult(
            response: rootResponse.response,
            statusCode: statusCode,
            bodyHead: bodyHead
        )
    }

    //

    private func searchSong(_ query: String) throws -> [GeniusHit] {
        let result = try perform("/search/song", query: ["q": query])

        guard case .sections(let sectionsResponse)? = result.response else {
            writeDebugLog(
                "[Genius] /search/song returned a non-sections shape — HTTP \(result.statusCode) body=\(result.bodyHead)"
            )
            throw LyricsError.decodingError
        }

        // Genius may return more than one section. Do not discard hits from later sections.
        return sectionsResponse.sections.flatMap(\.hits)
    }

    private func getSongInfo(_ songId: Int) throws -> GeniusSong {
        let result = try perform("/songs/\(songId)", query: ["text_format": "plain"])

        guard case .song(let songResponse)? = result.response else {
            writeDebugLog(
                "[Genius] /songs/\(songId) returned a non-song shape — HTTP \(result.statusCode) body=\(result.bodyHead)"
            )
            throw LyricsError.decodingError
        }

        return songResponse.song
    }

    //

    /// 上游思路：标题子串命中就取第一个命中的，否则取第一个结果（信任 Genius 相关度）。
    private func mostRelevantHitResult(
        hits: [GeniusHit],
        strippedTitle: String
    ) -> GeniusHitResult {
        let results = hits.map { $0.result }
        let matchingByTitle = results.filter {
            $0.title.containsInsensitive(strippedTitle)
        }
        if matchingByTitle.isEmpty {
            return results.first!
        }
        return matchingByTitle.first!
    }

    /// 第一枪（`标题 + 歌手`）0 命中时的第二枪：只拿标题搜，但**必须有一条命中歌手名**
    /// 才采用。
    ///
    /// 依据（2026-09-26 日志 3 / 2026-09-27 日志 15）：`标题 + 歌手`这种拼接查询在
    /// Genius 上会整条 0 命中 —— `Notes of Color / Yono`、`Inferno Rise / IKAN`、
    /// `MONTAGEM NUAR / LXNGVX` 都是这样，而 0 命中当前就等于"这首歌没词"（直接占位）。
    /// 同一份日志里另有大量"标题+歌手一条就中"的例子，所以只在这一枪已经失败的分支上
    /// 多打一次请求，不影响任何现在能出词的歌。
    ///
    /// 为什么要卡歌手：Genius 只按标题对齐会张冠李戴（同名歌太多），
    /// 与仓库里其它源的口径一致 ——"猜错比没有更糟"
    /// （见 `AmllTtmlLyricsRepository` 顶部注释）。
    private func titleOnlyHits(
        strippedTitle: String,
        primaryArtist: String
    ) throws -> [GeniusHit] {
        guard !strippedTitle.isEmpty, !primaryArtist.isEmpty else { return [] }

        let hits = try searchSong(strippedTitle)
        writeDebugLog("[Genius] Title-only retry returned \(hits.count) hit(s)")

        let artistMatched = hits.filter {
            $0.result.artistNames.containsInsensitive(primaryArtist)
        }

        guard !artistMatched.isEmpty else {
            writeDebugLog(
                "[Genius] Title-only retry matched no artist — ignored (a wrong match is worse than nothing)"
            )
            return []
        }

        return artistMatched
    }

    /// 日志用：把 `lyrics.plain` 的开头压成**一行**（换行转义），空串给 `<empty>`。
    ///
    /// 只用于 `No usable lyrics` 那条诊断 —— 要能一眼看出是"空词"、"只有标注"还是"别的歌"。
    private func plainHeadForLog(_ plain: String, limit: Int = 120) -> String {
        guard !plain.isEmpty else { return "<empty>" }

        let head = String(plain.prefix(limit))
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")

        return plain.count > limit ? "\(head)…" : head
    }

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        writeDebugLog("[Genius] Fetching lyrics for \"\(query.title)\" - \(query.primaryArtist)")
        let strippedTitle = query.title.strippedTrackTitle
        let keyword = "\(strippedTitle) \(query.primaryArtist)"
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 第一枪：`标题 + 歌手`（既有行为，不动）。
        var hits = try searchSong(keyword)
        writeDebugLog("[Genius] Search returned \(hits.count) hit(s)")

        if hits.isEmpty {
            // 第二枪：只拿标题再搜（必须命中歌手）。见 `titleOnlyHits` 的说明。
            hits = try titleOnlyHits(
                strippedTitle: strippedTitle,
                primaryArtist: query.primaryArtist
            )
        }

        guard !hits.isEmpty else {
            writeDebugLog("[Genius] No usable hits for either query — noSuchSong")
            throw LyricsError.noSuchSong
        }

        let song = mostRelevantHitResult(hits: hits, strippedTitle: strippedTitle)

        // 选中的是哪一条 —— **成功与否都打**。
        //
        // 以前只有成功路径的 `[Genius] Using "…" — N line(s)` 留下标题，失败路径什么都不留：
        // 2026-09-27 日志 16 的 `Runner` 就卡在这儿（`Search returned 1 hit(s)` 之后直接
        // `No usable lyrics`），看不出那条命中**是不是这首歌**、也看不出它的词页是不是空的。
        writeDebugLog(
            "[Genius] Chosen hit: id=\(song.id)"
                + " title=\"\(song.title)\" artist=\"\(song.artistNames)\""
        )

        let songInfo = try getSongInfo(song.id)

        let plainLines = songInfo.lyrics.plain.components(separatedBy: .newlines)
        let mappedLines = LyricsMarkerFilter.mapLyricsLines(plainLines)

        // 不把上游「空歌词 → 纯音乐占位」的 bug 带过来：无有效歌词就抛查无此歌。
        guard !mappedLines.isEmpty else {
            // 三种情况以前共用同一句 `No usable lyrics`，没法区分：
            //   · `plain` 是空串（Genius 有页面但没填词）；
            //   · 整页只有 `[Instrumental]` / `[Chorus]` 这类标注，被 mapLyricsLines 全过滤掉；
            //   · 匹配到的压根是另一首同名歌。
            // 原始字符数 / 原始行数 / 开头 120 字符一起打出来，一次复现就能定性。
            writeDebugLog(
                "[Genius] No usable lyrics — plain \(songInfo.lyrics.plain.count) char(s),"
                    + " raw \(plainLines.count) line(s), kept \(mappedLines.count),"
                    + " head=\(plainHeadForLog(songInfo.lyrics.plain))"
            )
            throw LyricsError.noSuchSong
        }

        var romanization = LyricsRomanizationStatus.original
        if songInfo.language.isCanBeRomanizedLanguage {
            romanization = .canBeRomanized
        }

        writeDebugLog("[Genius] Using \"\(song.title)\" — \(mappedLines.count) line(s)")
        return LyricsDto(
            lines: mappedLines.map { LyricsLineDto(content: $0) },
            timeSynced: false,
            romanization: romanization,
            languageCode: songInfo.language
        )
    }
}
