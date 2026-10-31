import Foundation

/// Unison（`unison.boidu.dev`）—— Better Lyrics 的众包歌词库，人工打轴的 TTML。
///
/// ── 接口
/// 读取接口的公开文档在 `github.com/better-lyrics/unison`（源码 AGPL-3.0）与
/// `docs.betterlyrics.org/unison`：
///
/// GET /lyrics?song=<曲名>&artist=<艺人>[&album=<专辑>][&duration=<秒>]
/// → {"success": true,
/// "data": {"song", "artist", "lyrics",
/// "format": "ttml" | "lrc" | "plain",
/// "syncType": "richsync" | "linesync" | "plain",
/// "confidence": "low" | "medium" | "high",
/// "id", "videoId", "language", "score", "voteCount"}}
///
/// 没命中时**没有 `data`**，只有 `{"success": false, "error", "code", "hint"}`。
///
/// ── 匹配是谁做的
/// **服务端**。它按 `v` → `isrc` → `song + artist` 的顺序找；歌手按完整署名比
/// （查 `Madvillain` 能命中署名为 `Madvillain, Madlib, MF Doom` 的那首）；
/// 给了 `duration` 就按 **±2 秒**收窄。所以这里不再拿时长兜一道：
/// · 响应里**根本没有 `duration` 字段** —— 早期版本按它比对，那个分支从来没执行过；
/// · 服务端的 ±2 秒比我们原来打算兜的 ±4 秒更严，重复一遍只会误杀。
///
/// 客户端只做三件事：确认 `success`、只收 `format == "ttml"`、能解析出至少一行。
/// 它也会回 LRC 和纯文本，那两样别的源都有，没有理由用它。
///
/// ── 为什么不用 `syncType` 定时
/// `richsync` 只说明它自己认为这份是逐字；最终是逐字还是逐行，由
/// `hasUsableWordLevelData` 按解析出来的行判 —— 那是自动优选与渲染层共用的唯一口径。
final class UnisonLyricsRepository: LyricsRepository {

    static let shared = UnisonLyricsRepository()
    private init() {}

    private static let endpoint = "https://unison.boidu.dev/lyrics"

    // MARK: - 取词

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let title = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = query.primaryArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else {
            writeDebugLog("[Unison] search skipped — empty title or artist")
            throw LyricsError.noSuchSong
        }

        guard let url = Self.searchURL(title: title, artist: artist, query: query) else {
            throw LyricsError.decodingError
        }

        guard let data = Self.fetchData(url, title: title, artist: artist) else {
            throw LyricsError.noSuchSong
        }

        guard let ttml = data["lyrics"] as? String, !ttml.isEmpty else {
            writeDebugLog("[Unison] \"\(title)\": response carried no lyric body")
            throw LyricsError.noSuchSong
        }

        guard let dto = Self.makeDto(fromTTML: ttml) else {
            writeDebugLog("[Unison] \"\(title)\": TTML would not parse into lines")
            throw LyricsError.noSuchSong
        }

        writeDebugLog(
            "[Unison] \"\(title)\" — \(artist): \(dto.lines.count) line(s), \(Self.describe(data))"
        )
        return dto
    }

    // MARK: - 请求

    private static func searchURL(title: String, artist: String, query: LyricsSearchQuery) -> URL? {
        var components = URLComponents(string: endpoint)
        var items = [
            URLQueryItem(name: "song", value: title),
            URLQueryItem(name: "artist", value: artist)
        ]

        // 秒。给了它，服务端就按 ±2 秒收窄候选。
        if let durationMs = query.durationMs, durationMs > 0 {
            items.append(URLQueryItem(name: "duration", value: String(durationMs / 1000)))
        }
        if let album = query.albumTitle, !album.isEmpty {
            items.append(URLQueryItem(name: "album", value: album))
        }

        components?.queryItems = items
        return components?.url
    }

    /// 拿到 `data` 才算成功：信封里的 `success` 为假时没有 `data`，
    /// `format` 不是 ttml 时也没必要往下走。
    private static func fetchData(_ url: URL, title: String, artist: String) -> [String: Any]? {
        guard let payload = LyricsSourceHTTP.getJSON(url, tag: "Unison") else { return nil }

        guard let envelope = payload as? [String: Any] else {
            writeDebugLog("[Unison] \"\(title)\": response was not an object")
            return nil
        }

        guard isSuccess(envelope["success"]), let data = envelope["data"] as? [String: Any] else {
            let code = envelope["code"] as? String ?? "no code"
            writeDebugLog("[Unison] \"\(title)\" — \(artist): no match (\(code))")
            return nil
        }

        let format = data["format"] as? String ?? "unknown"
        guard format == "ttml" else {
            writeDebugLog("[Unison] \"\(title)\": came back as \(format), not ttml — skipping")
            return nil
        }

        return data
    }

    /// JSON 的布尔在 `JSONSerialization` 里可能是 `Bool`，也可能是 `NSNumber`。
    private static func isSuccess(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    // MARK: - 解析

    private static func makeDto(fromTTML ttml: String) -> LyricsDto? {
        guard let parsed = try? AmllTtmlParser.parse(ttml) else { return nil }
        let dto = AmllLyricsMapper.makeDto(parsed, logTag: "Unison")
        return dto.lines.isEmpty ? nil : dto
    }

    private static func describe(_ data: [String: Any]) -> String {
        var parts: [String] = []
        if let sync = data["syncType"] as? String { parts.append(sync) }
        if let confidence = data["confidence"] as? String { parts.append("confidence \(confidence)") }
        return parts.isEmpty ? "no metadata" : parts.joined(separator: ", ")
    }
}
