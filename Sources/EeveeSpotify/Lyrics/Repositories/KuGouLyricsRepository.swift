import Foundation

/// 酷狗 —— 中文曲库里少数能给到**逐字**的那一档（KRC）。
///
/// ── 三个请求
/// 1. 找歌：`https://songsearch.kugou.com/song_search_v2?keyword=<歌名>`（HTTPS）
/// 2. 找词：`https://krcs.kugou.com/search?…&hash=<FileHash>&album_audio_id=<MixSongID>`
/// 3. 下词：`https://lyrics.kugou.com/download?ver=1&client=pc&id=&accesskey=&fmt=krc`
///
/// ── 为什么必须先找歌
/// 第 2 步的 `keyword` 是**酷狗曲库自己的**「歌手 - 歌名」。Spotify 给的是罗马字艺人
/// （`Sasuke Haraguchi` / `Rokudenashi`），酷狗那边写的是日文（`原口沙輔` / `ロクデナシ`）
/// ⇒ 拿我们的拼串去搜，这两个源之间的**同名不同文**直接把候选打成 0。
/// 第 1 步按**歌名**搜（`songsearch_v2` 支持中文/日文且不挑艺人），拿回 `FileHash` 与
/// `MixSongID`，第 2 步用这两个精确字段取词 —— 同一条目能取到带 `日本語` 标签的官方 KRC。
///
/// ── 挑候选的闸
/// · 标题：`LyricsMatch.titlesMatch`（去括号段 —— QQ/酷狗的条目普遍带 `(人狂热症)(Explicit)`）；
/// · 时长：差 ≤ 8 秒（KRC 的 duration 是毫秒，比 QQ 的整秒准，但翻唱版差得也多）；
/// · 歌手：**只作为排序偏好，不再是硬闸** —— 日文歌的 `singer` 常写演唱者（初音/重音テト），
///   与 Spotify 的 P 名对不上；硬闸会把这一类整批挡掉；
/// · `product_from == "ugc"` 的用户上传排到最后而不是丢掉：某些日文歌在酷狗**只有** UGC 那一档。
///
/// ── 罗马字版 KRC
/// 酷狗会给一部分日文歌**单独发一版"罗马字歌词"**：正文本身就是 `o yo gu yo u ni …`，
/// 没有日文原文。它排在候选前面时，选中就是"正文被罗马字替换"。这里用正文的 CJK 占比
/// 判掉，继续试后面那一条（酷狗通常同时有日文版）。
///
/// ── KRC 怎么解
/// 见 `KrcText`。一句话：base64 → `"krc1"` 魔数 → 16 字节 XOR → zlib 解压 → 逐行解析。
final class KuGouLyricsRepository: LyricsRepository {

    static let shared = KuGouLyricsRepository()
    private init() {}

    private static let songSearchAPI = "https://songsearch.kugou.com/song_search_v2"
    private static let searchAPI = "https://krcs.kugou.com/search"
    private static let downloadAPI = "https://lyrics.kugou.com/download"

    /// 毫秒。KRC 的时长字段本身是毫秒，所以这里也用毫秒比。
    private static let lengthSlackMs = 8000

    /// 最多试几个歌名命中（每个再配几条 KRC 候选）。
    private static let maxTriedSongs = 3

    /// 每个歌名最多下几条 KRC。KRC 偶尔"条目在、内容解不开"，试下一条比直接放弃划算；
    /// 但每多一条就多一次下载，链路本来就慢，所以上限压得低。
    private static let maxTriedCandidates = 3

    /// 一次取词最多下几份 KRC（跨"多个歌名命中 + 多条候选"合计）。每次下载都是同步网络往返，
    /// 而这条源在自动优选里只有 5 秒预算 —— 不封顶时最坏会把 12 次往返排进去。
    private static let maxDownloads = 5

    private static let headers = ["User-Agent": LyricsSourceHTTP.browserUserAgent]

    /// 曲库条目的时长是**整秒**。
    private static let songSearchSlackMs = 8000

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let title = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = LyricsMatch.leadArtist(query.primaryArtist)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !LyricsMatch.key(title).isEmpty, !LyricsMatch.key(lead).isEmpty else {
            writeDebugLog("[KuGou] search skipped — empty title or artist")
            throw LyricsError.noSuchSong
        }

        let trackMs = query.durationMs ?? 0
        let expectsCJK = Self.prefersCJKBody(title: title, artist: lead, query: query)
        // 同一首在 Spotify 侧可能有两个标题（曲目名 / 本地化名）。搜索与**判定**都用这一份：
        // 拿本地化名搜出来的条目，绝不能再用曲目名去比（那正是"变体搜到了又被丢掉"的成因）。
        let wantedTitles = Self.titleCandidates(title: title, query: query)

        var songs = songHits(wanted: wantedTitles, artist: lead, trackMs: trackMs)
        var searchedByTitle = !songs.isEmpty
        if songs.isEmpty {
            // 第 1 步的接口不认（或这首在酷狗歌曲库里没有）时退回老的「歌手 - 歌名」关键词。
            songs = keywordHits(wanted: wantedTitles, artist: lead, trackMs: trackMs)
            searchedByTitle = false
        }

        var romanizedFallback: LyricsDto?
        var downloadsLeft = Self.maxDownloads

        func collect(from songs: [SongHit]) -> LyricsDto? {
            for song in songs.prefix(Self.maxTriedSongs) {
                guard downloadsLeft > 0 else { return nil }
                let candidates = lyricCandidates(for: song, wanted: wantedTitles, trackMs: trackMs)
                for candidate in candidates.prefix(Self.maxTriedCandidates) {
                    guard downloadsLeft > 0 else { return nil }
                    downloadsLeft -= 1
                    guard let downloaded = tryDownload(candidate) else { continue }
                    var dto = downloaded
                    // 众包贡献者来自**条目元信息**（`nickname` / `transname`），
                    // 覆盖 KRC 文件头 `[by:]` 那一档（酷狗这边通常为空）。
                    let contributors = Self.contributors(for: candidate)
                    if !contributors.isEmpty { dto.providerContributors = contributors }

                    if expectsCJK, Self.bodyLooksRomanized(dto) {
                        writeDebugLog(
                            "[KuGou] lyrics \(candidate.id) is the romanised edition"
                                + " (body is Latin) — trying the next candidate"
                        )
                        if romanizedFallback == nil { romanizedFallback = dto }
                        continue
                    }

                    writeDebugLog(
                        "[KuGou] lyrics \(candidate.id) gave \(dto.lines.count) line(s)"
                            + (dto.lines.contains { !($0.words ?? []).isEmpty } ? ", word timed" : "")
                            + (dto.translation?.lines.contains { !$0.isEmpty } == true ? ", translated" : "")
                            + (contributors.isEmpty ? "" : ", credit \(contributors.map(\.name).joined(separator: "/"))")
                    )
                    return dto
                }
            }
            return nil
        }

        var result = collect(from: songs)

        // 歌名那条路**找到了歌**、却一条词也没下来 ⇒ 老关键词那条还值得再试一次
        // （两边的排序与候选集不同；只在"已经走关键词"时跳过，免得同一个请求发两遍）。
        if result == nil, searchedByTitle {
            let legacy = keywordHits(wanted: wantedTitles, artist: lead, trackMs: trackMs)
            if !legacy.isEmpty {
                downloadsLeft = Self.maxDownloads
                result = collect(from: legacy)
            }
        }

        if let result { return result }

        if let romanizedFallback {
            // 整首只有罗马字版：总比没有强，交给链路继续判档位。
            writeDebugLog("[KuGou] only a romanised edition was available — using it")
            return romanizedFallback
        }

        writeDebugLog("[KuGou] \"\(title)\" — \(lead): no usable lyrics")
        throw LyricsError.noSuchSong
    }

    /// 参与搜索与判定的标题：曲目名在前，本地化名随后（去重、去空白）。
    private static func titleCandidates(title: String, query: LyricsSearchQuery) -> [String] {
        var out: [String] = []
        for variant in [title] + query.titleVariants {
            let trimmed = variant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !out.contains(trimmed) else { continue }
            out.append(trimmed)
        }
        return out
    }

    // MARK: - 第 1 步：找歌（按歌名）

    private struct SongHit {
        /// `FileHash`；走旧关键词路时这里是 KRC 条目自己的 `id`。
        let hash: String
        /// `MixSongID`；走旧关键词路时这里是 `accesskey`。
        let albumAudioId: String
        let durationMs: Int
        let singer: String
        let title: String
        /// 旧关键词路：已经拿到 id/accesskey，第 2 步不用再搜一次。
        let isDirect: Bool
        /// 曲库返回顺序（同分时用它兜底：Swift 的 `sorted` 不保证稳定）。
        let order: Int
    }

    private func songHits(wanted: [String], artist: String, trackMs: Int) -> [SongHit] {
        var hits: [SongHit] = []
        for keyword in wanted.prefix(2) {
            for hit in songSearchHits(keyword: keyword, wanted: wanted, trackMs: trackMs) {
                if !hits.contains(where: { $0.hash == hit.hash }) { hits.append(hit) }
            }
            if !hits.isEmpty { break }
        }
        guard !hits.isEmpty else {
            writeDebugLog("[KuGou] song search \"\(wanted.first ?? "")\" found nothing")
            return []
        }

        let ranked = hits.compactMap { hit -> (SongHit, Int, Int)? in
            guard LyricsMatch.lengthMatches(
                hit.durationMs > 0 ? hit.durationMs : nil,
                trackMs > 0 ? trackMs : nil,
                slackMs: Self.songSearchSlackMs
            ) else { return nil }
            // 排序键：先"歌手对得上"，再"时长最接近"。
            let artistRank = LyricsMatch.sameArtist(hit.singer, artist) ? 0 : 1
            return (hit, artistRank, LyricsMatch.lengthGap(hit.durationMs, trackMs) ?? Int.max)
        }
        .sorted { left, right in
            if left.1 != right.1 { return left.1 < right.1 }
            if left.2 != right.2 { return left.2 < right.2 }
            return left.0.order < right.0.order
        }
        .map(\.0)

        guard !ranked.isEmpty else {
            writeDebugLog(
                "[KuGou] song search \"\(wanted.first ?? "")\" — \(hits.count) hit(s), none within"
                    + " \(Self.songSearchSlackMs / 1000)s of \(trackMs)ms"
            )
            return []
        }
        writeDebugLog("[KuGou] song search \"\(wanted.first ?? "")\": \(ranked.count) playable match(es)")
        return Array(ranked.prefix(Self.maxTriedSongs))
    }

    private func songSearchHits(keyword: String, wanted: [String], trackMs: Int) -> [SongHit] {
        var components = URLComponents(string: Self.songSearchAPI)
        components?.queryItems = [
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "pagesize", value: "10"),
            URLQueryItem(name: "platform", value: "WebFilter"),
            URLQueryItem(name: "userid", value: "-1"),
            URLQueryItem(name: "clientver", value: ""),
            URLQueryItem(name: "iscorrection", value: "1"),
            URLQueryItem(name: "privilege_filter", value: "0"),
            URLQueryItem(name: "filter", value: "10"),
            URLQueryItem(name: "area_code", value: "1")
        ]
        guard let url = components?.url else { return [] }
        guard let root = LyricsSourceHTTP.getJSON(url, headers: Self.headers, tag: "KuGou"),
              let list = LyricsSourceHTTP.dig(root, ["data", "lists"]) as? [Any] else {
            return []
        }

        var out: [SongHit] = []
        for item in list {
            guard let entry = item as? [String: Any] else { continue }
            guard let hash = Self.string(in: entry["FileHash"]), !hash.isEmpty,
                  let aaid = Self.string(in: entry["MixSongID"]), !aaid.isEmpty else { continue }

            // `OriSongName` 是**去后缀**的歌名（`SongName` 常带 `(Explicit)` / 译文）。
            let name = Self.string(in: entry["OriSongName"])
                ?? Self.string(in: entry["SongName"])
                ?? ""
            guard LyricsMatch.titlesMatch(name, anyOf: wanted)
                    || LyricsMatch.titlesMatch(Self.string(in: entry["SongName"]), anyOf: wanted) else {
                continue
            }

            let seconds = Self.int(in: entry["Duration"])
            let durationMs = seconds > 0 ? seconds * 1000 : 0
            guard LyricsMatch.lengthMatches(
                durationMs > 0 ? durationMs : nil,
                trackMs > 0 ? trackMs : nil,
                slackMs: Self.songSearchSlackMs
            ) else { continue }

            out.append(
                SongHit(
                    hash: hash,
                    albumAudioId: aaid,
                    durationMs: durationMs,
                    singer: Self.string(in: entry["SingerName"]) ?? "",
                    title: name,
                    isDirect: false,
                    order: out.count
                )
            )
        }
        return out
    }

    // MARK: - 第 1 步的兜底：老的「歌手 - 歌名」关键词

    private func keywordHits(wanted: [String], artist: String, trackMs: Int) -> [SongHit] {
        var components = URLComponents(string: Self.searchAPI)
        var items = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "man", value: "yes"),
            URLQueryItem(name: "client", value: "mobi"),
            URLQueryItem(name: "hash", value: ""),
            URLQueryItem(name: "album_audio_id", value: ""),
            // 酷狗的搜索串是「歌手 - 歌名」，顺序不能反。
            URLQueryItem(name: "keyword", value: "\(artist) - \(wanted.first ?? "")")
        ]
        if trackMs > 0 { items.append(URLQueryItem(name: "duration", value: String(trackMs))) }
        components?.queryItems = items
        guard let url = components?.url else { return [] }

        writeDebugLog("[KuGou] falling back to the artist–title keyword search")
        guard let root = LyricsSourceHTTP.getJSON(url, headers: Self.headers, tag: "KuGou"),
              let candidates = LyricsSourceHTTP.dig(root, ["candidates"]) as? [Any] else {
            return []
        }

        var out: [SongHit] = []
        for item in candidates {
            guard let entry = item as? [String: Any] else { continue }
            guard let id = Self.string(in: entry["id"]), !id.isEmpty,
                  let accessKey = Self.string(in: entry["accesskey"]), !accessKey.isEmpty else { continue }
            guard LyricsMatch.titlesMatch(Self.string(in: entry["song"]), anyOf: wanted) else { continue }

            let durationMs = Self.int(in: entry["duration"])
            guard LyricsMatch.lengthMatches(
                durationMs > 0 ? durationMs : nil,
                trackMs > 0 ? trackMs : nil,
                slackMs: Self.lengthSlackMs
            ) else { continue }

            // 这一档没有 FileHash，第 2 步直接吃 id/accesskey ⇒ 记成"已经带词"的条目。
            out.append(
                SongHit(
                    hash: id,
                    albumAudioId: accessKey,
                    durationMs: durationMs,
                    singer: Self.string(in: entry["singer"]) ?? "",
                    title: Self.string(in: entry["song"]) ?? (wanted.first ?? ""),
                    isDirect: true,
                    order: out.count
                )
            )
        }
        return out
    }

    // MARK: - 第 2 步：找词（hash + album_audio_id）

    private struct Candidate {
        let id: String
        let accessKey: String
        let durationMs: Int
        let isUserUploaded: Bool
        /// 曲库返回顺序（同分兜底）。
        let order: Int
        /// **这份歌词的众包贡献者**（酷狗回包的 `nickname`）与译文贡献者（`transname`）。
        /// 曲目元信息里的作词者不从这里取 —— 那是另一回事。
        let uploader: String?
        let translator: String?
    }

    private func lyricCandidates(for song: SongHit, wanted: [String], trackMs: Int) -> [Candidate] {
        // 关键词兜底那条路已经把 id/accesskey 直接塞进 SongHit 了（它没有 hash）。
        if song.isDirect {
            return [
                Candidate(
                    id: song.hash,
                    accessKey: song.albumAudioId,
                    durationMs: song.durationMs,
                    isUserUploaded: false,
                    order: 0,
                    uploader: nil,
                    translator: nil
                )
            ]
        }

        var components = URLComponents(string: Self.searchAPI)
        var items = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "man", value: "yes"),
            URLQueryItem(name: "client", value: "mobi"),
            URLQueryItem(name: "hash", value: song.hash),
            URLQueryItem(name: "album_audio_id", value: song.albumAudioId),
            URLQueryItem(name: "keyword", value: song.title)
        ]
        if trackMs > 0 { items.append(URLQueryItem(name: "duration", value: String(trackMs))) }
        components?.queryItems = items
        guard let url = components?.url,
              let root = LyricsSourceHTTP.getJSON(url, headers: Self.headers, tag: "KuGou"),
              let raw = LyricsSourceHTTP.dig(root, ["candidates"]) as? [Any] else {
            return []
        }

        var out: [Candidate] = []
        for item in raw {
            guard let entry = item as? [String: Any] else { continue }
            guard let id = Self.string(in: entry["id"]), !id.isEmpty,
                  let accessKey = Self.string(in: entry["accesskey"]), !accessKey.isEmpty else { continue }
            // 条目名普遍带 `(人狂热症)(Explicit)`，与歌名的匹配必须走 `titlesMatch`。
            guard LyricsMatch.titlesMatch(Self.string(in: entry["song"]), anyOf: wanted) else { continue }

            let durationMs = Self.int(in: entry["duration"])
            guard LyricsMatch.lengthMatches(
                durationMs > 0 ? durationMs : nil,
                trackMs > 0 ? trackMs : nil,
                slackMs: Self.lengthSlackMs
            ) else { continue }

            out.append(
                Candidate(
                    id: id,
                    accessKey: accessKey,
                    durationMs: durationMs,
                    isUserUploaded: (entry["product_from"] as? String) == "ugc",
                    order: out.count,
                    uploader: Self.nonEmptyString(entry["nickname"]),
                    translator: Self.nonEmptyString(entry["transname"])
                )
            )
        }

        return out.sorted { left, right in
            if left.isUserUploaded != right.isUserUploaded { return !left.isUserUploaded }
            let leftGap = LyricsMatch.lengthGap(left.durationMs, trackMs) ?? Int.max
            let rightGap = LyricsMatch.lengthGap(right.durationMs, trackMs) ?? Int.max
            if leftGap != rightGap { return leftGap < rightGap }
            return left.order < right.order
        }
    }

    private static func string(in value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// 非空字符串（酷狗把这些字段下发为空串而不是省略）。
    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = string(in: value)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// 这一条歌词的**众包贡献者**：上传者 + （不同人的）译文贡献者。
    private static func contributors(for candidate: Candidate) -> [LyricsContributor] {
        var out: [LyricsContributor] = []
        if let uploader = candidate.uploader {
            out.append(LyricsContributor(role: .uploader, name: uploader, url: nil))
        }
        if let translator = candidate.translator, translator != candidate.uploader {
            out.append(LyricsContributor(role: .translator, name: translator, url: nil))
        }
        return out
    }

    /// JSON 里的整数可能是 `NSNumber`，也可能是 `"127"` 这样的字符串。
    private static func int(in value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) ?? 0 }
        return 0
    }

    // MARK: - 正文语言

    /// 这一首**期不期待 CJK 正文**：查的这首本身是中日韩文（标题或艺人里带 CJK）。
    ///
    /// 只在这种歌上判"正文是不是罗马字版" —— 英文歌的正文本来就该是拉丁字母。
    private static func prefersCJKBody(
        title: String,
        artist: String,
        query: LyricsSearchQuery
    ) -> Bool {
        containsCJK(title) || containsCJK(artist) || query.allArtistNames.contains(where: containsCJK)
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D,
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0xAC00...0xD7AF:
                return true
            default:
                return false
            }
        }
    }

    /// 正文是不是**罗马字 / 拼音版**：CJK 字符占比过低，而拉丁字母不少。
    ///
    /// 判据用"占比"而不是"有没有拉丁字母"：日文歌的正文里常有英文单词，
    /// 而罗马字版**整首**都是拉丁字母（`o yo gu yo u ni …` 里一个汉字/假名都没有）。
    private static func bodyLooksRomanized(_ dto: LyricsDto) -> Bool {
        var cjk = 0
        var latin = 0
        for line in dto.lines {
            for scalar in line.content.unicodeScalars {
                switch scalar.value {
                case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D,
                     0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                     0xAC00...0xD7AF:
                    cjk += 1
                case 0x41...0x5A, 0x61...0x7A:
                    latin += 1
                default:
                    break
                }
            }
        }
        // 整首没有 CJK，却有成片的拉丁字母 ⇒ 罗马字版。
        return cjk == 0 && latin >= 20
    }

    // MARK: - 第 3 步：下载

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


