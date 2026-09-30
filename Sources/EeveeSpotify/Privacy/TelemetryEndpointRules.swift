import Foundation

/// 「上报 / 遥测」请求的判定规则（**纯函数**，不依赖 UIKit / Orion）。
///
/// 为什么单独成一个类型：
///   · `Tests/TelemetryClassification` 要能把它单独编进来跑（本机没有 Xcode /
///     Swift 工具链，测试是在有工具链的机器上一次性 `swiftc` 编译的）；
///   · 判据只能有一处 —— 设置页对用户说"拦了什么"，凭据就是这里。
///
/// 取向是**宁可漏拦，不可误拦**，顺序固定为：
///   1. 功能白名单：命中 → 一定放行（优先级最高，用户自定义关键词也压不过它）；
///   2. 已知上报主机 / 上报路径 → 拦；
///   3. 拿不准 → 不拦。
///
/// 误拦一次功能请求的表现是"播放 / 登录 / 歌词坏了"；漏拦一次上报只是少省一点流量。
/// 这两件事的代价不对等，所以规则一律向"放行"倾斜。
enum TelemetryEndpointRules {

    /// **精确**功能白名单：本仓库自己依赖的端点，命中即放行。
    ///
    /// 这些不是猜的：`color-lyrics` / `bootstrap` / `customize` 等已经是本仓库既有
    /// 链路里的关键词（见 `URL+Extension.swift` 与 `SpotifyResponsePatcher`），
    /// 误拦会直接破坏歌词替换与 Premium 修补。
    ///
    /// ⚠️ 为什么分成两档（静态审查抓到的 push-blocking 缺陷）：`lyrics` / `shuffle`
    /// 这类**宽泛**词如果也参与内置上报表的判定，`shouldBlock` 会在功能白名单这一步就
    /// 返回 false，把一批真实上报端点挡在门外 —— 开关看着打开了，其实什么都没拦。
    /// 所以这一档只放**精确**路径片段，它优先于上报表；宽泛词见下一档。
    ///
    /// 之所以连 host 一起看：`apresolve.spotify.com` 这类功能域名本身就在 host 上，
    /// 只看 path 会漏掉它。
    static let corePathTokens: [String] = [
        "color-lyrics",
        "bootstrap",
        "customize",
        "getplanoverview",
        "getpremiumplanrow",
        "getyourpremiumbadge",
        "select-ondemand-set",
        "apresolve",
        "signup/public",
        "collection/v1",
        "metadata/4",
        "context-resolve",
        "connect-state",
        "storage-resolve",
        "playlist/v2",
        "search/v2",
        "album/v1",
        "artist/v1",
        "track-playback",
    ]

    /// **宽泛**功能词：只用来管住**用户自定义关键词**，**不参与**内置上报表的判定。
    ///
    /// 手滑把 `spotify` / `auth` 写进关键词框，不该把播放、歌词、登录一起锁死 ——
    /// 这一档就是那道保险。它排在上报表**之后**判定，所以不会遮住上报端点。
    static let broadPathTokens: [String] = [
        "lyrics",
        "shuffle",
        "login",
        "auth",
        "product-state",
        "screenconfig",
    ]

    /// 明确的上报主机，**整机名匹配**（不做子域通配，免得把功能域名卷进来）。
    static let telemetryHosts: Set<String> = [
        "log.spotify.com",
    ]

    /// 上报端点的路径片段，**只在 spotify 域下生效**。
    ///
    /// 这一组不是猜的：它来自用户设备 9.1.86 的 `[Traffic]` 调试日志（19 份，
    /// 2026-09-26 ~ 09-30）里实际发出的请求：
    ///
    ///   · `.../gabo-receiver-service/v3/events`、`/public/v3/events` —— 事件上报，
    ///     响应体恒为 0 字节（纯上行，拦掉不影响任何功能）。
    ///   · `.../partner-userid/encrypted/crashlytics` —— Crashlytics 归因上行。
    ///   · `.../partner-userid/encrypted/branch` —— Branch 归因上行。
    ///
    /// `partner-userid/encrypted/onetrust` **故意不在这里**：那是 OneTrust 的同意状态，
    /// 拦掉可能影响合规流程，不属于"少省一点流量"能换的。
    static let telemetryPathTokens: [String] = [
        "/int/v1/log",
        "/v1/log/",
        "/telemetry",
        "/beacon",
        "/analytics",
        "/tracking",
        "/collect/",
        "gabo-receiver-service",
        "partner-userid/encrypted/crashlytics",
        "partner-userid/encrypted/branch",
    ]

    /// 最外层判据，四段顺序写死：
    ///   1. 精确功能白名单 → 放行（上报表与用户关键词都压不过它）；
    ///   2. 内置上报表 → 拦；
    ///   3. 宽泛功能白名单 → 放行（**只**保护功能端点不被用户关键词锁死，
    ///      不参与第 2 步的判定，所以遮不住上报端点）；
    ///   4. 用户自定义关键词 → 拦。
    static func shouldBlock(_ url: URL, extraKeywords: String) -> Bool {
        if isCoreFunctional(url) { return false }
        if isTelemetry(url) { return true }
        if isFunctional(url) { return false }
        return matchesUserKeywords(url, rawKeywords: extraKeywords)
    }

    /// 精确功能白名单：内置上报表也压不过它。
    static func isCoreFunctional(_ url: URL) -> Bool {
        contains(url, any: corePathTokens)
    }

    /// 精确 + 宽泛：用于"用户关键词不得锁死功能"那道保险。
    static func isFunctional(_ url: URL) -> Bool {
        isCoreFunctional(url) || contains(url, any: broadPathTokens)
    }

    private static func contains(_ url: URL, any tokens: [String]) -> Bool {
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()
        let haystack = "\(host)\(path)"

        return tokens.contains { haystack.contains($0) }
    }

    static func isTelemetry(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }

        // 主机规则先判：`https://log.spotify.com` 这种 path 为空（或 `/`）的 URL
        // 也必须是上报端点 —— 早期版本把 `!path.isEmpty` 放在前面，它会被漏掉。
        if telemetryHosts.contains(host) { return true }

        let path = url.path.lowercased()
        guard !path.isEmpty else { return false }

        guard host == "spotify.com" || host.hasSuffix(".spotify.com") else { return false }
        return telemetryPathTokens.contains { path.contains($0) }
    }

    /// 用户自加的关键词（主机名或路径片段，逗号 / 分号 / 空白 / 换行分隔）。
    ///
    /// 匹配对象是 `host + path`，所以 `"log.spotify.com"` 与 `"/event/v1"`
    /// 两种写法都能用。
    static func matchesUserKeywords(_ url: URL, rawKeywords: String) -> Bool {
        let keywords = parseUserKeywords(rawKeywords)
        guard !keywords.isEmpty else { return false }

        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()
        let haystack = "\(host)\(path)"

        return keywords.contains { haystack.contains($0) }
    }

    static func parseUserKeywords(_ raw: String) -> [String] {
        raw
            .split(whereSeparator: {
                $0 == "," || $0 == ";" || $0 == "\n" || $0 == " " || $0 == "\t"
            })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
}
