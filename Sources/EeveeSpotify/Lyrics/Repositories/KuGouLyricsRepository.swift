import Foundation

/// 酷狗 —— 中文曲库里少数能给到**逐字**的那一档（KRC）。
///
/// ── 两个请求
/// 1. 搜：`https://krcs.kugou.com/search?ver=1&man=yes&client=mobi&keyword=<歌手 - 歌名>`
/// 2. 下：`https://lyrics.kugou.com/download?ver=1&client=pc&id=&accesskey=&fmt=krc`
///
/// 搜索回的每条候选带 `id` + `accesskey`，两个都要原样带进下载 —— 少一个就是 404。
///
/// ── 挑候选的三条闸
/// · `product_from == "ugc"` 丢掉：那是用户上传的，错字与错轴极多；
/// · 标题（去标点后）必须**完全相等**、歌手互相包含；
/// · 时长差 ≤ 8 秒（KRC 的 duration 是毫秒，比 QQ 的整秒准，但翻唱版差得也多）。
/// 通过闸的按"时长最接近"排序，**最多试 3 条**：KRC 偶尔会有"条目在、内容解不开"的，
/// 试下一条比直接放弃划算；但试太多会把链路拖长。
///
/// ── KRC 怎么解
/// 见 `KrcText`。一句话：base64 → `"krc1"` 魔数 → 16 字节 XOR → zlib 解压 → 逐行解析。
final class KuGouLyricsRepository: LyricsRepository {

    static let shared = KuGouLyricsRepository()
    private init() {}

    private static let searchAPI = "https://krcs.kugou.com/search"
    private static let downloadAPI = "https://lyrics.kugou.com/download"

    /// 毫秒。KRC 的时长字段本身是毫秒，所以这里也用毫秒比。
    private static let lengthSlackMs = 8000

    /// 最多试几条候选。Taurus 用的也是 3。
    private static let maxTriedSongs = 3

    private static let headers = ["User-Agent": LyricsSourceHTTP.browserUserAgent]

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let title = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = LyricsMatch.leadArtist(query.primaryArtist)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !LyricsMatch.key(title).isEmpty, !LyricsMatch.key(lead).isEmpty else {
            writeDebugLog("[KuGou] search skipped — empty title or artist")
            throw LyricsError.noSuchSong
        }

        let trackMs = query.durationMs ?? 0

        var components = URLComponents(string: Self.searchAPI)
        var items = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "man", value: "yes"),
            URLQueryItem(name: "client", value: "mobi"),
            URLQueryItem(name: "hash", value: ""),
            URLQueryItem(name: "album_audio_id", value: ""),
            // 酷狗的搜索串是「歌手 - 歌名」，顺序不能反。
            URLQueryItem(name: "keyword", value: "\(lead) - \(title)")
        ]
        if trackMs > 0 { items.append(URLQueryItem(name: "duration", value: String(trackMs))) }
        components?.queryItems = items
        guard let searchURL = components?.url else { throw LyricsError.decodingError }

        writeDebugLog("[KuGou] searching \"\(title)\" — \(lead)")
        guard let root = LyricsSourceHTTP.getJSON(searchURL, headers: Self.headers, tag: "KuGou"),
              let candidates = LyricsSourceHTTP.dig(root, ["candidates"]) as? [Any] else {
            writeDebugLog("[KuGou] search returned nothing usable")
            throw LyricsError.noSuchSong
        }

        let fitting = fittingCandidates(in: candidates, title: title, artist: lead, trackMs: trackMs)
        guard !fitting.isEmpty else {
            writeDebugLog(
                "[KuGou] \"\(title)\" — \(lead): no candidate matched the length"
                    + " (slack \(Self.lengthSlackMs / 1000)s)"
            )
            throw LyricsError.noSuchSong
        }

        for candidate in fitting.prefix(Self.maxTriedSongs) {
            if let dto = tryDownload(candidate) {
                writeDebugLog(
                    "[KuGou] lyrics \(candidate.id) gave \(dto.lines.count) line(s)"
                        + (dto.lines.contains { !($0.words ?? []).isEmpty } ? ", word timed" : "")
                )
                return dto
            }
        }

        writeDebugLog("[KuGou] \(fitting.count) candidate(s), none had usable lyrics")
        throw LyricsError.noSuchSong
    }

    // MARK: - 候选

    private struct Candidate {
        let id: String
        let accessKey: String
        let durationMs: Int
    }

    private func fittingCandidates(
        in raw: [Any],
        title: String,
        artist: String,
        trackMs: Int
    ) -> [Candidate] {
        let wanted = LyricsMatch.key(title)
        var out: [Candidate] = []

        for item in raw {
            guard let entry = item as? [String: Any] else { continue }
            guard let id = Self.string(in: entry["id"]), !id.isEmpty,
                  let accessKey = Self.string(in: entry["accesskey"]), !accessKey.isEmpty else { continue }

            // 上传的那一批（`ugc`）错字、错轴都多，直接跳过。
            if (entry["product_from"] as? String) == "ugc" { continue }

            guard LyricsMatch.key(entry["song"] as? String) == wanted else { continue }
            guard LyricsMatch.sameArtist(entry["singer"] as? String, artist) else { continue }

            let durationMs = (entry["duration"] as? NSNumber)?.intValue ?? 0
            guard LyricsMatch.lengthMatches(
                durationMs > 0 ? durationMs : nil,
                trackMs > 0 ? trackMs : nil,
                slackMs: Self.lengthSlackMs
            ) else { continue }

            out.append(Candidate(id: id, accessKey: accessKey, durationMs: durationMs))
        }

        // 时长最接近的排前面；缺时长的（durationMs == 0）当作最不接近。
        return out.sorted { a, b in
            let da = a.durationMs > 0 && trackMs > 0 ? abs(a.durationMs - trackMs) : Int.max
            let db = b.durationMs > 0 && trackMs > 0 ? abs(b.durationMs - trackMs) : Int.max
            return da < db
        }
    }

    private static func string(in value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    // MARK: - 下载

    private func tryDownload(_ candidate: Candidate) -> LyricsDto? {
        var components = URLComponents(string: Self.downloadAPI)
        components?.queryItems = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "id", value: candidate.id),
            URLQueryItem(name: "accesskey", value: candidate.accessKey),
            URLQueryItem(name: "fmt", value: "krc"),
            URLQueryItem(name: "charset", value: "utf8")
        ]
        guard let url = components?.url else { return nil }

        guard let root = LyricsSourceHTTP.getJSON(url, headers: Self.headers, tag: "KuGou") else {
            return nil
        }
        let status = (LyricsSourceHTTP.dig(root, ["status"]) as? NSNumber)?.intValue ?? 0
        guard status == 200 else {
            writeDebugLog("[KuGou] download \(candidate.id) answered status \(status)")
            return nil
        }
        guard let content = LyricsSourceHTTP.dig(root, ["content"]) as? String, !content.isEmpty else {
            return nil
        }

        // `contenttype == 2` 是**未加密的纯文本 LRC**（base64），不是 KRC。
        // Taurus 那条路只认 KRC，会把这一档当成失败；这里顺手接住。
        let contentType = (LyricsSourceHTTP.dig(root, ["contenttype"]) as? NSNumber)?.intValue ?? 0
        if contentType == 2 {
            guard let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters),
                  let lrc = String(data: data, encoding: .utf8),
                  let dto = LrcText.dto(from: lrc) else { return nil }
            writeDebugLog("[KuGou] download \(candidate.id) was plain LRC")
            return dto
        }

        return KrcText.dto(fromBase64: content)
    }
}
