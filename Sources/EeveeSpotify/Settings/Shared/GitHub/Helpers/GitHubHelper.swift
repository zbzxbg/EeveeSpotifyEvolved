import Foundation

/// GitHub 接口的失败原因 —— **带着状态码**。
///
/// ⚠️ 为什么单开这个类型（2026-10-02 用户报的「更新日志显示：未能读取该数据，
/// 因为它的格式不正确」）：
///   旧 `perform` **完全不看 HTTP 状态码**，把响应体直接丢给 `JSONDecoder`。
///   真机日志 28 那次 `/releases/latest` 只回了 **280 字节**（GitHub 未登录限流的
///   403 响应体；同一天同一台机器连续请求，出口 IP 是运营商 NAT、额度是很多人共用的），
///   于是错误 JSON 被当成 release 解 → `DecodingError.keyNotFound("tagName")` →
///   界面上就变成"格式不正确"这句**误导人**的话。
///   现在：状态码先过闸，界面按**真实原因**说话（`EeveeUpdatesSettingsView`），
///   日志里连状态码和响应体开头一起打出来 —— 下一份日志一眼就能定案。
enum GitHubAPIError: Error {
    /// 限流。GitHub 未登录是 **60 次/小时，按出口 IP 算**。
    /// `reset` 是 `X-RateLimit-Reset` / `Retry-After` 给的恢复时刻（拿不到就是 nil）。
    case rateLimited(reset: Date?)
    /// 404：仓库或路径不存在。
    ///
    /// ★ 2026-10-11 更正（查"这条文案还用得到吗"时发现的）：
    ///   · `/releases/latest` 在"本仓库还没有 tag 化 release"时**确实**回 404 ——
    ///     `getLatestRelease` 那条注释说的是对的，别改；
    ///   · 但**列表**接口（`getReleases` → `/repos/<slug>/releases?per_page=30`）在同样情况下
    ///     回的是 **200 + `[]`**，只有仓库**不存在 / 改名 / 转私有**时才 404。
    /// ⇒ 这一支现在的含义就是"**仓库找不到了**"，界面文案（`updates_error_not_found`）
    ///   已按这个真相改写（原来是"还没有 release，预期内无害"，对不上唯一能走到这里的场景）。
    case notFound
    /// 其它非 2xx（会把状态码原样带出来，方便日志与界面区分）。
    case httpStatus(Int)
    /// 网络层失败（超时、断网、DNS）。
    case transport(String)
    /// 2xx 但解不出来（真·格式问题）。
    case decoding(String)
}

/// GitHub 只读接口。
///
/// ── 2026-10-02 两处修正（都与「更新日志」那次故障有关）────────────────────────
///   ① **仓库 slug 不再写死**：用构建期生成的 `EeveeSpotify.repoSlug`
///      （`Makefile` 从 `git remote get-url origin` 生成）。以前这里写死
///      `zbzxbg/EeveeSpotify-ng-latest`，而那个名字已经改成 `zbzxbg/EeveeSpotifyEvolved`
///      —— GitHub 对改名仓库会 302，于是"看起来还能用"，可一旦重定向没了（或换 owner）
///      两个接口会一起静默失效；而且**改名后的名字才是用户看到的那个**。
///   ② **条件请求 + 短缓存**：`ETag` / `If-None-Match`，GitHub 对 **304 不计算额度**
///      （官方规则），再加上 5 分钟新鲜窗口 —— 反复进出「更新日志」不再白烧那 60 次。
final class GitHubHelper {
    private let apiUrl = "https://api.github.com"
    private let decoder = JSONDecoder()

    static let shared = GitHubHelper()

    /// 本仓库 slug（构建期从 git remote 生成；`Makefile` 里那个兜底值也是它）。
    private var repoSlug: String { EeveeSpotify.repoSlug }

    init() {
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    // MARK: - 缓存 / 条件请求

    /// 一次请求的结果。`etag` 用来发条件请求（304 不计额度）。
    private struct Entry {
        var data: Data
        var etag: String?
        var at: Date
    }

    private let lock = NSLock()
    private var cache: [String: Entry] = [:]

    /// 新鲜窗口：这段时间内直接用缓存，一个网络请求都不发。
    /// 5 分钟是"更新日志不要求秒级新鲜"与"少烧额度"之间的折中（版本检查同理）。
    private let freshInterval: TimeInterval = 300

    private func cachedEntry(_ path: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return cache[path]
    }

    private func store(_ entry: Entry, for path: String) {
        lock.lock()
        cache[path] = entry
        lock.unlock()
    }

    // MARK: - 请求

    private func perform(_ path: String) async throws -> Data {
        if let entry = cachedEntry(path), Date().timeIntervalSince(entry.at) < freshInterval {
            writeDebugLog("[GitHub] \(path) → using the cache (\(entry.data.count) bytes, no request sent this time)")
            return entry.data
        }

        var request = URLRequest(url: URL(string: "\(apiUrl)\(path)")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(
            "EeveeSpotify v\(EeveeSpotify.version) https://github.com/\(repoSlug)",
            forHTTPHeaderField: "User-Agent"
        )
        if let etag = cachedEntry(path)?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        writeDebugLog("[GitHub] GET \(path)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            writeDebugLog("[GitHub] ⚠️ \(path) transport failure: \(error.localizedDescription)")
            throw GitHubAPIError.transport(error.localizedDescription)
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1

        // 304：缓存还有效，**这一次不烧额度**（GitHub 官方规则）。
        if status == 304, let entry = cachedEntry(path) {
            store(Entry(data: entry.data, etag: entry.etag, at: Date()), for: path)
            writeDebugLog("[GitHub] \(path) → 304 (cache still valid, no quota used)")
            return entry.data
        }

        guard (200...299).contains(status) else {
            // ★ 这里以前**什么都不做**：错误体被当成正常数据往下走，于是限流 / 404
            //   全都被 `JSONDecoder` 报成"格式不正确"。状态码 + 响应体开头都写进日志。
            writeDebugLog(
                "[GitHub] ⚠️ \(path) → HTTP \(status)（\(data.count) bytes）\(Self.excerpt(data))"
            )
            throw Self.error(status: status, response: http)
        }

        store(
            Entry(data: data, etag: http?.value(forHTTPHeaderField: "ETag"), at: Date()),
            for: path
        )
        writeDebugLog("[GitHub] \(path) -> \(data.count) bytes")
        return data
    }

    /// 状态码 → 失败原因。403/429 一律按**限流**处理（对公开仓库的只读请求来说，
    /// GitHub 的 403 实质就是限流；真出别的 403，日志里的响应体开头会说明）。
    private static func error(status: Int, response: HTTPURLResponse?) -> GitHubAPIError {
        switch status {
        case 404:
            return .notFound
        case 403, 429:
            return .rateLimited(reset: resetDate(from: response))
        default:
            return .httpStatus(status)
        }
    }

    /// 额度恢复时刻：先看 `Retry-After`（次限流），再看 `X-RateLimit-Reset`（主限流，Unix 秒）。
    private static func resetDate(from response: HTTPURLResponse?) -> Date? {
        if let raw = response?.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(raw) {
            return Date().addingTimeInterval(seconds)
        }
        if let raw = response?.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let seconds = TimeInterval(raw) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    /// 日志用：响应体开头一小段（单行），够看清 `"message":"API rate limit exceeded…"`。
    private static func excerpt(_ data: Data) -> String {
        let text = String(data: data.prefix(160), encoding: .utf8) ?? "<not UTF-8, \(data.count) bytes>"
        return text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            writeDebugLog("[GitHub] ⚠️ \(path) decode failed: \(error)")
            throw GitHubAPIError.decoding(error.localizedDescription)
        }
    }

    // MARK: - 接口

    /// 版本检查的数据源。仓库 slug 来自构建期生成的 `EeveeSpotify.repoSlug`
    /// （`Makefile`：`git remote get-url origin` → `GeneratedConfig.repoSlug`）。
    ///
    /// ⚠️ 本仓库若没有 tag 化的 release，这里会 404 —— 那是**预期内**的：
    /// `EeveeSettingsVersionView.loadVersion()` 会把失败当成"没有新版本"，
    /// 界面只是不提示更新，不会卡在转圈上（见那里的 15 秒超时与兜底）。
    func getLatestRelease() async throws -> GitHubRelease {
        let path = "/repos/\(repoSlug)/releases/latest"
        return try decode(GitHubRelease.self, from: try await perform(path), path: path)
    }

    /// 「更新日志」页用：最近 30 个 release（含正文）。
    ///
    /// 与版本检查**同一个仓库、同一个 decoder**（`convertFromSnakeCase` → `tagName` /
    /// `htmlUrl` / `publishedAt` 这些都能对上）。没有 release 时返回空数组而不是抛错。
    func getReleases() async throws -> [GitHubRelease] {
        let path = "/repos/\(repoSlug)/releases?per_page=30"
        return try decode([GitHubRelease].self, from: try await perform(path), path: path)
    }

    func getUser(_ username: String) async throws -> GitHubUser {
        let path = "/users/\(username)"
        return try decode(GitHubUser.self, from: try await perform(path), path: path)
    }

    func getContributors() async throws -> [GitHubUser] {
        let path = "/repos/\(repoSlug)/contributors"
        return try decode([GitHubUser].self, from: try await perform(path), path: path)
    }

    /// 贡献者分区：走 `raw.githubusercontent.com`（**不占 API 额度**），所以不经 `perform`。
    func getEeveeContributorSections() async throws -> [EeveeContributorSection] {
        let path = "https://raw.githubusercontent.com/\(repoSlug)/refs/heads/\(GeneratedConfig.branchName)/contributors.json"
        let (data, _) = try await URLSession.shared.data(from: URL(string: path)!)
        return try decode([EeveeContributorSection].self, from: data, path: path)
    }
}
