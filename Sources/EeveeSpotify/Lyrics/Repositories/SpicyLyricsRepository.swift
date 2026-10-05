import Foundation

// MARK: - SpicyLyricsRepository
//
// 走 **SpicyLyrics 官方开发者 API**：`GET https://api.spicylyrics.org/v1/lyrics/<trackId>`
// + `Authorization: Bearer <key>`（key 见 `SpicyLyricsKey+UserDefaults.swift`）。
//
// ── 为什么从 `/query` 搬过来（2026-10-13 实测）────────────────────────────────
// 旧路是**内部客户端 API** `POST /query`：body 里带 `queries[].variables.auth =
// "SpicyLyrics-WebAuth"`，并且必须把从 Spotify 请求里抓到的 access token 塞进
// `SpicyLyrics-WebAuth: Bearer <token>` 头，还要伪装一整套 Spicetify 的
// Origin / UA / sec-ch-ua 头。实测结论：
//   · body 形状不对 → HTTP 418「This is the internal client API… use the developer API」；
//   · 形状对但不带 token → 200 外壳 + `result.data.error = "Missing authorization"`，
//     且外壳带一条 `_notice`：**只授权官方客户端及其公开 fork 的个人使用，禁止第三方
//     应用抓取/再分发**。
// ⇒ 技术上要抓 Spotify 凭据（脆弱）、条款上不被允许。官方 v1 只认我们自己的 key，
//   不依赖任何 Spotify 凭据，并且是文档明确给出的接入方式。
//
// ── 返回格式 ────────────────────────────────────────────────────────────────
// v1 返回**普通 JSON**（`{"Body": {...}, "Status": 200, "Type": "object"}`），
// 而旧 `/query` 的内层是 SLObjPack 打包格式。三条解析路径（Syllable / Line / Static）
// 吃的都是 `SLObjPackValue`，所以在 `SLObjPackValue.fromJSON` 那一层做一次转换，
// 不维护第二套解析器。`Body.Type` 决定精度：Syllable（逐词）/ Line（逐行）/ Static（无时间轴）。
//
// ── iOS 27 crash ─────────────────────────────────────────────────────────────
// The EXC_BREAKPOINT / _swift_task_checkIsolatedSwift crash is fixed in
// DataLoaderServiceHooks.x.swift by dispatching orig.URLSession callbacks
// onto the main queue. No changes needed here for that.

class SpicyLyricsRepository: LyricsRepository {

    static let shared = SpicyLyricsRepository()
    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest  = 15
        config.timeoutIntervalForResource = 15
        config.allowsExpensiveNetworkAccess   = true
        config.allowsConstrainedNetworkAccess = true
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    private let session: URLSession

    private static let apiUrl = "https://api.spicylyrics.org/v1/lyrics/"

    // MARK: - Network

    /// 一次 GET 的产物：响应体 + HTTP 状态码。
    ///
    /// ⚠️ 状态码**必须**跟数据一起带出来：v1 把失败原因放在状态码里
    /// （401 = key 不存在/被吊销，403 = 带 Origin 头且不在白名单，404 = 没这首词的同步，
    /// 503 = 还在生成）。旧 `/query` 那条路是 200 外壳 + 内层 `httpStatus`，两者不可混用。
    private struct QueryResult {
        let data: Data
        let httpStatus: Int
    }

    /// 503 = "这首歌的同步还在生成中"，官方语义上会自愈 ⇒ 按 2·1.5^n 退避重试
    /// （最多 5 次，单次上限 10s）。
    private static let queuedRetryDelays: [TimeInterval] = {
        (0 ..< 5).map { attempt in min(10.0, 2.0 * pow(1.5, Double(attempt))) }
    }()

    private func performQuery(trackId: String) throws -> QueryResult {
        for (attempt, delay) in ([0.0] + SpicyLyricsRepository.queuedRetryDelays).enumerated() {
            if delay > 0 {
                // ⚠️ 不写嵌套双引号字面量（仓库成文规矩）：把 `String(format:)` 先算成变量。
                let seconds = String(format: "%.1f", delay)
                writeDebugLog(
                    "[SpicyLyrics] \(trackId) queued (503), retrying in \(seconds)s "
                        + "(attempt \(attempt + 1))"
                )
                Thread.sleep(forTimeInterval: delay)
            }
            let result = try performRequest(trackId: trackId)
            if result.httpStatus != 503 { return result }
        }
        writeDebugLog("[SpicyLyrics] \(trackId) still queued after all retries")
        throw LyricsError.noSuchSong
    }

    private func performRequest(trackId: String) throws -> QueryResult {
        guard let url = URL(string: SpicyLyricsRepository.apiUrl + trackId) else {
            throw LyricsError.decodingError
        }

        // ⚠️ 没有密钥就**不要发请求**：本仓库不内置默认 key（用户拍板，理由见
        // `SpicyLyricsKey+UserDefaults.swift` 文件头）。正常流程下调用方（`CustomLyrics`）
        // 在"没 key"时已经改用 Musixmatch 了，走到这里说明是别处直接调进来 —— 给一句能读懂的原因。
        let apiKey = UserDefaults.effectiveSpicyLyricsApiKey
        guard !apiKey.isEmpty else {
            writeDebugLog("[SpicyLyrics] \(trackId) skipped — no client key is configured")
            throw LyricsError.missingSpicyKey
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // 只有这一条凭据 —— 不再需要 Spotify 的 access token，也不再伪装浏览器头。
        // 我们**不带** `Origin`：key 所在的 application 必须打开
        // "Allow requests with no Origin header"，否则会拿到 403 origin_not_allowed。
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("EeveeSpotify", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseStatus = 0
        var responseError: Error?

        session.dataTask(with: request) { data, response, error in
            responseData = data
            responseStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            responseError = error
            semaphore.signal()
        }.resume()

        semaphore.wait()

        if let error = responseError {
            writeDebugLog("[SpicyLyrics] Network error for \(trackId): \(error)")
            throw error
        }
        guard let data = responseData else {
            writeDebugLog("[SpicyLyrics] No data for \(trackId)")
            throw LyricsError.decodingError
        }
        writeDebugLog("[SpicyLyrics] HTTP \(responseStatus), \(data.count) bytes for \(trackId)")
        return QueryResult(data: data, httpStatus: responseStatus)
    }

    // MARK: - Parse

    private func parseLyricsData(_ result: QueryResult, trackId: String) throws -> LyricsDto {
        switch result.httpStatus {
        case 200:
            break
        case 401, 403:
            // 401 key_not_found（key 被吊销/写错）；403 origin_not_allowed（只有带 Origin 头
            // 的请求才可能撞到 —— 我们不发这个头，撞到就说明面板那一项被关了）。
            // 单独一种错误：混进 noSuchSong 会被当成"这首歌没词"，用户只会去换来源。
            writeDebugLog(
                "[SpicyLyrics] \(trackId) key rejected (HTTP \(result.httpStatus)): "
                    + SpicyLyricsRepository.bodyPreview(result.data)
            )
            throw LyricsError.invalidSpicyKey
        case 400:
            // invalid_track_id —— 官方要求 22 位 base62（就是 Spotify 曲目 URL 里那串）。
            // 走到这里说明我们递过去的不是从 Spotify 拿到的 id，属于我方 bug。
            writeDebugLog(
                "[SpicyLyrics] \(trackId) invalid track id (HTTP 400): "
                    + SpicyLyricsRepository.bodyPreview(result.data)
            )
            throw LyricsError.noSuchSong
        case 404:
            writeDebugLog("[SpicyLyrics] \(trackId): HTTP 404, no lyrics for that track")
            throw LyricsError.noSuchSong
        case 429:
            // publishable key 在应用级限流之外还有**每 IP 限流**（官方文档原话）——
            // 所以它和"这首歌没词"必须分开记：同一个 IP 下多台设备（或运营商 NAT 后面的
            // 一整片用户）共用同一个出口时，429 是最先撞到的一堵墙。
            writeDebugLog(
                "[SpicyLyrics] \(trackId) rate limited (HTTP 429): "
                    + SpicyLyricsRepository.bodyPreview(result.data)
            )
            throw LyricsError.unknownError
        case 500, 502, 503:
            // 503 已经在 `performQuery` 里退避重试过了，走到这里说明重试也用完。
            writeDebugLog(
                "[SpicyLyrics] \(trackId) server error (HTTP \(result.httpStatus)): "
                    + SpicyLyricsRepository.bodyPreview(result.data)
            )
            throw LyricsError.unknownError
        default:
            writeDebugLog(
                "[SpicyLyrics] \(trackId) unexpected HTTP \(result.httpStatus): "
                    + SpicyLyricsRepository.bodyPreview(result.data)
            )
            throw LyricsError.noSuchSong
        }

        guard let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any] else {
            writeDebugLog(
                "[SpicyLyrics] \(trackId) invalid JSON: "
                    + SpicyLyricsRepository.bodyPreview(result.data)
            )
            throw LyricsError.decodingError
        }

        // v1 的正文在 `Body` 里（外面还有 `Status` / `Type`）。兼容性地也认裸对象。
        let rootJSON = (json["Body"] as? [String: Any]) ?? json
        let root = SLObjPackValue.fromJSON(rootJSON)

        guard let type = root["Type"]?.stringValue else {
            writeDebugLog(
                "[SpicyLyrics] \(trackId) missing Type: "
                    + SpicyLyricsRepository.bodyPreview(result.data)
            )
            throw LyricsError.decodingError
        }

        // `source` 决定署名（spicy_lyrics / apple_music / spotify），排查时很有用。
        // ⚠️ 取出来再拼串：`\(root["source"]…)` 是嵌套双引号字面量，仓库规矩不写。
        let sourceName = root["source"]?.stringValue ?? "?"
        writeDebugLog("[SpicyLyrics] \(trackId) type=\(type), source=\(sourceName)")

        let dto: LyricsDto
        switch type {
        case "Syllable": dto = parseSyllableLyrics(root)
        case "Line":     dto = parseLineLyrics(root)
        case "Static":   dto = parseStaticLyrics(root)
        default:
            writeDebugLog("[SpicyLyrics] \(trackId) unknown type '\(type)'")
            throw LyricsError.decodingError
        }

        // 署名挂在 dto 上往下走（`CustomLyrics.storeLyricsDto` 只在 dto 没带署名时兜底成源名）。
        //
        // ⚠️ 两个字段**分工不同**，别合并：
        //   · `providerName`（短，如 `Spicy Lyrics`）会被贴到听歌页**歌手那一行**
        //     （`NowPlayingLyricsPlate.providerSuffix()` 套一层全角括号）—— 长了会把歌手名挤掉；
        //   · `providerCredit`（长，含"制作者 / 上传者"）进**注入 payload 的 `providedBy`**，
        //     也就是 Spotify 原生歌词页/卡片底部那一行。
        var credited = dto
        credited.providerName = SpicyLyricsRepository.providerName
        credited.providerURL = SpicyLyricsRepository.providerURL
        credited.providerContributors = SpicyLyricsAttribution.contributors(
            attribution: root["UploadAttribution"]
        )
        credited.providerCredit = SpicyLyricsRepository.providerCredit(
            source: root["source"]?.stringValue,
            attribution: root["UploadAttribution"]
        )
        return credited
    }

    // MARK: - Attribution

    /// 服务名 / 站点 / 贡献者解析都在 `SpicyLyricsAttribution` 里（Foundation-only，CI 直接测它）。
    /// 这里只留"拼成一行纯文本"这件事 —— 它要用到 `.localized`，进不了 CI 的编译单元。
    static var providerName: String { SpicyLyricsAttribution.providerName }
    static var providerURL: URL? { SpicyLyricsAttribution.providerURL }

    /// 按响应的 `source` 拼**纯文本**署名（进注入 payload 的 `providedBy`）。
    ///
    /// 这不是"客气一下"：SL 的服务条款把 `/docs/attribution` 定为**条款的一部分**（§6），
    /// 而 §5 明写"不许删除、模糊或改动署名"。三条硬要求：
    ///   · 永远要写出**回答的 provider**；
    ///   · `source == "spicy_lyrics"`（社区同步，词是人做的）时**还要**署名 uploader 与 maker；
    ///   · 响应里没有 `source` 时要说**来源未知**，不许猜一个安上去。
    /// 另外"歌词在屏幕上，署名就得在屏幕上（比如页面底部），不许只放进关于页或没人点的 tooltip"。
    ///
    /// 这一串进 `LyricsDto.providerCredit` → `toSpotifyLyricsData` 的 `providedBy`
    /// （**Spotify 原生歌词页/卡片底部那一行**）。听歌页歌手行用的是**短名**
    /// （`providerName`），歌词区底沿那条可点署名用的是 `providerContributors`，
    /// 三者分工见 `LyricsDto` 里各字段的说明。
    static func providerCredit(source: String?, attribution: SLObjPackValue?) -> String {
        let name = SpicyLyricsAttribution.providerName
        guard let source = source, !source.isEmpty else {
            return name + " · " + "lyrics_source_unknown".localized
        }
        // apple_music / spotify：商业源只有 provider 可署（它们的响应里也没有 contributor）。
        guard source == "spicy_lyrics" else { return name }

        var parts = [name]
        for contributor in SpicyLyricsAttribution.contributors(attribution: attribution) {
            parts.append(contributor.role.label + " " + contributor.name)
        }
        return parts.joined(separator: " · ")
    }

    /// 只给日志用：截前 200 字符。整份歌词（几十 KB）不许进日志。
    private static func bodyPreview(_ data: Data) -> String {
        let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
        return String(raw.prefix(200))
    }

    // MARK: Syllable lyrics

    private func parseSyllableLyrics(_ root: SLObjPackValue) -> LyricsDto {
        guard let content = root["Content"]?.arrayValue else { return emptyDto() }

        let preserveWords = NgzhwmSettingsViewModel.isWordByWordLyricsEnabled

        var lines        = [LyricsLineDto]()
        var hasRomanized = root["HasTransliterations"]?.boolValue ?? false

        for entry in content {
            guard entry["Type"]?.stringValue == "Vocal",
                  let lead = entry["Lead"] else { continue }

            let lineText: String
            var words: [LyricsWordDto]? = nil
            if let syllables = lead["Syllables"]?.arrayValue, !syllables.isEmpty {
                // 拼接规则整体住在 `SpicySyllableText` 里（含「IsPartOfWord 是前瞻的」
                // 那条坑；文件头有实测数据）。这里只负责取数据，不重复一份规则 ——
                // 两份实现分叉过一次，代价是 36% 的歌词行拼错。
                lineText = SpicySyllableText.joined(syllables)
                words = preserveWords ? SpicySyllableText.words(syllables) : nil
                if syllables.contains(where: { ($0["TransliteratedText"]?.stringValue ?? "").isEmpty == false }) {
                    hasRomanized = true
                }
            } else if let text = lead["Text"]?.stringValue {
                lineText = text
            } else {
                continue
            }

            if (lead["TransliteratedText"]?.stringValue ?? "").isEmpty == false { hasRomanized = true }

            let offsetMs = lead["StartTime"]?.doubleValue.map { Int($0 * 1000) }
            lines.append(LyricsLineDto(content: lineText.lyricsNoteIfEmpty, offsetMs: offsetMs, words: words))
        }

        let romanization: LyricsRomanizationStatus = hasRomanized
            ? .romanized
            : (lines.map(\.content).canBeRomanized ? .canBeRomanized : .original)

        return LyricsDto(lines: lines, timeSynced: true, romanization: romanization)
    }

    // MARK: Line lyrics

    private func parseLineLyrics(_ root: SLObjPackValue) -> LyricsDto {
        guard let content = root["Content"]?.arrayValue else { return emptyDto() }

        var lines        = [LyricsLineDto]()
        let hasRomanized = root["HasTransliterations"]?.boolValue ?? false

        for entry in content {
            guard entry["Type"]?.stringValue == "Vocal" else { continue }
            let text      = entry["Lead"]?["Text"]?.stringValue ?? entry["Text"]?.stringValue ?? ""
            let startTime = entry["Lead"]?["StartTime"]?.doubleValue ?? entry["StartTime"]?.doubleValue
            lines.append(LyricsLineDto(content: text.lyricsNoteIfEmpty, offsetMs: startTime.map { Int($0 * 1000) }))
        }

        let romanization: LyricsRomanizationStatus = hasRomanized
            ? .romanized
            : (lines.map(\.content).canBeRomanized ? .canBeRomanized : .original)

        return LyricsDto(lines: lines, timeSynced: true, romanization: romanization)
    }

    // MARK: Static lyrics

    private func parseStaticLyrics(_ root: SLObjPackValue) -> LyricsDto {
        // Static（无时间轴）的载荷有两种形状 —— 上游同款处理：
        //   · `Lines: [{ Text }]`（旧 `/query` 时代我们只认这一种）；
        //   · 或者跟 Syllable/Line 一样走 `Content: [{ Lead: { Text } }]`。
        // ⚠️ 只认第一种的话，v1 的 Static 曲目会拿到一份**空**歌词 —— 界面上就是"这首歌
        // 没有歌词"，比显示纯文本更糟。
        var texts = [String]()
        if let rawLines = root["Lines"]?.arrayValue {
            texts = rawLines.compactMap { $0["Text"]?.stringValue }
        }
        if texts.isEmpty, let content = root["Content"]?.arrayValue {
            texts = content.compactMap { $0["Lead"]?["Text"]?.stringValue ?? $0["Text"]?.stringValue }
        }

        let lines = texts.map { LyricsLineDto(content: $0.lyricsNoteIfEmpty, offsetMs: nil) }
        let romanization: LyricsRomanizationStatus = lines.map(\.content).canBeRomanized
            ? .canBeRomanized : .original
        return LyricsDto(lines: lines, timeSynced: false, romanization: romanization)
    }

    private func emptyDto() -> LyricsDto {
        LyricsDto(lines: [], timeSynced: false, romanization: .original)
    }

    // MARK: - LyricsRepository

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let trackId = query.spotifyTrackId
        guard !trackId.isEmpty else {
            writeDebugLog("[SpicyLyrics] Empty track ID")
            throw LyricsError.noSuchSong
        }
        let result = try performQuery(trackId: trackId)
        var dto = try parseLyricsData(result, trackId: trackId)

        // SpicyLyrics 上游会把部分歌词打码成 `***`。这里按「词数 + 词位置」从其他
        // 未打码的源（LRCLIB / Musixmatch / Genius，见 LyricsUncensorFill）把词补回：
        // 只改行文本，行的时间戳/时长原样保留。
        // Static(纯文本) / Line(逐行同步) / Syllable(逐字) 三条解析路径最终都汇合到
        // dto.lines，所以接在这一处即可全部覆盖。
        let filledContents = LyricsUncensorFill.fill(
            lines: dto.lines.map(\.content),
            query: query,
            options: options
        )
        for (index, content) in filledContents.enumerated() where index < dto.lines.count {
            dto.lines[index].content = content
        }

        return dto
    }
}
