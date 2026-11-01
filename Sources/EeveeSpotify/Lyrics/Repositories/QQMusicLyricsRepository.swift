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
    private static let lyricKey = "music.musichallSong.PlayLyricInfo.GetPlayLyricInfo"

    /// QQ 的 `interval` 是整秒，比别的源粗；6 秒容差是 Taurus 用的值。
    private static let lengthSlackSeconds = 6

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
        let searchBody: [String: Any] = [
            "comm": ["ct": "19", "cv": "1859", "uin": "0"],
            "req": [
                "module": "music.search.SearchCgiService",
                "method": "DoSearchForQQMusicDesktop",
                "param": [
                    "query": "\(title) \(lead)",
                    "search_type": 0,
                    "grp": 1,
                    "num_per_page": 8,
                    "page_num": 1
                ]
            ]
        ]

        guard let searchRoot = LyricsSourceHTTP.postJSON(
            url, body: searchBody, headers: Self.headers, tag: "QQMusic"
        ) else {
            throw LyricsError.noSuchSong
        }

        let list = LyricsSourceHTTP.dig(searchRoot, ["req", "data", "body", "song", "list"]) as? [Any]
        guard let songId = pickSong(in: list ?? [], title: title, artist: lead, seconds: seconds) else {
            writeDebugLog(
                "[QQMusic] \"\(title)\" — \(lead): no candidate matched the length"
                    + " (slack \(Self.lengthSlackSeconds)s)"
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
                // `interval` 是**秒**，其余几个 `*_t` 是"要不要翻译/罗马音"的开关，这里全关。
                "param": [
                    "albumName": Self.base64(query.albumTitle ?? ""),
                    "crypt": 1,
                    "ct": 19,
                    "cv": 2111,
                    "interval": seconds,
                    "lrc_t": 0,
                    "qrc": 1,
                    "qrc_t": 0,
                    "roma": 0,
                    "roma_t": 0,
                    "singerName": Self.base64(lead),
                    "songID": songId,
                    "songName": Self.base64(title),
                    "trans": 0,
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

        // `qrc_t != 0` 表示 `lyric` 里是**加密的逐字 QRC**；等于 0 才是 base64 的明文 LRC。
        // 两个字段都可能是数字也可能是字符串（不同接口版本不一致），统一按 int 读。
        let qrcType = Self.intValue(payload?["qrc_t"])
        if qrcType != 0, !encoded.isEmpty {
            if let dto = QrcText.dto(fromEncrypted: encoded) {
                writeDebugLog(
                    "[QQMusic] song \(songId): \(dto.lines.count) word-timed line(s) from QRC"
                )
                return Self.attachingOfficialRomaji(to: dto, payload: romaPayload, type: romaType)
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
        return Self.attachingOfficialRomaji(to: dto, payload: romaPayload, type: romaType)
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
    /// 按最近的起点匹配，容差 100ms。逐毫秒扫是因为差值是 1 这种，不能用固定步长。
    private static func nearby(_ start: Int, in map: [Int: String]) -> String? {
        for delta in 1...100 {
            if let hit = map[start + delta] { return hit }
            if let hit = map[start - delta] { return hit }
        }
        return nil
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

    /// 第一条"就是这首歌"的录音。
    ///
    /// 与 Taurus 同一条判据：**标题去掉标点后必须完全相等**（不接受包含），
    /// 歌手用互相包含，时长在容差内。标题用相等而不是包含，是因为
    /// "`晴天` 与 `晴天 (Live)` 去掉标点后是 `晴天` 与 `晴天live`"——
    /// 用包含会把 Live 版放进来，而那正是最常配错的一类。
    private func pickSong(
        in list: [Any],
        title: String,
        artist: String,
        seconds: Int
    ) -> Int? {
        let wanted = LyricsMatch.key(title)
        guard !wanted.isEmpty else { return nil }

        for item in list {
            guard let song = item as? [String: Any] else { continue }

            let name = (song["title"] as? String) ?? (song["songname"] as? String) ?? ""
            guard LyricsMatch.key(name) == wanted else { continue }

            let length = (song["interval"] as? NSNumber)?.intValue ?? 0
            guard LyricsMatch.lengthMatches(
                length > 0 ? length * 1000 : nil,
                seconds > 0 ? seconds * 1000 : nil,
                slackMs: Self.lengthSlackSeconds * 1000
            ) else { continue }

            let singers = (song["singer"] as? [Any]) ?? []
            let sung = singers.contains { entry in
                guard let singer = entry as? [String: Any] else { return false }
                return LyricsMatch.sameArtist(singer["name"] as? String, artist)
            }
            guard sung else { continue }

            if let id = (song["id"] as? NSNumber)?.intValue { return id }
        }

        return nil
    }
}
