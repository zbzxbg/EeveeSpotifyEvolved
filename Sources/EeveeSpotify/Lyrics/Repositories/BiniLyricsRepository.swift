import Foundation

/// BiniLyrics（`lyrics-api.binimum.org`）—— 按名字搜 Apple Music 逐字 TTML 的社区库。
///
/// ── 接口
/// GET /?track=<曲名>&artist=<艺人>[&duration=<秒>][&album=<专辑>]
/// → {"results": [{"track_name", "artist_name", "duration"(秒), "isrc",
/// "lyricsUrl", "timing_type": "word" | "line" | "none"}], "total": N}
/// → 再 GET `lyricsUrl` 拿 TTML 正文（实际就是 `https://lrc.red/s/<isrc>.ttml`）
///
/// 不带参数打根路径时，服务自己会回 `{"detail":"provide one of: q / isrc / track(+artist)"}`
/// —— 这就是它的接口说明。它也接受 `isrc=`，但 `LyricsSearchQuery` 里没有 ISRC
/// （Spotify 的播放器元数据不保证带），所以这里只走名字搜索。
///
/// ── 为什么必须自己比标题和歌手
/// 这个库是**模糊搜索**，一次回 20 条，里面混着大量同曲异人的翻唱。实测
/// `Blinding Lights / The Weeknd` 的前 20 条里有 17 条是别人的版本
/// （The Naked and Famous 187s、The Howl & The Hum 221s…），原曲 200s。
/// 只按时长挑的话，4 秒容差足够让某首翻唱混进来 —— 用户会拿到**另一首歌的词**。
///
/// 所以判据是三道闸，缺一不可：
/// ① 曲名：去标点后**全等**（`LyricsMatch.key`；`晴天` 与 `晴天 (Live)` 因此不同）。
/// 唯一放宽的是合作署名：`Song (feat. X)` 与 `Song` 视为同一首（见 `titlesMatch`）；
/// ② 歌手：互相包含（`LyricsMatch.sameArtist`，认 `feat.` 之后的主艺人）；
/// ③ 时长：±4 秒（`LyricsMatch.lengthMatches`，任一方缺数据就不否决）。
///
/// ①② 的代价是**漏配**而不是错配：Spotify 与 Apple 的标题偶尔差一个后缀
/// （`- Remastered 2011`）就会整条落空。这是有意的 —— 漏了还有下一个源，
/// 配错了用户是看不出来的。
///
/// ── 挑哪一条
/// 过闸的候选按 `(逐字优先, 时长差更小)` 排序，取第一条。`timing_type` 只参与**排序**，
/// 不改写 dto：最终是逐字还是逐行，由 `hasUsableWordLevelData` 按解析出来的行判 ——
/// 那是自动优选与渲染层共用的唯一口径（声明 "word" 而 TTML 里只有 `<p begin>` 的情况确实存在）。
final class BiniLyricsRepository: LyricsRepository {

    static let shared = BiniLyricsRepository()
    private init() {}

    private static let endpoint = "https://lyrics-api.binimum.org/"

    /// 秒。翻唱/伴奏与原版通常差得比这多；同曲异名的不同母带差得比这少。
    private static let lengthToleranceSeconds = 4

    // MARK: - 取词

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let title = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = query.primaryArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else {
            writeDebugLog("[Bini] search skipped — empty title or artist")
            throw LyricsError.noSuchSong
        }

        guard let searchURL = Self.searchURL(title: title, artist: artist, query: query) else {
            throw LyricsError.decodingError
        }

        guard let payload = LyricsSourceHTTP.getJSON(searchURL, tag: "Bini"),
              let rows = LyricsSourceHTTP.dig(payload, ["results"]) as? [Any] else {
            writeDebugLog("[Bini] search returned no results array")
            throw LyricsError.noSuchSong
        }

        let candidates = rows.compactMap { Self.candidate(from: $0) }
        let fittingCandidates = Self.fitting(candidates, for: query)
        guard let pick = fittingCandidates.first else {
            writeDebugLog(
                "[Bini] \"\(title)\" — \(artist): \(candidates.count) candidate(s),"
                    + " none passed title / artist / length"
            )
            throw LyricsError.noSuchSong
        }

        writeDebugLog(
            "[Bini] \"\(title)\" — \(artist): \(fittingCandidates.count)/\(candidates.count) passed,"
                + " picking \(pick.label)"
        )

        guard let ttml = LyricsSourceHTTP.getText(pick.url, tag: "Bini"), !ttml.isEmpty else {
            writeDebugLog("[Bini] \(pick.label): TTML came back empty")
            throw LyricsError.noSuchSong
        }

        guard let dto = Self.makeDto(fromTTML: ttml) else {
            writeDebugLog("[Bini] \(pick.label): TTML parsed to no lines")
            throw LyricsError.noSuchSong
        }

        writeDebugLog("[Bini] \(pick.label): \(dto.lines.count) line(s)")
        return dto
    }

    // MARK: - 搜索

    private static func searchURL(title: String, artist: String, query: LyricsSearchQuery) -> URL? {
        var components = URLComponents(string: endpoint)
        var items = [
            URLQueryItem(name: "track", value: title),
            URLQueryItem(name: "artist", value: artist)
        ]

        // `duration` 是**秒**（接口的 `duration` 字段也是秒）。
        if let durationMs = query.durationMs, durationMs > 0 {
            items.append(URLQueryItem(name: "duration", value: String(durationMs / 1000)))
        }
        if let album = query.albumTitle, !album.isEmpty {
            items.append(URLQueryItem(name: "album", value: album))
        }

        components?.queryItems = items
        return components?.url
    }

    // MARK: - 候选
    //
    // 一条搜索结果。`seconds` 为 nil 表示接口没给时长（排序时当作最不接近）。
    private struct Candidate {
        let url: URL
        let trackName: String
        let artistName: String
        let seconds: Int?
        let wordTimed: Bool
        let isrc: String?

        /// 没有就用 URL 最后一段。
        var label: String { isrc ?? url.lastPathComponent }
    }

    private static func candidate(from row: Any) -> Candidate? {
        guard let entry = row as? [String: Any],
              let raw = entry["lyricsUrl"] as? String,
              !raw.isEmpty,
              let url = URL(string: raw) else { return nil }

        let seconds = (entry["duration"] as? NSNumber)?.intValue

        return Candidate(
            url: url,
            trackName: entry["track_name"] as? String ?? "",
            artistName: entry["artist_name"] as? String ?? "",
            seconds: (seconds ?? 0) > 0 ? seconds : nil,
            wordTimed: (entry["timing_type"] as? String) == "word",
            isrc: entry["isrc"] as? String
        )
    }

    /// 过三道闸，再按 (逐字优先, 时长差更小) 排好。第一条就是最该用的那条。
    private static func fitting(_ candidates: [Candidate], for query: LyricsSearchQuery) -> [Candidate] {
        let wantedTitles = Set(
            ([query.title] + query.titleVariants)
                .map { LyricsMatch.key($0) }
                .filter { !$0.isEmpty }
        )
        let artists = query.allArtistNames
        let trackMs = query.durationMs

        let passing = candidates.filter { candidate in
            guard Self.titlesMatch(LyricsMatch.key(candidate.trackName), wanted: wantedTitles) else {
                return false
            }
            guard artists.contains(where: { LyricsMatch.sameArtist(candidate.artistName, $0) }) else {
                return false
            }
            let candidateMs = candidate.seconds.map { $0 * 1000 }
            return LyricsMatch.lengthMatches(
                candidateMs,
                trackMs,
                slackMs: lengthToleranceSeconds * 1000
            )
        }

        return passing.sorted { lhs, rhs in
            if lhs.wordTimed != rhs.wordTimed { return lhs.wordTimed }
            return offset(lhs, trackMs) < offset(rhs, trackMs)
        }
    }

    /// 曲名是否同一首。
    ///
    /// 主判据是**全等**（去标点后）。唯一的放宽是合作署名：Apple 常把 `feat.` 写进标题
    /// （`Song (feat. X)`），Spotify 有时只在艺人字段里写 —— 归一化后是 `songfeatx` 与
    /// `song`，全等会把同一首歌判成两首。所以允许"多出来的一段以 `feat` / `ft` 开头"。
    ///
    /// 不放宽版本后缀：`Song (Live)` / `Song (Remix)` 归一化后多出来的是 `live` / `remix`，
    /// 那正是最常配错的一类，必须挡在外面。
    private static func titlesMatch(_ candidateKey: String, wanted: Set<String>) -> Bool {
        guard !candidateKey.isEmpty else { return false }
        if wanted.contains(candidateKey) { return true }

        for key in wanted {
            let longer = key.count >= candidateKey.count ? key : candidateKey
            let shorter = key.count >= candidateKey.count ? candidateKey : key
            guard longer.hasPrefix(shorter), longer.count > shorter.count else { continue }

            let extra = longer.dropFirst(shorter.count)
            if extra.hasPrefix("feat") || extra.hasPrefix("ft") { return true }
        }
        return false
    }

    /// 与曲目的时长差（毫秒）。缺任一侧就是 `.max`，排在所有能算出差值的候选后面。
    private static func offset(_ candidate: Candidate, _ trackMs: Int?) -> Int {
        guard let seconds = candidate.seconds, let trackMs, trackMs > 0 else { return .max }
        return abs(seconds * 1000 - trackMs)
    }

    // MARK: - 解析
    //
    // TTML → dto。解析与映射与 AMLL / Apple Music 官方那两条线**共用同一套**代码。
    private static func makeDto(fromTTML ttml: String) -> LyricsDto? {
        guard let parsed = try? AmllTtmlParser.parse(ttml) else { return nil }
        let dto = AmllLyricsMapper.makeDto(parsed, logTag: "Bini")
        return dto.lines.isEmpty ? nil : dto
    }
}
