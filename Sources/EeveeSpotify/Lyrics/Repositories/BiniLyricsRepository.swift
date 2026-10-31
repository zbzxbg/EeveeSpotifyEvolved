import Foundation

/// BiniLyrics（`lyrics-api.binimum.org`）—— Apple Music 的逐字 TTML 库。
///
/// ── 它是什么 ────────────────────────────────────────────────────────────────
/// 社区把 Apple Music 的 `syllable-lyrics` TTML 收下来做成可搜索的接口，按
/// `track / artist / duration / album` 搜，回一组候选（每条带 `lyricsUrl` 与 `timing_type`），
/// 再按 URL 取 TTML 正文。
///
/// ── 为什么值得接 ────────────────────────────────────────────────────────────
/// 它是"逐字 + 人工校对"的那一档，和 AMLL 同一类，但**按名字搜**而不是按 Spotify ID 查，
/// 所以 AMLL 库里没有的曲子它可能有。反过来它没有精确 ID，只能靠时长与名字挑候选 ——
/// 挑错就是把别的录音的词配上来，所以 `bestOf` 那段判据（逐字优先 + 时长容差）不能省。
///
/// ── 没有接的那一半 ──────────────────────────────────────────────────────────
/// Taurus 还有一条"按 ISRC 直取"的捷径（`https://lrc.red/s/<isrc>.ttml`）。
/// 我们的 `LyricsSearchQuery` 里**没有 ISRC**（Spotify 的播放器元数据不保证带），
/// 所以这条走不了；Taurus 在拿不到 ISRC 时也是退回按名字搜，行为一致。
final class BiniLyricsRepository: LyricsRepository {

    static let shared = BiniLyricsRepository()
    private init() {}

    private static let api = "https://lyrics-api.binimum.org/"

    /// 候选录音与曲目的时长差在几秒内才算同一首。
    /// 4 秒是 Taurus 用的值：翻唱/伴奏与原版通常差得比这多，而同曲异名的不同母带差得比这少。
    private static let lengthSlackSeconds = 4

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let title = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = query.primaryArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else {
            writeDebugLog("[Bini] nothing to search with (empty title or artist)")
            throw LyricsError.noSuchSong
        }

        let seconds = (query.durationMs ?? 0) / 1000

        var components = URLComponents(string: Self.api)
        var items = [
            URLQueryItem(name: "track", value: title),
            URLQueryItem(name: "artist", value: artist)
        ]
        if seconds > 0 { items.append(URLQueryItem(name: "duration", value: String(seconds))) }
        if let album = query.albumTitle, !album.isEmpty {
            items.append(URLQueryItem(name: "album", value: album))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw LyricsError.decodingError }

        writeDebugLog("[Bini] searching \"\(title)\" — \(artist)")
        guard let root = LyricsSourceHTTP.getJSON(url, tag: "Bini"),
              let results = LyricsSourceHTTP.dig(root, ["results"]) as? [Any] else {
            writeDebugLog("[Bini] search returned nothing usable")
            throw LyricsError.noSuchSong
        }

        guard let best = bestCandidate(in: results, trackSeconds: seconds) else {
            writeDebugLog(
                "[Bini] no candidate within \(Self.lengthSlackSeconds)s of \(seconds)s"
            )
            throw LyricsError.noSuchSong
        }

        guard let ttml = LyricsSourceHTTP.getText(best.url, tag: "Bini"), !ttml.isEmpty else {
            writeDebugLog("[Bini] \(best.url.absoluteString) gave no body")
            throw LyricsError.noSuchSong
        }

        guard let dto = Self.makeDto(fromTTML: ttml) else {
            writeDebugLog("[Bini] \(best.url.absoluteString) had nothing the page could show")
            throw LyricsError.noSuchSong
        }

        writeDebugLog(
            "[Bini] \"\(title)\" — \(artist): \(dto.lines.count) line(s),"
                + " \(best.wordTimed ? "word timed" : "line timed")"
        )
        return dto
    }

    /// 逐字优先，其次时长更接近；两条都过不了容差的直接丢掉。
    ///
    /// ⚠️ 与 Taurus 的 `bestOf` 逐条对齐：**先判逐字，再判时长**。
    ///   反过来的话"时长更准的行级"会顶掉"时长差 3 秒的逐字"，
    ///   而用户开逐字开关要的正是后者。
    private func bestCandidate(
        in results: [Any],
        trackSeconds: Int
    ) -> (url: URL, wordTimed: Bool, off: Int)? {
        var best: (url: URL, wordTimed: Bool, off: Int)?

        for item in results {
            guard let candidate = item as? [String: Any],
                  let raw = candidate["lyricsUrl"] as? String,
                  !raw.isEmpty,
                  let url = URL(string: raw) else { continue }

            let length = (candidate["duration"] as? NSNumber)?.intValue ?? 0
            let off = (trackSeconds > 0 && length > 0) ? abs(length - trackSeconds) : 0
            if off > Self.lengthSlackSeconds { continue }

            let wordTimed = (candidate["timing_type"] as? String) == "word"

            if let current = best {
                if current.wordTimed && !wordTimed { continue }
                if current.wordTimed == wordTimed && off >= current.off { continue }
            }
            best = (url, wordTimed, off)
        }

        return best
    }

    /// TTML → dto。解析与映射与 AMLL / Apple Music 官方那两条线**共用同一套**代码。
    ///
    /// ⚠️ 候选声明的 `timing_type` **不改写 dto**：最终是逐字还是逐行，由
    ///   `hasUsableWordLevelData` 按**解析出来的行**判 —— 那是自动优选与渲染层共用的唯一口径。
    ///   候选自称 "word" 而 TTML 里只有 `<p begin>` 的情况确实存在（AMLL 也一样），
    ///   信声明就会做出"标着逐字、实际逐行"的错配。
    private static func makeDto(fromTTML ttml: String) -> LyricsDto? {
        guard let parsed = try? AmllTtmlParser.parse(ttml) else { return nil }
        let dto = AmllLyricsMapper.makeDto(parsed, logTag: "Bini")
        return dto.lines.isEmpty ? nil : dto
    }
}
