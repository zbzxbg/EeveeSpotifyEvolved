import Foundation

/// QQ 音乐 —— 中文（国语 / 粤语）曲库，**逐字**（QRC）与逐行（LRC）都有。
///
/// ── 两个请求
/// 1. 搜：`music.search.SearchCgiService / DoSearchForQQMusicDesktop`
/// 2. 词：`music.musichallSong.PlayLyricInfo / GetPlayLyricInfo`
///
/// 两个都打 `https://u.y.qq.com/cgi-bin/musicu.fcg`，body 是
/// `{"comm": {…}, "<模块名>": {module, method, param}}` —— **第二个请求的键是完整模块名**，
/// 不是 `"req"`，这一点很容易抄错（抄错的表现是永远拿不到 `data`）。
///
/// ── 逐字（QRC）
/// 原来这里带的是 `qrc: 0, crypt: 0`，只取明文 LRC（Taurus 的做法）。
/// 现在改成 `qrc: 1, crypt: 1`：`data["qrc_t"] != 0` 时 `data["lyric"]` 是**加密的 QRC**，
/// 解密与解析在 `QrcText` 里（hex → 3DES → zlib → `词(起始,时长)`）。
/// 解不开 / `qrc_t == 0` 时退回 base64 明文 LRC —— 有些条目确实只有行级。
///
/// 所以这个源在自动优选里现在是 **word 档**（`canProduceWordTiming == true`），
/// 具体这一首给到哪一档，由 `hasUsableWordLevelData` 按解析出来的行判。
final class QQMusicLyricsRepository: LyricsRepository {

    static let shared = QQMusicLyricsRepository()
    private init() {}

    private static let api = "https://u.y.qq.com/cgi-bin/musicu.fcg"
    /// 老的网页搜索接口。`musicu.fcg` 的搜索偶尔整段不返回结果（同一请求隔几秒重发就恢复，code=2001），
    /// 这一条是同一份曲库的另一个入口，用来兜住那种情况。
    private static let legacySearchAPI = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp"
    private static let lyricKey = "music.musichallSong.PlayLyricInfo.GetPlayLyricInfo"

    /// QQ 的 `interval` 是整秒，比别的源粗；6 秒容差是 Taurus 用的值。
    private static let lengthSlackSeconds = 6

    /// 歌手对不上时（Spotify 给罗马字、QQ 写给日文/中文名）只认**更紧**的时长差。
    private static let tightSlackSeconds = 2

    private static let headers = [
        "Referer": "https://y.qq.com/",
        "Accept": "application/json"
    ]

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let title = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = LyricsMatch.leadArtist(query.primaryArtist)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !LyricsMatch.key(title).isEmpty, !LyricsMatch.key(lead).isEmpty else {
            writeDebugLog("[QQMusic] search skipped — empty title or artist")
            throw LyricsError.noSuchSong
        }
        guard let url = URL(string: Self.api) else { throw LyricsError.decodingError }

        let seconds = (query.durationMs ?? 0) / 1000

        writeDebugLog("[QQMusic] searching \"\(title)\" — \(lead)")
        var titles: [String] = []
        for variant in [title] + query.titleVariants {
            let trimmed = variant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !titles.contains(trimmed) else { continue }
            titles.append(trimmed)
        }
        let hits = searchSongs(titles: Array(titles.prefix(2)), artist: lead)
        guard let songId = pickSong(in: hits, titles: titles, artist: lead, seconds: seconds) else {
            writeDebugLog(
                "[QQMusic] \"\(title)\" — \(lead): \(hits.count) hit(s), none was this recording"
                    + " (slack \(Self.lengthSlackSeconds)s; \(Self.tightSlackSeconds)s when the singer does not match)"
            )
            throw LyricsError.noSuchSong
        }

        writeDebugLog("[QQMusic] song \(songId) — asking for its lyric")
        let lyricBody: [String: Any] = [
            "comm": ["ct": "19", "cv": "1859", "uin": "0"],
            Self.lyricKey: [
                "module": "music.musichallSong.PlayLyricInfo",
                "method": "GetPlayLyricInfo",
                // 从 `qrc: 0` 改成 `qrc: 1, crypt: 1` —— 要逐字。
                // 参数表照 `chenmozhijin/LDDC` 的 `get_lyrics`（它拿到的是能解开的 QRC）：
                // `songName` / `singerName` / `albumName` 是 **base64 的 UTF-8**，
                // `interval` 是**秒**，其余几个 `*_t` 是"要不要翻译/罗马音"的开关。
                //
                // ⚠️ `roma` 不置 1 时 `data.roma` 恒为空 —— 服务端只在被要求时才下发那份
                // 官方逐词罗马字。文件头说的"有罗马音就用"因此在这之前是**永远走不到**的分支。
                "param": [
                    "albumName": Self.base64(query.albumTitle ?? ""),
                    "crypt": 1,
                    "ct": 19,
                    "cv": 2111,
                    "interval": seconds,
                    "lrc_t": 0,
                    "qrc": 1,
                    "qrc_t": 0,
                    "roma": 1,
                    "roma_t": 0,
                    "singerName": Self.base64(lead),
                    "songID": songId,
                    "songName": Self.base64(title),
                    "trans": 1,
                    "trans_t": 0,
                    "type": 0
                ]
            ]
        ]

        guard let lyricRoot = LyricsSourceHTTP.postJSON(
            url, body: lyricBody, headers: Self.headers, tag: "QQMusic"
        ) else {
            throw LyricsError.noSuchSong
        }

        let payload = LyricsSourceHTTP.dig(lyricRoot, [Self.lyricKey, "data"]) as? [String: Any]
        let encoded = payload?["lyric"] as? String ?? ""
        let romaPayload = payload?["roma"] as? String
        let romaType = Self.intValue(payload?["roma_t"])
        let transPayload = payload?["trans"] as? String
        let transType = Self.intValue(payload?["trans_t"])

        // `qrc_t != 0` 表示 `lyric` 里是**加密的逐字 QRC**；等于 0 才是 base64 的明文 LRC。
        // 两个字段都可能是数字也可能是字符串（不同接口版本不一致），统一按 int 读。
        let qrcType = Self.intValue(payload?["qrc_t"])
        if qrcType != 0, !encoded.isEmpty {
            if let dto = QrcText.dto(fromEncrypted: encoded) {
                writeDebugLog(
                    "[QQMusic] song \(songId): \(dto.lines.count) word-timed line(s) from QRC"
                )
                let translated = Self.attachingTranslation(
                    to: dto, payload: transPayload, type: transType
                )
                return Self.attachingOfficialRomaji(to: translated, payload: romaPayload, type: romaType)
            }
            writeDebugLog("[QQMusic] song \(songId): QRC would not decrypt — trying plain LRC")
        }

        guard !encoded.isEmpty,
              let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              let lrc = String(data: data, encoding: .utf8) else {
            writeDebugLog("[QQMusic] song \(songId) gave no decodable lyric")
            throw LyricsError.noSuchSong
        }

        guard let dto = LrcText.dto(from: lrc) else {
            writeDebugLog("[QQMusic] song \(songId) gave no timed line")
            throw LyricsError.noSuchSong
        }

        writeDebugLog("[QQMusic] song \(songId): \(dto.lines.count) line-timed line(s) from LRC")
        let translated = Self.attachingTranslation(to: dto, payload: transPayload, type: transType)
        return Self.attachingOfficialRomaji(to: translated, payload: romaPayload, type: romaType)
    }

    // MARK: - 官方罗马字

    /// 把 QQ 的官方罗马字（`roma` 字段）贴到歌词上。
    ///
    /// 它和正文是**两个独立的加密 QRC**（同一套 `QrcText` 解），但**行不保证一一对应**：
    /// 罗马音那侧还会下发只有时间、没有字的行（解析器会丢掉），主歌词这侧又刚剔掉了
    /// 制作信息行。所以按**行起始时间**配，不按下标 —— 与 Musixmatch 把 richsync
    /// 按行起点贴回行级是同一套做法。
    ///
    /// 只在这一首**有罗马音、且解得开**时才动 `officialRomanizedLines`；
    /// 配对率低于 60% 视为“两份不是同一版词”，整份不用（宁可退回本地转换）。
    private static func attachingOfficialRomaji(
        to dto: LyricsDto,
        payload romaPayload: String?,
        type romaType: Int
    ) -> LyricsDto {
        guard romaType != 0,
              let payload = romaPayload, !payload.isEmpty else { return dto }

        guard let romaDto = QrcText.dto(fromEncrypted: payload) else {
            writeDebugLog("[QQMusic] roma would not decrypt — keeping lyrics without official romaji")
            return dto
        }

        var byStart: [Int: String] = [:]
        for line in romaDto.lines {
            guard let start = line.offsetMs else { continue }
            let text = line.content.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, byStart[start] == nil else { continue }
            byStart[start] = text
        }
        guard !byStart.isEmpty else { return dto }

        var romaji: [String] = []
        romaji.reserveCapacity(dto.lines.count)
        var matched = 0
        for line in dto.lines {
            guard let start = line.offsetMs,
                  let hit = byStart[start] ?? nearby(start, in: byStart) else {
                romaji.append("")
                continue
            }
            romaji.append(hit)
            matched += 1
        }

        guard matched * 5 >= dto.lines.count * 3 else {
            writeDebugLog(
                "[QQMusic] official romaji matched \(matched)/\(dto.lines.count) line(s) — dropped"
            )
            return dto
        }

        var result = dto
        result.officialRomanizedLines = romaji
        // 语言写进 dto：显示层按它挑「该看哪个罗马化开关」（ja/zh/ko 三个键）。
        if let languageCode = dto.lines.map(\.content).romanizationLanguageCode,
           !languageCode.isEmpty {
            result.languageCode = languageCode
        }
        writeDebugLog("[QQMusic] official romaji attached — \(matched)/\(dto.lines.count) line(s)")
        return result
    }

    /// 两份 QRC 的行起点常差 1~2ms（同一次转码的取整不同；实测 `947` 对 `946`）⇒
    /// 按最近的起点匹配。逐毫秒扫是因为差值是 1 这种，不能用固定步长。
    ///
    /// 默认 100ms 给罗马字；译文是另一份 LRC，和正文分行不完全一致，用 250ms 更稳。
    private static func nearby(_ start: Int, in map: [Int: String], maxDelta: Int = 100) -> String? {
        for delta in 1...max(1, maxDelta) {
            if let hit = map[start + delta] { return hit }
            if let hit = map[start - delta] { return hit }
        }
        return nil
    }

    // MARK: - 官方译文

    /// 把 QQ 的官方译文（`data.trans`）贴到歌词上。
    ///
    /// `trans_t != 0` 时 `trans` 是**加密的 LRC**（正文是 `[mm:ss.xx]译文` 行，不是逐字 QRC），
    /// 用同一个 `QrcText.decode` 解就行；`trans_t == 0` 时是 base64 明文 LRC。
    ///
    /// 译文与正文**不保证一一对应**：前几行常是 `//` 或「TME享有本翻译作品的著作权」声明，
    /// 也有整行漏翻的 ⇒ 按**行起点**配，配不到留空串（与 romaji 同一套做法）。
    /// 配对率低于 40% 视为"两份不是同一版"，整份不用。
    private static func attachingTranslation(
        to dto: LyricsDto,
        payload: String?,
        type: Int
    ) -> LyricsDto {
        guard let payload, !payload.isEmpty else { return dto }

        let text: String?
        if type != 0 {
            text = QrcText.decode(payload)
        } else if let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) {
            text = String(data: data, encoding: .utf8)
        } else {
            text = nil
        }
        guard let text, !text.isEmpty else {
            writeDebugLog("[QQMusic] translation would not decode — keeping lyrics without it")
            return dto
        }

        var byStart: [Int: String] = [:]
        for line in LrcText.lines(from: text) {
            guard let start = line.offsetMs else { continue }
            let value = line.content.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, !isTranslationNotice(value), byStart[start] == nil else { continue }
            byStart[start] = value
        }
        guard !byStart.isEmpty else { return dto }

        var lines: [String] = []
        lines.reserveCapacity(dto.lines.count)
        var matched = 0
        for line in dto.lines {
            let original = line.content.trimmingCharacters(in: .whitespaces)
            guard let start = line.offsetMs,
                  let hit = byStart[start] ?? nearby(start, in: byStart, maxDelta: 250),
                  hit != original else {
                lines.append("")
                continue
            }
            lines.append(hit)
            matched += 1
        }

        guard matched * 5 >= dto.lines.count * 2 else {
            writeDebugLog(
                "[QQMusic] official translation matched \(matched)/\(dto.lines.count) line(s) — dropped"
            )
            return dto
        }

        var result = dto
        result.translation = LyricsTranslationDto(languageCode: "zh", lines: lines)
        writeDebugLog("[QQMusic] official translation attached — \(matched)/\(dto.lines.count) line(s)")
        return result
    }

    /// 译文里的声明/占位行（不是歌词）。
    private static func isTranslationNotice(_ text: String) -> Bool {
        if text == "//" { return true }
        for marker in ["TME享有", "翻译作品", "以下歌词", "翻译由", "QQ音乐"] {
            if text.contains(marker) { return true }
        }
        return false
    }

    /// QQ 的 `songName` / `singerName` / `albumName` 要 base64 的 UTF-8。
    private static func base64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    /// JSON 里的数字可能是 `NSNumber`，也可能是 `"0"` 这样的字符串。
    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) ?? 0 }
        return 0
    }

    // MARK: - 搜歌
    //
    // 两个入口、两种查询串，合并去重：
    // · `musicu.fcg` 是桌面端搜索，结果里 `title` 常带译名后缀（`人マニア (人狂热症)`）；
    // · `client_search_cp` 是网页搜索，同一个曲库的另一条路 —— 前者整段失败时兜底。
    // 查询串先试**纯歌名**、再试「歌名 艺人」：日文歌的艺人字段两边写法常常不同，
    // 带着罗马字艺人搜反而会把正确的条目挤出前 8 条之外。
    private struct SongHit {
        let id: Int
        let title: String
        let singers: [String]
        let durationMs: Int
        /// 在合并后的命中列表里的位置。同分时保留**搜索相关性顺序**（曲库把原版排前面），
        /// 而不是按 id 挑一个 —— 后者等于掷骰子。
        let order: Int
    }

    private func searchSongs(titles: [String], artist: String) -> [SongHit] {
        var hits: [SongHit] = []
        func append(_ batch: [SongHit]) {
            for hit in batch where !hits.contains(where: { $0.id == hit.id }) {
                hits.append(SongHit(id: hit.id, title: hit.title, singers: hit.singers,
                                    durationMs: hit.durationMs, order: hits.count))
            }
        }

        // 每一轮都是**同步阻塞**的网络往返，所以"命中即停"：纯歌名的结果通常已经把原版排在最前，
        // 再补「歌名 艺人」只会把预算翻倍（这条源在自动优选里只有 5 秒）。
        for title in titles {
            append(musicuSearch(title))
            if !hits.isEmpty { return hits }
            append(musicuSearch("\(title) \(artist)"))
            if !hits.isEmpty { return hits }
        }

        // 两个接口都只是"同一份曲库的两个入口"：上面整段空手才走网页那条。
        for title in titles {
            append(legacySearch(title))
            if !hits.isEmpty { return hits }
            append(legacySearch("\(title) \(artist)"))
            if !hits.isEmpty { return hits }
        }
        return hits
    }

    private func musicuSearch(_ query: String) -> [SongHit] {
        guard let url = URL(string: Self.api) else { return [] }
        let body: [String: Any] = [
            "comm": ["ct": "19", "cv": "1859", "uin": "0"],
            "req": [
                "module": "music.search.SearchCgiService",
                "method": "DoSearchForQQMusicDesktop",
                "param": [
                    "query": query,
                    "search_type": 0,
                    "grp": 1,
                    "num_per_page": 10,
                    "page_num": 1
                ]
            ]
        ]
        guard let root = LyricsSourceHTTP.postJSON(
            url, body: body, headers: Self.headers, tag: "QQMusic"
        ), let list = LyricsSourceHTTP.dig(root, ["req", "data", "body", "song", "list"]) as? [Any] else {
            return []
        }
        return Self.songHits(from: list)
    }

    private func legacySearch(_ query: String) -> [SongHit] {
        var components = URLComponents(string: Self.legacySearchAPI)
        components?.queryItems = [
            URLQueryItem(name: "w", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "n", value: "10"),
            URLQueryItem(name: "p", value: "1"),
            URLQueryItem(name: "cr", value: "1"),
            URLQueryItem(name: "t", value: "0")
        ]
        guard let url = components?.url,
              let root = LyricsSourceHTTP.getJSON(url, headers: Self.headers, tag: "QQMusic"),
              let list = LyricsSourceHTTP.dig(root, ["data", "song", "list"]) as? [Any] else {
            return []
        }
        return Self.songHits(from: list)
    }

    /// 把两种搜索响应的条目归一。字段名不同：`musicu` 用 `id`，网页那条用 `songid`。
    private static func songHits(from list: [Any]) -> [SongHit] {
        var out: [SongHit] = []
        for item in list {
            guard let song = item as? [String: Any] else { continue }
            guard let id = (song["id"] as? NSNumber)?.intValue
                    ?? (song["songid"] as? NSNumber)?.intValue else { continue }

            let name = (song["title"] as? String)
                ?? (song["songname"] as? String)
                ?? (song["name"] as? String)
                ?? ""
            let singers = ((song["singer"] as? [Any]) ?? []).compactMap { entry -> String? in
                guard let singer = entry as? [String: Any] else { return nil }
                return singer["name"] as? String
            }
            let interval = (song["interval"] as? NSNumber)?.intValue ?? 0
            out.append(
                SongHit(
                    id: id,
                    title: name,
                    singers: singers,
                    durationMs: interval > 0 ? interval * 1000 : 0,
                    order: out.count
                )
            )
        }
        return out
    }

    // MARK: - 挑歌

    /// 这一条候选是不是"就是这首歌"的录音。
    ///
    /// 三条闸，按"多可信"排：
    /// · **标题**：`LyricsMatch.titlesMatch`（`key` 相等，或去掉括号段后相等）；
    /// · **时长**：差 ≤ 6s；
    /// · **歌手**：对得上就放行；对不上时（Spotify 给罗马字、QQ 写日文/中文名）
    ///   还要求时长差 ≤ 2s —— 只靠"同名 + 差不多长"会配到翻唱。
    ///
    /// 排序：先"歌手对得上"、再"时长最接近"、最后**搜索相关性顺序**
    /// （曲库把原版排在翻唱前面；同分时按 id 挑等于掷骰子）。
    private func pickSong(
        in hits: [SongHit],
        titles: [String],
        artist: String,
        seconds: Int
    ) -> Int? {
        guard titles.contains(where: { !LyricsMatch.key($0).isEmpty }) else { return nil }
        let trackMs = seconds > 0 ? seconds * 1000 : nil

        struct Scored {
            let hit: SongHit
            let artistMatched: Bool
            let gap: Int
        }

        var scored: [Scored] = []
        for hit in hits {
            guard LyricsMatch.titlesMatch(hit.title, anyOf: titles) else { continue }
            guard LyricsMatch.lengthMatches(
                hit.durationMs > 0 ? hit.durationMs : nil,
                trackMs,
                slackMs: Self.lengthSlackSeconds * 1000
            ) else { continue }

            let artistMatched = hit.singers.contains { LyricsMatch.sameArtist($0, artist) }
            let gap = LyricsMatch.lengthGap(hit.durationMs, trackMs) ?? Int.max
            if !artistMatched, gap > Self.tightSlackSeconds * 1000 { continue }

            scored.append(Scored(hit: hit, artistMatched: artistMatched, gap: gap))
        }

        return scored.sorted { left, right in
            // 1. 歌手对得上（曲库写日文/中文、我们手上是罗马字时这一条对不上，见上面三条闸）；
            // 2. 时长最接近；
            // 3. 搜索相关性顺序 —— 曲库把原版排在翻唱前面。
            if left.artistMatched != right.artistMatched { return left.artistMatched }
            if left.gap != right.gap { return left.gap < right.gap }
            return left.hit.order < right.hit.order
        }.first?.hit.id
    }
}
