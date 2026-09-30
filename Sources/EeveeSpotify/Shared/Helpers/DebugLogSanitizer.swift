import Foundation

/// 日志脱敏（2026-09-30 新增）。
///
/// ── 两层，职责不同 ─────────────────────────────────────────────────────────
///
/// ① `sanitize(_:)` —— **写入口**，进程内永远生效（`writeDebugLog` / `writeErrorLog`
///    与 `eeveeSanitizedNSLog` 都会过一遍）。管的是"无论如何都不该落盘"的东西：
///    凭证、账号/设备标识、已知的用户内容 query 参数。
///
/// ② `redactForSharing(_:)` —— **只在导出时**应用，给"要发到 issue / 给别人看"的那一份。
///    管的是"日志主体本身就是用户数据"的那一类：曲目/艺人/专辑 URI、曲名、曲目 id。
///    本地那份文件不受影响 —— 排查时你仍然需要真实曲目才能复现。
///
/// ── 为什么脱敏必须放在写入口 ───────────────────────────────────────────────
/// `writeDebugLog` 同时写文件和 `os_log(privacy: .public)`；而系统统一日志**清不掉**
/// （设置里的「清除调试日志」只清 App 容器里那份）。只在导出时脱敏的话，
/// 系统日志里那份仍然是明文。
///
/// ── 判据（来自真机日志审计，含 19 号日志）──────────────────────────────────
/// · **必隐**：Bearer/Authorization/Cookie 类凭证、设备唯一标识、账号标识；
/// · **默认隐**：播放上下文/歌单、曲目与艺人、曲名、时区与地区；
/// · **必须保留**：时间戳、接口 path、元素清单与 hex dump 这类排查判据本身。
///   所以本文件里**没有**任何"把 query 里所有参数一锅端"的规则 —— 只处理已知的
///   用户内容参数，且 `[TokenCapture]` 那类整条 URL 由调用方改用 `logSafeURL(_:)`
///   （只留 scheme+host+path）在源头掐掉。
enum DebugLogSanitizer {

    // MARK: - ① 写入口：硬脱敏

    /// `key=value` 形式的凭证键名。顺序无所谓（正则回溯会自己找到能匹配完整键的那一支）。
    private static let secretKeyAlternation = [
        "authorization", "cookie", "set-cookie", "set_cookie",
        "access_token", "refresh_token", "id_token",
        "csrf_token", "csrf", "__csrf",
        "sp_dc", "sp_t", "sp_key", "password", "usertoken",
        "userid", "user_id", "deviceid", "device_id", "session_id",
    ].joined(separator: "|")

    /// 规则表：(正则, 替换模板)。
    ///
    /// **顺序有意义** —— 先摘 `Bearer <token>`，再谈 `key=value`；
    /// 否则 `Authorization=Bearer xxx` 里的 `Bearer` 会先被当成一个普通值打掉。
    ///
    /// 为什么预编译 + 模板（而不是每行现编正则、每个匹配走闭包）：`writeDebugLog`
    /// 跑在 URLSession delegate 回调这类**热路径**上，每写一行现编 6 个 `NSRegularExpression`
    /// 纯属浪费。模板里的 `$1`/`$3` 都是普通捕获组引用，字面量里没有 `$` 也没有 `\`。
    private static let rawSanitizeRules: [(pattern: String, template: String)] = [
        // 1. `Bearer <token>`——只吃掉 token 本身，保留 "Bearer " 供读日志时辨认。
        ("(?i)(\\bbearer\\s+)[A-Za-z0-9._~+/=-]+", "$1<redacted>"),

        // 2. `key=value`（URL query、表单体、`Set-Cookie: sp_dc=…` 都归这条）。
        ("(?i)((?:\(secretKeyAlternation))\\s*=\\s*)[^&\\s,;|]+", "$1<redacted>"),

        // 2b. header 整行形态：`Cookie: …` / `Set-Cookie: …` / `Authorization: …`。
        //     只靠第 2 条会漏 —— 那条要求 cookie **名字**在名单里，
        //     而 `Set-Cookie: <别的名字>=…` 一样是凭证。这两条直接吃掉整行剩余内容。
        ("(?i)((?:set-)?cookie\\s*[:=]\\s*)[^\\n]*", "$1<redacted>"),
        ("(?i)(authorization\\s*[:=]\\s*)[^\\n]*", "$1<redacted>"),

        // 3. JSON 形式 `"key":"value"` —— SponsorBlock 的 `"userID":"…"` 走这条。
        (
            "(?i)(\"(?:userid|user_id|authorization|cookie|access_token|refresh_token|id_token|deviceid|device_id)\"\\s*:\\s*\")([^\"]*)(\")",
            "$1<redacted>$3"
        ),

        // 4. 设备唯一标识：`/social-connect/v2/devices/<32hex>/jam_status`。
        //    换成**固定占位**而不是哈希 —— 一份日志里只可能有一台设备，
        //    而固定占位保证了**跨日志不可关联**，正是我们要的。
        ("(?i)(/devices/)[A-Za-z0-9._-]{6,}", "$1<device>"),

        // 5. 账号标识（用户名那条路径）。
        ("(?i)(spotify:user:)[A-Za-z0-9._-]+", "$1<redacted>"),

        // 6. 已知的用户内容 query 参数。**兜底**用：正常路径上 URL 已经在调用方
        //    经 `logSafeURL(_:)` 掐掉了 query，这条只防"某天有人又打了一条整 URL"。
        //    `region` 刻意**不在**名单里 —— "日区还是别的区"是有用的排查判据。
        (
            "(?i)([?&](?:play_context_uri|contexturi|creatoruri|entityuri|entity_uri|signal|eagerload|timezone|locale|userid|usertoken|csrf_token|access_token)=)[^&\\s]*",
            "$1<redacted>"
        ),
    ]

    /// 预编译结果。`static let` 由 Swift 保证只初始化一次（`dispatch_once` 语义），
    /// 所以并发读安全，不需要额外的锁。
    private static let sanitizeRules: [(regex: NSRegularExpression, template: String)] =
        rawSanitizeRules.compactMap { rule in
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { return nil }
            return (regex: regex, template: rule.template)
        }

    /// 硬脱敏。**必须幂等**（`sanitize(sanitize(x)) == sanitize(x)`）——
    /// 因为同一行可能既过 `writeErrorLog` 的 `[ERROR]` 前缀，也过导出时的二次处理。
    static func sanitize(_ message: String) -> String {
        var out = message

        for rule in sanitizeRules {
            let ns = out as NSString
            out = rule.regex.stringByReplacingMatches(
                in: out,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: rule.template
            )
        }

        return out
    }

    /// URL → `scheme://host/path`（**丢掉整个 query**）。
    ///
    /// 为什么在源头丢而不是靠 `sanitize` 兜：7 类敏感点里有 4 类（播放上下文/歌单、
    /// 曲目与艺人 URI、时区与地区、以及 `eagerload` 那种几百字节的 base64 上下文）
    /// **只出现在 query 里**；而 path 才是排查真正要看的东西（"客户端有没有发那一枪"）。
    /// 19 号日志里 73 条 `[TokenCapture]` 各自带着一整个 query，全靠这一处收敛。
    static func logSafeURL(_ url: URL?) -> String {
        guard let url else { return "<no url>" }
        let scheme = url.scheme ?? "?"
        let host = url.host ?? "?"
        return sanitize("\(scheme)://\(host)\(url.path)")
    }

    /// 同上，但入参是字符串（有些调用点只有已经拼好的 URL 串）。
    static func logSafeURLString(_ raw: String) -> String {
        guard let url = URL(string: raw) else { return sanitize(raw) }
        return logSafeURL(url)
    }

    // MARK: - ② 导出：内容假名化

    /// 导出用的假名前缀。分门别类，读日志时一眼看得出是哪一类对象。
    private static let aliasPrefixes: [String: String] = [
        "track": "t", "artist": "ar", "album": "al", "episode": "ep",
        "show": "sh", "playlist": "pl", "concert": "co", "user": "us",
    ]

    /// 导出时把"日志主体里的用户数据"假名化。
    ///
    /// ⚠️ 两个刻意的设计：
    /// 1. **同一份日志内保持可关联** —— 同一个 id 每次都映射到同一个假名（`t1`、`t2`…），
    ///    否则"`[Scrollsita] manifest track=t1` 与 `injected … track=t1` 是不是同一首"
    ///    这种判读就废了；
    /// 2. **`spotify:section:` 一律不动** —— 元素类型/版块号（`…Gq21` = 歌词卡片那一项、
    ///    `…Gq1L` = 关于艺人）是排查元素清单的**唯一判据**，见 `ScrollsitaLyricsElementInjector`。
    static func redactForSharing(_ text: String) -> String {
        var aliases: [String: String] = [:]
        var counters: [String: Int] = [:]

        func alias(_ value: String, _ kind: String) -> String {
            if let existing = aliases[value] { return existing }
            let prefix = aliasPrefixes[kind] ?? "x"
            let next = (counters[prefix] ?? 0) + 1
            counters[prefix] = next
            let made = "\(prefix)\(next)"
            aliases[value] = made
            return made
        }

        var out = text

        // 1. `spotify:<kind>:<id>`（section 由正则本身排除在外）。
        out = replacing(
            out,
            pattern: "spotify:(track|artist|album|episode|show|playlist|concert|user):([A-Za-z0-9]+)"
        ) { match, ns in
            let kind = ns.substring(with: match.range(at: 1))
            let id = ns.substring(with: match.range(at: 2))
            let key = "\(kind):\(id)"
            return "spotify:\(kind):\(alias(key, kind))"
        }

        // 1b. 同一批 id 出现在**路径**里（`/track/2Fkz…`）——真实日志里到处都是
        //     （`[NPVModule] … path=/merch-npv-service/v1/merch/track/<id>`、
        //      `[HasLyricsProbe] seen path=/color-lyrics/v2/track/<id>`）。
        //     必须和 `spotify:track:<id>` 映射到**同一个**假名，否则"这行说的和上一行是不是同一首"就对不上了。
        //     `{10,}` 是为了避开 `/track/search` 这类非 id 段。
        out = replacing(
            out,
            pattern: "(?i)/(track|album|artist|episode|show|playlist|concert)/([A-Za-z0-9]{10,})"
        ) { match, ns in
            let kind = ns.substring(with: match.range(at: 1)).lowercased()
            let id = ns.substring(with: match.range(at: 2))
            let key = "\(kind):\(id)"
            return "/\(kind)/\(alias(key, kind))"
        }

        // 2. 曲名：把 `… for "标题"` / `… fetching "标题"` / `… Using "标题"` 里的引号串换成标记。
        //    只吃引号内那一小段，不吃行尾 —— 行尾带着"行数 / provider"这类判据。
        //    `using` 只会命中 `[Genius] Using "…"`（`[Lyrics] Using original colors`
        //    与 `[Musixmatch] using macro matcher …` 都没有引号）。
        out = replacing(
            out,
            pattern: "(?i)((?:lyrics for|fetching|using|malformed for|no such song for)\\s+)\"[^\"]*\""
        ) { match, ns in
            ns.substring(with: match.range(at: 1)) + "\"<title>\""
        }

        // 3. 艺人：**依赖第 2 步留下的 `<title>` 标记**，所以只会命中已经处理过的行，
        //    不会误伤别处的 `- xxx`。
        out = replacing(out, pattern: "(\"<title>\"\\s+-\\s+)[^\\n(]*") { match, ns in
            ns.substring(with: match.range(at: 1)) + "<artist>"
        }

        // 4. `[NetEase] Chosen[0]: 短夜の星 (id 2044457637)`
        out = replacing(out, pattern: "(?i)(chosen\\[\\d+\\]:\\s*)[^\\n]*?\\(id\\s*\\d+\\)") { match, ns in
            ns.substring(with: match.range(at: 1)) + "<title> (id <redacted>)"
        }
        // 4b. 其余 `(id 123)` 兜底。
        out = replacing(out, pattern: "(?i)\\(id\\s*\\d+\\)") { _, _ in "(id <redacted>)" }

        // 5. `album_id 00C345qa1C9et1uiN0yP1I` / `track_id=2094728852`（两种写法都要覆盖：
        //    `[NPVModule]` 用空格，`[Musixmatch] macro matcher.track.get` 用等号）。
        out = replacing(out, pattern: "(?i)((?:album|track)_id[=:\\s]+)[A-Za-z0-9]+") { match, ns in
            ns.substring(with: match.range(at: 1)) + "<id>"
        }

        // 6. 封面 URL 里的图 hash 是曲目的强指纹；`[Artwork] fetching … for <id>` 同理。
        out = replacing(out, pattern: "(?i)(https://i\\.scdn\\.co/image/)[A-Za-z0-9]+") { match, ns in
            ns.substring(with: match.range(at: 1)) + "<artwork>"
        }
        // 6b. `[Artwork] fetching <url> for <id>` 与 `[Artwork] cache hit for <id>` —— 两种
        //     写法都用 `… for <id>` 结尾，所以一条规则覆盖（`metadata keys:` 那行没有 ` for `）。
        out = replacing(out, pattern: "(?i)(\\[Artwork\\][^\\n]*?\\bfor\\s+)[A-Za-z0-9]{10,}") { match, ns in
            ns.substring(with: match.range(at: 1)) + "<id>"
        }

        // 7. `[AMLL] … (spotifyId 2e1gUS6Wv8GS8ZT6FMeE1J)`
        out = replacing(out, pattern: "(?i)(spotifyid\\s+)[A-Za-z0-9]+") { match, ns in
            ns.substring(with: match.range(at: 1)) + "<id>"
        }

        // 7b. SponsorBlock 投稿/投票里的 `"videoID":"<episode id>"` 与 `"UUID":"<segment id>"`。
        //     它们是**内容 id**（能反查你投的是哪一集/哪一段），不是凭证，所以归导出层。
        out = replacing(
            out,
            pattern: "(?i)(\"(?:videoID|UUID)\"\\s*:\\s*\")[^\"]*(\")"
        ) { match, ns in
            ns.substring(with: match.range(at: 1)) + "<id>" + ns.substring(with: match.range(at: 2))
        }

        // 8. 各仓库把曲名/艺人放在 query 里明文的那些参数。
        //    · Musixmatch：`?q_track=独白&q_artist=DUSTCELL…`（那条 log 刻意保留其余 query，
        //      以便和"Safari 能过"的 URL 逐字对比，所以这里只按参数名打掉这几项）；
        //    · LRCLIB：`?track_name=…&artist_name=…`；
        //    · Genius：`?q=…`。
        out = replacing(
            out,
            pattern: "(?i)([?&](?:q_track|q_artist|q_album|track_name|artist_name|album_name|q)=)[^&\\s]*"
        ) { match, ns in
            ns.substring(with: match.range(at: 1)) + "<redacted>"
        }

        // 9. 整行的"原始响应体片段"：这些行**本身就是抓来的服务端内容**，
        //    可能含曲名/艺人/歌词，靠模式匹配清不干净 —— 分享版里整段打掉。
        //    只动 `…: ` 后面的内容，时间戳与标签（判读"这一枪有没有打"）都留着。
        out = replacing(
            out,
            pattern: "(?i)((?:raw XML head|raw head|richsync body head|body head):\\s*)[^\\n]*"
        ) { match, ns in
            ns.substring(with: match.range(at: 1)) + "<redacted>"
        }
        // 9b. `body: {…}` / `body={"…"}` 这种**响应体片段**（`[SB][submit] -> 200 body=…`、
        //     `[Musixmatch] … body: …`）。⚠️ 必须用负向先行断言躲开 `body=584B` ——
        //     `[Scrollsita] manifest track=… body=584B has5=false elements=[…]` 那行的
        //     `body=` 是**字节数**，而它后面正是整份日志里最有价值的元素清单，
        //     被这条规则整行吞掉就等于把排查判据删了。
        out = replacing(out, pattern: "(?i)(\\bbody[:=]\\s*)(?!\\d+B\\b)[^\\n]*") { match, ns in
            ns.substring(with: match.range(at: 1)) + "<redacted>"
        }

        // 9c. 同族的 `printable=<…>`（`[NPVModule] … printable=… | …`、`[ScrollProbe] … printable=…`）：
        //     它是探针从响应体里捞出来的可打印串，里面是**裸的**艺人名 / 场馆 / 城市
        //     （`… | 2026-11-07T18:00:00+0900 | esoragoto`）—— 模式匹配盖不住，整段打掉。
        out = replacing(out, pattern: "(?i)(\\bprintable=)[^\\n]*") { match, ns in
            ns.substring(with: match.range(at: 1)) + "<redacted>"
        }

        // 10. **hex dump**：`[ScrollProbe] … hex512B=<hex>` 里那些字节是可以**解码还原**的
        //     （`73706f746966793a747261636b3a` = `spotify:track:`），模式匹配看不见，
        //     所以只能整段打掉。两种形态：
        //       · `hex512B=<hex>`（ScrollProbe）
        //       · `[NPVModule] hex path=… 256B=<hex>`
        //     这两个探针在**本地**文件里原样保留，分享版里退化成 `<hex-redacted>`。
        out = replacing(out, pattern: "(?i)(\\bhex[0-9a-f]*B=)[0-9a-f]{16,}") { match, ns in
            ns.substring(with: match.range(at: 1)) + "<hex-redacted>"
        }
        out = replacing(out, pattern: "(?i)(\\[NPVModule\\] hex [^\\n]*?=\\s*)[0-9a-f]{16,}") { match, ns in
            ns.substring(with: match.range(at: 1)) + "<hex-redacted>"
        }

        return out
    }

    // MARK: - 导出文件

    /// 生成"可分享的那一份"。
    ///
    /// `redact == false` 时原样返回原文件（自己留档）。脱敏版写到
    /// `eeveespotify_debug_shared.log`，**不动**原文件 —— 排查要用的真实曲目
    /// 仍然留在 `eeveespotify_debug.log` 里。
    static func sharedLogFile(from path: String, redact: Bool) -> URL? {
        let original = URL(fileURLWithPath: path)
        guard redact else { return original }

        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }

        let outputPath = NSTemporaryDirectory() + "eeveespotify_debug_shared.log"
        let redacted = redactForSharing(raw)
        guard (try? redacted.write(toFile: outputPath, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        return URL(fileURLWithPath: outputPath)
    }

    // MARK: - 内部：按正则逐段重建字符串

    /// 用闭包替换所有匹配（`NSRegularExpression` 的模板替换没法做"同一个值映射到同一个假名"
    /// 这种带状态的事，所以自己走一遍）。
    ///
    /// 全程用 `NSString` 下标：`NSRegularExpression` 给的是 UTF-16 range，
    /// 与 `String.Index` 混用会在含中文/CJK 的行上错位（本仓库日志里到处都是日文曲名）。
    private static func replacing(
        _ input: String,
        pattern: String,
        _ transform: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return input }

        let ns = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }

        var out = ""
        out.reserveCapacity(input.count)
        var cursor = 0

        for match in matches {
            let range = match.range
            guard range.location >= cursor, NSMaxRange(range) <= ns.length else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            out += transform(match, ns)
            cursor = NSMaxRange(range)
        }

        out += ns.substring(from: cursor)
        return out
    }
}

/// 把 Bearer token 映射成**轮换序号**（`token#1` / `token#2` …）。
///
/// 为什么还要留点什么：真机验证时"token 有没有换过"本身就是判据 —— 19 号日志里
/// 一次会话中就出现过两枚。但 token 的任何片段都没有调试价值，
/// 所以原先的 `prefix=<前6字符>` 换成只记"第几枚"。
enum SpotifyTokenOrdinal {
    private static let lock = NSLock()
    private static var order: [String] = []
    /// 一次会话里正常也就一两枚；上限只是防止异常情况下无限持有 token 串。
    private static let limit = 8

    static func label(for token: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        if let index = order.firstIndex(of: token) {
            return "token#\(index + 1)"
        }
        guard order.count < limit else { return "token#\(limit)+" }
        order.append(token)
        return "token#\(order.count)"
    }
}
