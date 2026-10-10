import Foundation
import UIKit

class MusixmatchLyricsRepository: LyricsRepository {
    private let apiUrl = "https://apic.musixmatch.com"

    /// 这一行是不是**间奏行**（整行只有 ♪ ♫ ♬ ♩ ♭ ♯ 这类音乐符号，或者本来就是空白）。
    ///
    /// ★ 2026-10-18：判据只看内容本身、与旧开关无关 —— 间奏行现在**无条件剔除**
    /// （用户拍板 A：「把原本有的间奏全部删掉」），见下面处理 `lyricsLines` 那一段的说明。
    private func isMxmInterludeRow(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return trimmed.allSatisfy { "♪♫♬♩♭♯".contains($0) }
    }

    /// ⚠️ 2026-10-18：「删除间奏符号 ♪」那颗开关的**读取点已全部撤掉** —— 间奏行改为无条件剔除
    /// （用户拍板 A，见 `isMxmInterludeRow` 与处理 `lyricsLines` 那一段）。
    /// 键与 UI 行还在（键定义 `NgzhwmSettingsViewModel.removeMxmInterludeSymbolKey`），
    /// 拆除它们是单独一刀：漏一处引用是编译错，不做半拉子。

    private func cleanedMxmLyricsText(_ text: String) -> String {
        guard shouldRemoveMxmInterludeSymbol, text.contains("♪") else {
            return text
        }

        return ""
    }

    private func isNgzhwmRomanizationEnabled(for romanizationLanguage: String) -> Bool {
        switch romanizationLanguage.lowercased() {
        case "rc", "rz":
            return UserDefaults.standard.bool(forKey: "ngzhwm_chineseRomanization")
        case "rj":
            return UserDefaults.standard.bool(forKey: "ngzhwm_japaneseRomanization")
        case "rk":
            return UserDefaults.standard.bool(forKey: "ngzhwm_koreanRomanization")
        default:
            return false
        }
    }

    private var selectedLanguageForRequest: String {
        let normalizedLanguage = selectedLanguage.lowercased()
        guard normalizedLanguage.hasPrefix("r") else {
            return selectedLanguage
        }

        return isNgzhwmRomanizationEnabled(for: selectedLanguage) ? selectedLanguage : ""
    }

    var selectedLanguage: String

    static let shared = MusixmatchLyricsRepository(
        language: UserDefaults.lyricsOptions.musixmatchLanguage
    )

    private init(language: String) {
        selectedLanguage = language
    }

    //

    private class CachedLyrics {
        let dto: LyricsDto

        init(dto: LyricsDto) {
            self.dto = dto
        }
    }

    private let lyricsCache = NSCache<NSString, CachedLyrics>()

    private func getCacheKey(for query: LyricsSearchQuery) -> String {
        let romanizationSettings = [
            UserDefaults.standard.bool(forKey: "ngzhwm_chineseRomanization"),
            UserDefaults.standard.bool(forKey: "ngzhwm_japaneseRomanization"),
            UserDefaults.standard.bool(forKey: "ngzhwm_koreanRomanization"),
            shouldRemoveMxmInterludeSymbol,
        ].map { $0 ? "1" : "0" }.joined()

        return "\(query.hashValue)_\(selectedLanguage)_\(romanizationSettings)"
    }

    //

    /// 没有 `usertoken` 时换一个**匿名令牌**填上。
    ///
    /// 只填一次（填完就进 `UserDefaults.musixmatchToken`），失败**不抛** —— 这次请求照旧发出去，
    /// 401 由 `getMacroCalls` 那边统一处理（弹窗/清令牌都在那里）。这样"没令牌"和"令牌过期"
    /// 两条路只有一处决定成败。
    ///
    /// ⚠️ 这条路是同步阻塞的（最多 15s，见 `AnonymousTokenHelper.fetchTokenBlocking`）：
    /// 它跑在歌词取词那条已经阻塞的队列上，不会卡住主线程。
    private func ensureTokenIfNeeded() {
        guard UserDefaults.musixmatchToken.isEmpty else { return }
        // 自动这条路给 6s：外层对 Musixmatch 只有 5s 预算（`CustomLyrics` 的 requestTimeout），
        // 换到的令牌会落进 UserDefaults —— 就算这一次被外层判超时，下一首也直接有令牌了。
        guard let token = AnonymousTokenHelper.fetchTokenBlocking(totalBudget: 6) else {
            writeDebugLog("[Musixmatch] no token, and the anonymous request failed — sending without one")
            return
        }
        UserDefaults.musixmatchToken = token
        UserDefaults.musixmatchTokenIsAnonymous = true
        writeDebugLog("[Musixmatch] stored an anonymous token (len=\(token.count))")
    }

    private func perform(
        _ path: String,
        query: [String: Any] = [:]
    ) throws -> Data {
        var stringUrl = "\(apiUrl)\(path)"
        var finalQuery = query

        // ★ 2026-10-13：没有令牌时**自动换一个匿名令牌**再发请求。
        //
        // 为什么必须放在这里（而不是只在设置页留一颗按钮）："没填 SpicyLyrics 密钥 → 改用
        // Musixmatch"是**自动**发生的，用户根本没去过设置页；如果 mxm 这边也因为没有令牌直接
        // 失败，这条回退对他就是一句空话。见 `AnonymousTokenHelper` 文件头。
        ensureTokenIfNeeded()

        let userToken = UserDefaults.musixmatchToken
        let appId = UIDevice.current.musixmatchAppId

        finalQuery["usertoken"] = userToken
        finalQuery["app_id"] = appId

        let queryString = finalQuery.queryString
        stringUrl += "?\(queryString)"

        var request = URLRequest(url: URL(string: stringUrl)!)

        // 按 Safari 的形态补齐请求头（见 UIDevice.safariUserAgent 注释）。
        request.setValue(UIDevice.current.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(
            Locale.preferredLanguages.prefix(3).joined(separator: ","),
            forHTTPHeaderField: "Accept-Language"
        )

        // 只记 token 长度不记内容：token 为空是 403 的疑似原因之一，长度直接回答「到底发出去了没有」。
        // 其余 query 原样记录，便于和「Safari 能通过」的那条 URL 逐字对比。
        var loggedQuery = finalQuery
        loggedQuery["usertoken"] = "REDACTED"
        writeDebugLog(
            "[Musixmatch] request \(path)?\(loggedQuery.queryString) "
                + "— usertokenLen=\(userToken.count), ua=\(UIDevice.current.safariUserAgent)"
        )

        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var httpResponse: HTTPURLResponse?
        var error: Error?

        let task = URLSession.shared.dataTask(with: request) { body, response, err in
            error = err
            data = body
            httpResponse = response as? HTTPURLResponse
            semaphore.signal()
        }

        task.resume()
        semaphore.wait()

        let httpStatus = httpResponse?.statusCode ?? -1

        // 非 200 时把响应头打出来（Server / Content-Type 等），用于判断是 nginx 哪一类规则在拦。
        if httpStatus != 200, let httpResponse = httpResponse {
            let headers = httpResponse.allHeaderFields
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: ", ")
            writeDebugLog("[Musixmatch] \(path) — http \(httpStatus) response headers: \(headers)")
        }

        if let error = error {
            // 传输层失败（DNS / 连接 / TLS / 取消）以前完全没有日志，
            // 上层只会显示成一句「Musixmatch failed」，看不出是网络问题。
            writeDebugLog("[Musixmatch] \(path) — transport error: \(error) (http=\(httpStatus))")
            throw error
        }

        writeDebugLog("[Musixmatch] \(path) -> http \(httpStatus), \(data?.count ?? 0) byte(s)")

        guard let data = data else {
            writeDebugLog("[Musixmatch] \(path) — empty response body (http=\(httpStatus))")
            throw LyricsError.decodingError
        }

        return data
    }

    /// 原始响应体片段，用于诊断「响应不是预期 JSON」这类静默失败。
    private func bodyHead(_ data: Data, limit: Int = 300) -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            return "<non-utf8, \(data.count) byte(s)>"
        }

        return String(text.prefix(limit))
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    //

    private func getMacroCalls(_ data: Data) throws -> [String: Any] {
        guard
            let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            let message = json["message"] as? [String: Any]
        else {
            writeDebugLog("[Musixmatch] macro.subtitles.get — response is not JSON / no message: \(bodyHead(data))")
            throw LyricsError.decodingError
        }

        let header = message["header"] as? [String: Any]
        let statusCode = header?["status_code"] as? Int
        let statusText = statusCode.map { String($0) } ?? "-"

        // 状态码检查必须排在 macro_calls 的 guard 之前：401 等错误响应体里没有 macro_calls，
        // 否则会先抛 decodingError，把「token 失效」静默吞掉（连带未授权弹窗也永远弹不出来）。
        if let code = statusCode, code != 200 {
            let hint = header?["hint"] as? String ?? "-"
            writeDebugLog("[Musixmatch] macro.subtitles.get — status_code=\(code), hint=\(hint), body: \(bodyHead(data))")
        }

        if statusCode == 401 {
            writeDebugLog("[Musixmatch] 401 — invalid token")
            // 匿名令牌会过期：是它就把缓存丢掉，**下一次请求会自动换一个新的**。
            // 用户自己填的令牌 401 了**不能替他清** —— 那是他自己要改的东西，我们只记一行。
            if UserDefaults.musixmatchTokenIsAnonymous {
                writeDebugLog(
                    "[Musixmatch] dropping the expired anonymous token"
                        + " — the next request will fetch a new one"
                )
                UserDefaults.musixmatchToken = ""
                UserDefaults.musixmatchTokenIsAnonymous = false
            } else {
                writeDebugLog(
                    "[Musixmatch] the token was user-provided — not clearing it"
                        + " (the user has to replace it in Settings)"
                )
            }
            throw LyricsError.invalidMusixmatchToken
        }

        guard
            let body = message["body"] as? [String: Any],
            let macroCalls = body["macro_calls"] as? [String: Any]
        else {
            writeDebugLog(
                "[Musixmatch] macro.subtitles.get — no macro_calls (status_code=\(statusText)): \(bodyHead(data))"
            )
            throw LyricsError.decodingError
        }

        return macroCalls
    }

    private func getFirstSubtitle(_ subtitlesMessage: [String: Any]) throws -> [String: Any] {
        guard
            let subtitlesBody = subtitlesMessage["body"] as? [String: Any],
            let subtitleList = subtitlesBody["subtitle_list"] as? [[String: Any]],
            let firstSubtitle = subtitleList.first,
            let subtitle = firstSubtitle["subtitle"] as? [String: Any]
        else {
            throw LyricsError.decodingError
        }

        if let restricted = subtitle["restricted"] as? Bool, restricted {
            writeDebugLog("[Musixmatch] Lyrics restricted")
            throw LyricsError.musixmatchRestricted
        }

        return subtitle
    }

    //

    private func getTranslations(_ spotifyTrackId: String, selectedLanguage: String) throws
        -> [String: String]
    {
        let data = try perform(
            "/ws/1.1/crowd.track.translations.get",
            query: [
                "track_spotify_id": spotifyTrackId,
                "selected_language": selectedLanguage,
            ]
        )

        guard
            let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            let message = json["message"] as? [String: Any],
            let body = message["body"] as? [String: Any],
            let translationsList = body["translations_list"] as? [[String: Any]]
        else {
            throw LyricsError.decodingError
        }

        let translations = translationsList.compactMap {
            $0["translation"] as? [String: Any]
        }

        return translations.reduce(into: [:]) { dictionary, translation in
            dictionary[translation["subtitle_matched_line"] as! String] =
                translation["description"] as? String
        }
    }

    private func intValue(_ dict: [String: Any], _ key: String) -> Int? {
        if let value = dict[key] as? Int { return value }
        if let value = dict[key] as? Int64 { return Int(value) }
        if let value = dict[key] as? NSNumber { return value.intValue }
        return nil
    }

    /// 用 matcher.track.get 把 Spotify track id / 歌名+歌手解析成 MxM 内部 commontrack id。
    /// 返回 (trackId, hasRichSync)。macro.subtitles.get 的响应里没有 commontrack id，
    /// 必须单独走这一步才能拿到。
    private func getTrackId(_ query: LyricsSearchQuery) throws -> (trackId: Int, hasRichSync: Bool) {
        let data = try perform(
            "/ws/1.1/matcher.track.get",
            query: [
                "track_spotify_id": query.spotifyTrackId,
                "q_track": query.title,
                "q_artist": query.primaryArtist,
            ]
        )

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = json["message"] as? [String: Any],
            let body = message["body"] as? [String: Any],
            let track = body["track"] as? [String: Any],
            let trackId = intValue(track, "track_id")
        else {
            throw LyricsError.decodingError
        }

        let hasRichSync = (intValue(track, "has_richsync") ?? 0) == 1
        return (trackId, hasRichSync)
    }

    private func getRichSync(trackId: Int) throws -> [MusixmatchRichSyncLine] {
        let data = try perform(
            "/ws/1.1/track.richsync.get",
            query: ["track_id": trackId]
        )

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = json["message"] as? [String: Any],
            let body = message["body"] as? [String: Any],
            let richsync = body["richsync"] as? [String: Any]
        else {
            throw LyricsError.decodingError
        }

        if (intValue(richsync, "restricted") ?? 0) != 0 {
            writeDebugLog("[Musixmatch] richsync restricted")
            throw LyricsError.musixmatchRestricted
        }

        guard
            let richsyncBody = richsync["richsync_body"] as? String,
            let bodyData = richsyncBody.data(using: .utf8)
        else {
            throw LyricsError.decodingError
        }

        writeDebugLog("[Musixmatch] richsync body head: \(richsyncBody.prefix(300))")

        guard let lines = try? JSONDecoder().decode(
            [MusixmatchRichSyncLine].self,
            from: bodyData
        ) else {
            throw LyricsError.decodingError
        }

        return lines
    }

    /// 按行起始时间（±10ms 容差）在 richsync 词表里查找对应的词数组。
    private func wordsAtTime(_ ms: Int, in wordsByTime: [Int: [LyricsWordDto]]) -> [LyricsWordDto]? {
        if let words = wordsByTime[ms] { return words }
        for delta in 1...10 {
            if let words = wordsByTime[ms + delta] { return words }
            if let words = wordsByTime[ms - delta] { return words }
        }
        return nil
    }

    //

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        writeDebugLog("[Musixmatch] Fetching lyrics for \"\(query.title)\" - \(query.primaryArtist)")
        let cacheKey = getCacheKey(for: query)

        if let cached = lyricsCache.object(forKey: cacheKey as NSString) {
            writeDebugLog("[Musixmatch] Cache hit")
            return cached.dto
        }

        var musixmatchQuery = [
            "track_spotify_id": query.spotifyTrackId,
            "subtitle_format": "mxm",
            "q_track": query.title,
            "q_artist": query.primaryArtist,
        ]

        let requestedLanguage = selectedLanguageForRequest

        if !requestedLanguage.isEmpty {
            musixmatchQuery["selected_language"] = requestedLanguage
            musixmatchQuery["part"] = "subtitle_translated"
        }

        let data = try perform(
            "/ws/1.1/macro.subtitles.get",
            query: musixmatchQuery
        )

        var romanized = false
        var translation: LyricsTranslationDto? = nil

        let macroCalls = try getMacroCalls(data)

        // 诊断：宏响应里有哪些子调用，以及是否内嵌了 matcher.track.get（同源 track_id）
        writeDebugLog("[Musixmatch] macro_calls keys: \(macroCalls.keys.sorted().joined(separator: ","))")
        if let matcherCall = macroCalls["matcher.track.get"] as? [String: Any],
            let matcherMessage = matcherCall["message"] as? [String: Any],
            let matcherBody = matcherMessage["body"] as? [String: Any],
            let track = matcherBody["track"] as? [String: Any]
        {
            writeDebugLog("[Musixmatch] macro matcher.track.get — track_id=\(intValue(track, "track_id") ?? -1), has_richsync=\(intValue(track, "has_richsync") ?? 0)")
        }

        if let trackSubtitlesGet = macroCalls["track.subtitles.get"] as? [String: Any],
            let subtitlesMessage = trackSubtitlesGet["message"] as? [String: Any],
            let subtitle = try? getFirstSubtitle(subtitlesMessage),
            let subtitleLanguage = subtitle["subtitle_language"] as? String,
            let subtitleBody = subtitle["subtitle_body"] as? String,
            let subtitles = try? JSONDecoder().decode(
                [MusixmatchSubtitle].self, from: subtitleBody.data(using: .utf8)!
            )
        {

            let romanizationLanguage = "r\(subtitleLanguage.prefix(1))"

            // 逐字歌词：开关开启时先 matcher 解析 commontrack id，再取 richsync 词级时间轴。
            // 行仍用 subtitle（行级，时间可靠），richsync 词按「行起始时间」对齐贴回：
            // 既避免行数不一致按序号错位；个别歌 richsync 时间轴整体偏移（如 Die For You）
            // 时词贴不上，自然回退行级，不会把整首歌时间带歪。
            var richSyncWordsByTimeMs: [Int: [LyricsWordDto]] = [:]
            if NgzhwmSettingsViewModel.isWordByWordLyricsEnabled {
                // 优先用宏内嵌的 matcher.track.get（与 subtitle 同源、时间轴一致），
                // 避免单独 matcher.track.get 按标题模糊匹配解析到不同版本（如 Die For You 偏 20s）。
                var richSyncTrackId: Int?
                var richSyncHasFlag = false
                if let matcherCall = macroCalls["matcher.track.get"] as? [String: Any],
                    let matcherMessage = matcherCall["message"] as? [String: Any],
                    let matcherBody = matcherMessage["body"] as? [String: Any],
                    let track = matcherBody["track"] as? [String: Any],
                    let tid = intValue(track, "track_id")
                {
                    richSyncTrackId = tid
                    richSyncHasFlag = (intValue(track, "has_richsync") ?? 0) == 1
                    writeDebugLog("[Musixmatch] using macro matcher track_id=\(tid), has_richsync=\(richSyncHasFlag ? 1 : 0)")
                } else {
                    // 兜底：宏里没有时退回单独 matcher.track.get
                    if let (tid, hrs) = try? getTrackId(query) {
                        richSyncTrackId = tid
                        richSyncHasFlag = hrs
                    }
                }

                if let trackId = richSyncTrackId, richSyncHasFlag {
                    if let richSync = try? getRichSync(trackId: trackId) {
                        for richLine in richSync {
                            richSyncWordsByTimeMs[Int(richLine.ts * 1000)] = richLine.l.map {
                                LyricsWordDto(
                                    text: $0.c,
                                    startMs: Int((richLine.ts + $0.o) * 1000)
                                )
                            }
                        }
                        let richFirst = richSync.prefix(5).map { String(format: "%.2f", $0.ts) }.joined(separator: ",")
                        let subFirst = subtitles.prefix(5).map { String(format: "%.2f", Double($0.time.total)) }.joined(separator: ",")
                        writeDebugLog("[Musixmatch] Word-by-word (richsync) — \(richSync.count) line(s); richsync ts(first5)=[\(richFirst)] subtitle(first5)=[\(subFirst)]")
                    } else {
                        writeDebugLog("[Musixmatch] richsync unavailable — falling back to line-synced lyrics")
                    }
                } else {
                    writeDebugLog("[Musixmatch] no richsync — falling back to line-synced lyrics")
                }
            }

            var lyricsLines = subtitles.dropLast().map { subtitle in
                let offsetMs = Int(subtitle.time.total * 1000)
                return LyricsLineDto(
                    content: subtitle.text.lyricsNoteIfEmpty,
                    offsetMs: offsetMs,
                    words: wordsAtTime(offsetMs, in: richSyncWordsByTimeMs)
                )
            }

            lyricsLines.append(
                LyricsLineDto(
                    content: "",
                    offsetMs: Int(subtitles.last!.time.total * 1000)
                )
            )

            // 对齐校验：richsync 词只贴到极少行（如 Die For You 只 1/60），
            // 说明 richsync 与 subtitle 时间轴整体偏移（matcher 解析到错误版本等），
            // 词级数据不可用 —— 全部丢弃，回退纯行级，让 Spotify 原生歌词框架接管。
            let matchedWordLines = lyricsLines.filter { $0.words?.isEmpty == false }.count
            if matchedWordLines * 10 < lyricsLines.count * 3 {
                writeDebugLog("[Musixmatch] richsync misaligned — words matched \(matchedWordLines)/\(lyricsLines.count) (<30%), dropping to line-synced")
                for i in lyricsLines.indices { lyricsLines[i].words = nil }
            } else {
                writeDebugLog("[Musixmatch] richsync words attached to \(matchedWordLines)/\(lyricsLines.count) line(s)")
            }

            // 用于验证是否实际发生了替换（**只剩 path A**：用户把"罗马音语言"直接选成歌词语言，
            // 那是语言选择、不是罗马化开关，替换是用户要的）。
            var didReplaceAnyLine = false

            // ★★ 2026-10-12（用户：「把 mxm 的问题解决一下」）：
            // **源给的官方罗马字**，与 `lyricsLines` **同序、同长**，由我们那层画在**原文上方**
            // （`LyricLinesAdapter.romanizedContentsForDisplay()` 的首选来源）。
            //
            // ⚠️ 长度**必须**等于 `lyricsLines.count`，没匹配上的行留**空串** ——
            //    这是那条 guard 的硬要求（长度对不上会被整份忽略 ⇒ 罗马字一行都不显示）。
            var officialRomanizedLines: [String] = []

            // subtitle_translated：MxM 返回的目标语言字幕（罗马音或真实翻译）。
            // 按「行起始 offset」对齐到 lyricsLines（richsync/subtitle 行都带 offsetMs 且同源同时间；
            // richsync 与 subtitle 行数不一致时也能对上，多余行自然无翻译）。
            if let subtitleTranslated = subtitle["subtitle_translated"] as? [String: Any],
                let subtitleTranslatedBody = subtitleTranslated["subtitle_body"] as? String,
                let subtitlesTranslated = try? JSONDecoder().decode(
                    [MusixmatchSubtitle].self, from: subtitleTranslatedBody.data(using: .utf8)!
                )
            {
                var translatedByOffset: [Int: String] = [:]
                for st in subtitlesTranslated {
                    let key = Int(st.time.total * 1000)
                    if translatedByOffset[key] == nil { translatedByOffset[key] = st.text }
                }

                if requestedLanguage == romanizationLanguage {
                    // 用户直接选择了罗马音语言：用 MxM 罗马音替换歌词行（按 offset 对齐）
                    for i in 0..<lyricsLines.count {
                        guard let offset = lyricsLines[i].offsetMs,
                              let roma = translatedByOffset[offset], !roma.isEmpty else { continue }
                        lyricsLines[i].content = roma
                        didReplaceAnyLine = true
                    }
                } else if !requestedLanguage.isEmpty {
                    // 用户选择了真实翻译语言：按 offset 对齐附加为翻译层（显示翻译按钮），
                    // 行内容保持原文 —— ⚠️ 2026-10-04 起 `toSpotifyLyricsData` **不再**做本地罗马化
                    // （用户要求原生那页回到原文、罗马字只由我们自己的渲染层画，
                    // 见 `LyricsDto.toSpotifyLyricsData` 里那段说明）。
                    translation = LyricsTranslationDto(
                        languageCode: requestedLanguage,
                        lines: lyricsLines.map { line -> String in
                            guard let offset = line.offsetMs,
                                  let t = translatedByOffset[offset] else { return "" }
                            return (shouldRemoveMxmInterludeSymbol
                                && t.trimmingCharacters(in: .whitespaces) == "♪")
                                ? "" : t
                        }
                    )
                }
            }
            // 次优先：未选择任何目标语言时，全局罗马化开关开启，尝试通过翻译接口拿 MxM 罗马音。
            //
            // ★★ 2026-10-12（用户：「把 mxm 的问题解决一下」）：这一段以前是**替换原文**
            //   （`lyricsLines[i].content = translationText`，按 content 匹配）——
            //   与用户已经拍板的规矩**直接冲突**：「罗马字只画在原文上方，**绝不替换原文**」
            //   （网易 `romalrc` 那条上一轮就是这么改的，见 `LyricsDto.officialRomanizedLines`）。
            //   它现在走**同一套机制**：原文一个字不动，罗马字存进 `officialRomanizedLines`，
            //   由我们那层画在原文上方 —— Spotify 原生页也照旧是原文。
            // 已选择真实翻译语言时不走这里，避免 MxM 罗马音顶掉本地转换。
            else if isNgzhwmRomanizationEnabled(for: romanizationLanguage),
                requestedLanguage.isEmpty {
                if let translations = try? getTranslations(
                    query.spotifyTrackId,
                    selectedLanguage: romanizationLanguage
                ) {
                    // content → 罗马字 的表：同一行原文出现多次时共用同一条罗马字
                    // （覆盖范围与旧实现"所有 content 相同的行都替换"一致）。
                    var romanizedByOriginal: [String: String] = [:]
                    for (original, romanizedText) in translations
                    where romanizedByOriginal[original] == nil {
                        romanizedByOriginal[original] = romanizedText
                    }
                    officialRomanizedLines = lyricsLines.map { line in
                        romanizedByOriginal[line.content] ?? ""
                    }
                    let matched = officialRomanizedLines.filter { !$0.isEmpty }.count
                    writeDebugLog(
                        "[Musixmatch] romanization kept as the line above the original — \(matched)/\(lyricsLines.count) line(s)"
                    )
                }
            }

            // ★★★ 2026-10-18（用户拍板 A：「**把原本有的间奏全部删掉**」）：
            //   间奏行**整行删掉**，不再是"把 ♪ 清成空白、保留位置"。与网易云那一刀同一条纪律：
            //   间奏由**时间间隙**去推（`LyricInterludeTimeline`），不靠一个占位行；
            //   而空行在 AM 渲染层里照样占一行高度，看着就是"漏了一句词"✗。
            //
            //   ⚠️ 三份数组是**按下标一一对应**的（`lyricsLines` / `officialRomanizedLines` /
            //      `translation.lines`）⇒ 剔行必须**一起剔**，否则罗马字与翻译会整体错位一行
            //      （那正是用户报过的"某行翻译跑到上一行"这一类现象的同族）。
            let keep = lyricsLines.indices.filter { !isMxmInterludeRow(lyricsLines[$0].content) }
            let droppedRows = lyricsLines.count - keep.count
            if droppedRows > 0 {
                lyricsLines = keep.map { lyricsLines[$0] }
                if !officialRomanizedLines.isEmpty {
                    officialRomanizedLines = keep.map {
                        $0 < officialRomanizedLines.count ? officialRomanizedLines[$0] : ""
                    }
                }
                if let existing = translation {
                    translation = LyricsTranslationDto(
                        languageCode: existing.languageCode,
                        lines: keep.compactMap { $0 < existing.lines.count ? existing.lines[$0] : nil }
                    )
                }
                writeDebugLog(
                    "[Musixmatch] dropped \(droppedRows) interlude row(s) — \(lyricsLines.count) line(s)"
                        + " left; romanization and translation dropped in step"
                )
            }

            if didReplaceAnyLine {
                romanized = true
            }

            var romanization = LyricsRomanizationStatus.original

            if romanized {
                romanization = .romanized
            } else if lyricsLines.map({ $0.content }).canBeRomanized
                || subtitleLanguage.isCanBeRomanizedLanguage
            {
                romanization = .canBeRomanized
            }

            let lyricsDto = LyricsDto(
                lines: lyricsLines,
                timeSynced: true,
                romanization: romanization,
                translation: translation,
                languageCode: subtitleLanguage,
                officialRomanizedLines: officialRomanizedLines
            )

            writeDebugLog("[Musixmatch] Synced lyrics — \(lyricsDto.lines.count) line(s)")
            lyricsCache.setObject(CachedLyrics(dto: lyricsDto), forKey: cacheKey as NSString)
            return lyricsDto
        }

        if let trackLyricsGet = macroCalls["track.lyrics.get"] as? [String: Any],
            let lyricsMessage = trackLyricsGet["message"] as? [String: Any],
            let lyricsHeader = lyricsMessage["header"] as? [String: Any],
            let lyricsStatusCode = lyricsHeader["status_code"] as? Int
        {

            if lyricsStatusCode == 404 {
                writeDebugLog("[Musixmatch] 404 — no song")
                throw LyricsError.noSuchSong
            }

            if let lyricsBody = lyricsMessage["body"] as? [String: Any],
                let lyrics = lyricsBody["lyrics"] as? [String: Any],
                let lyricsLanguage = lyrics["lyrics_language"] as? String,
                let plainLyrics = lyrics["lyrics_body"] as? String
            {

                if let restricted = lyrics["restricted"] as? Bool, restricted {
                    throw LyricsError.musixmatchRestricted
                }

                let plainLines = plainLyrics
                    .components(separatedBy: "\n")
                    .dropLast()
                    .map { cleanedMxmLyricsText($0.lyricsNoteIfEmpty) }

                let lyricsDto = LyricsDto(
                    lines: plainLines.map { LyricsLineDto(content: $0) },
                    timeSynced: false,
                    romanization: plainLines.canBeRomanized
                        || lyricsLanguage.isCanBeRomanizedLanguage
                        ? .canBeRomanized : .original,
                    languageCode: lyricsLanguage
                )

                writeDebugLog("[Musixmatch] Plain lyrics — \(plainLines.count) line(s)")
                lyricsCache.setObject(CachedLyrics(dto: lyricsDto), forKey: cacheKey as NSString)
                return lyricsDto
            }
        }

        writeDebugLog("[Musixmatch] No usable lyrics")
        throw LyricsError.decodingError
    }
}