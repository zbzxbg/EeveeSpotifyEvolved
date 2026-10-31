import Foundation

/// Unison（`unison.boidu.dev`）—— 人工打轴的 Apple Music 风格 TTML，曲库小但质量高。
///
/// ── 它是什么 ────────────────────────────────────────────────────────────────
/// 按 `song / artist / duration / album` 搜，直接回一份 TTML 正文（不是 URL），
/// 外加 `format` / `syncType` / `duration` / `confidence` 几个元数据。
///
/// ── 判据（三条，缺一不可）──────────────────────────────────────────────────
///   1. `format` 必须是 `ttml`：它也会回 LRC 和纯文本，而那两样别的源都有，没有理由用它；
///   2. 时长与曲目差不超过 4 秒；
///   3. `lyrics` 能解析出至少一行。
///
/// ⚠️ 它回的是"最高分匹配"而不是候选列表 —— 也就是说**它自己已经挑过了**，
///   我们只能靠时长再兜一道。所以时长这一关必须留，删了就会开始配错歌。
final class UnisonLyricsRepository: LyricsRepository {

    static let shared = UnisonLyricsRepository()
    private init() {}

    private static let api = "https://unison.boidu.dev/lyrics"
    private static let lengthSlackSeconds = 4

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let title = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = query.primaryArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else {
            writeDebugLog("[Unison] nothing to search with (empty title or artist)")
            throw LyricsError.noSuchSong
        }

        let seconds = (query.durationMs ?? 0) / 1000

        var components = URLComponents(string: Self.api)
        var items = [
            URLQueryItem(name: "song", value: title),
            URLQueryItem(name: "artist", value: artist)
        ]
        if seconds > 0 { items.append(URLQueryItem(name: "duration", value: String(seconds))) }
        if let album = query.albumTitle, !album.isEmpty {
            items.append(URLQueryItem(name: "album", value: album))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw LyricsError.decodingError }

        writeDebugLog("[Unison] searching \"\(title)\" — \(artist)")
        guard let root = LyricsSourceHTTP.getJSON(url, tag: "Unison"),
              let data = LyricsSourceHTTP.dig(root, ["data"]) as? [String: Any] else {
            writeDebugLog("[Unison] no lyrics for \"\(title)\" — \(artist)")
            throw LyricsError.noSuchSong
        }

        let format = data["format"] as? String ?? "?"
        guard format == "ttml" else {
            writeDebugLog("[Unison] \"\(title)\" came back as \(format), not ttml — passing")
            throw LyricsError.noSuchSong
        }

        let length = (data["duration"] as? NSNumber)?.intValue ?? 0
        if seconds > 0, length > 0, abs(length - seconds) > Self.lengthSlackSeconds {
            writeDebugLog("[Unison] \"\(title)\" is \(length)s against the track's \(seconds)s — passing")
            throw LyricsError.noSuchSong
        }

        guard let ttml = data["lyrics"] as? String, !ttml.isEmpty else {
            writeDebugLog("[Unison] ttml body missing")
            throw LyricsError.noSuchSong
        }
        guard let parsed = try? AmllTtmlParser.parse(ttml) else {
            writeDebugLog("[Unison] ttml would not parse")
            throw LyricsError.noSuchSong
        }

        let dto = AmllLyricsMapper.makeDto(parsed, logTag: "Unison")
        guard !dto.lines.isEmpty else {
            writeDebugLog("[Unison] ttml had nothing the page could show")
            throw LyricsError.noSuchSong
        }

        let sync = data["syncType"] as? String ?? "?"
        let confidence = (data["confidence"] as? NSNumber)?.doubleValue
        writeDebugLog(
            "[Unison] \"\(title)\" — \(artist): \(dto.lines.count) line(s),"
                + " \(sync)"
                + (confidence.map { String(format: ", confidence %.2f", $0) } ?? "")
        )
        return dto
    }
}
