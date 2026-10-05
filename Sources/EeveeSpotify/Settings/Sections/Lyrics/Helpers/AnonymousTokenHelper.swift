import UIKit
import Combine

/// Musixmatch 的**匿名令牌**（无需授权即可换一个 `usertoken`）。
///
/// ## 它现在为什么要回来（2026-10-13）
///
/// 用户拍板：本仓库**不再内置** Spicy Lyrics 的默认密钥；没填密钥时这一首改用
/// **Musixmatch**（见 `CustomLyrics.loadCustomLyricsForCurrentTrack` 里那一段替换）。
/// 而 Musixmatch 自己也要 `usertoken` —— 没有匿名令牌这条路，"回退到 mxm"对绝大多数
/// 用户就是一句空话（会直接抛 `invalidMusixmatchToken`）。
///
/// 这条路 2026-09-27 被整块删过（提交 `271de5b`，当时删的理由是"设置页少一个按钮"），
/// 现在按同一个接口原样接回来，并补了两处：
///   · **app_id 三个候选**（上游后来的做法）：设备推断的那个 → 另一平台的 → `web-desktop-app-v1.0`；
///   · **同步入口**（`fetchTokenBlocking`）：取词路径是同步的，不能只留 Combine 那个 async 版本。
///
/// ## 请求形态的两条实测结论（别改）
///
/// 1. **必须带 Safari 形态的 UA**（`UIDevice.safariUserAgent`）：Musixmatch 的 nginx 会对
///    App 内 `URLSession` 的默认 UA 回 403 + 一页 nginx HTML。这一条与
///    `MusixmatchLyricsRepository` 里用的是同一个 UA，改一处就要改两处。
/// 2. host 用 `apic.musixmatch.com` —— 与 `MusixmatchLyricsRepository` 的 `apiUrl` 保持一致。
///    （上游后来换成 `apic-appmobile.musixmatch.com`，理由是 ELB 层 403；本仓库这条 host +
///    Safari UA 是真机上跑通过的那一套，先不跟着改。）
struct AnonymousTokenHelper {

    private static let apiUrl = "https://apic.musixmatch.com"

    /// 取匿名令牌用的会话：超时压到 15s —— 取词路径会**同步等**它，不能让它挂着不动。
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// app_id 的三个候选：先试设备推断出来的那个，再试另一平台的，最后是通用 web 客户端。
    private static var appIds: [String] {
        let device = UIDevice.current.musixmatchAppId
        let other = UIDevice.current.isIpad ? "mac-ios-v2.0" : "mac-ios-ipad-v1.0"
        return [device, other, "web-desktop-app-v1.0"]
    }

    // MARK: - 两个入口

    /// **同步**取一个匿名令牌。给取词路径用（那条路整条是同步的）。
    ///
    /// - Parameter totalBudget: **整轮**的时间上限（不是每个 app_id 各一份）。
    ///   取词路径那边对 Musixmatch 只有 5s 预算（`CustomLyrics` 的 `requestTimeout`），
    ///   所以自动那条路传得比 15s 小 —— 超时了也只是"这一首没赶上"，令牌下次照样会补上。
    /// - Returns: 拿到就返回；全失败返回 `nil`（调用方按"没有令牌"处理，
    ///   不要在这里抛 —— 弹不弹窗是上层的事）。
    static func fetchTokenBlocking(totalBudget: TimeInterval = 15) -> String? {
        // 整轮失败后的冷却：没网时**不能**每首歌都阻塞一轮 —— 3 个 app_id × 15s 会让
        // 每一首歌词请求都白等，日志也会刷满。
        if let last = lastFailure, Date().timeIntervalSince(last) < failureCooldown {
            let ago = Int(Date().timeIntervalSince(last))
            writeDebugLog("[Musixmatch] anonymous token: skipped (last attempt failed \(ago)s ago)")
            return nil
        }

        let deadline = Date().addingTimeInterval(totalBudget)
        for appId in appIds {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 1 else {
                writeDebugLog("[Musixmatch] anonymous token: budget exhausted before app_id=\(appId)")
                break
            }
            if let token = fetch(appId: appId, timeout: min(remaining, 15)) {
                lastFailure = nil
                writeDebugLog("[Musixmatch] anonymous token acquired (app_id=\(appId), len=\(token.count))")
                return token
            }
        }

        lastFailure = Date()
        writeErrorLog(
            "[Musixmatch] anonymous token: all app ids failed (\(appIds.joined(separator: ", ")))"
                + " — not retrying for \(Int(failureCooldown / 60)) min"
        )
        return nil
    }

    /// 上一次**整轮失败**的时间（见 `failureCooldown`）。
    ///
    /// ⚠️ 故意不加锁：它只是个"别刷屏"的时间戳，多线程下最坏情况是**多试一次**；
    /// 为它引一把锁反而要在信号量等待里持锁。
    private static var lastFailure: Date?
    private static let failureCooldown: TimeInterval = 600

    /// **异步**取一个匿名令牌。给设置页那颗按钮用（要显示转圈）。
    ///
    /// ⚠️ 只保留这一个真入口：上一版还有一个 `musixmatchTokenInputAlertPublisher`，
    /// 但**全工程没有任何地方 `send` 过它**（`EeveeLyricsSettingsView` 的 `.onReceive`
    /// 收不到东西）—— 那种死订阅不再带回来。
    static func requestAnonymousMusixmatchToken() -> AnyPublisher<String, Error> {
        Deferred {
            Future { promise in
                DispatchQueue.global(qos: .userInitiated).async {
                    if let token = fetchTokenBlocking() {
                        promise(.success(token))
                    } else {
                        promise(.failure(AnonymousTokenError.invalidResponse))
                    }
                }
            }
        }
        .eraseToAnyPublisher()
    }

    // MARK: - 一次请求

    private static func fetch(appId: String, timeout: TimeInterval) -> String? {
        guard let url = URL(string: "\(apiUrl)/ws/1.1/token.get?app_id=\(appId)") else { return nil }

        var request = URLRequest(url: url)
        // ⚠️ 见文件头：不加这个 UA，nginx 会回 403 + HTML。
        request.setValue(UIDevice.current.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout

        let semaphore = DispatchSemaphore(value: 0)
        var body: Data?
        var status = -1
        let task = session.dataTask(with: request) { data, response, _ in
            body = data
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
            semaphore.signal()
        }
        task.resume()

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            writeDebugLog("[Musixmatch] anonymous token: \(appId) timed out after \(Int(timeout))s")
            return nil
        }
        guard let data = body, let token = parseToken(from: data, appId: appId, status: status) else {
            return nil
        }
        return token
    }

    /// 解析 `token.get` 的响应；不合格就返回 `nil`（**不抛**，让调用方换下一个 app_id）。
    ///
    /// ⚠️ 名字**不叫** `token`：设置页那个 `receiveValue { token in … }` 的闭包参数同名，
    /// 而本仓库的 `swift_member_check.py` 会把它当成"跨文件引用了别处的 private `token`"
    /// 报出来（2026-10-13 实测）。名字错开，检查器与读代码的人都不用猜。
    private static func parseToken(from data: Data, appId: String, status: Int) -> String? {
        let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
        let preview = String(raw.prefix(200))

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = json["message"] as? [String: Any],
            let body = message["body"] as? [String: Any],
            let token = body["user_token"] as? String,
            !token.isEmpty,
            // 上游遇到过拿这个字符串当令牌返回的情况 —— 它不是令牌。
            token != "UpgradeRequired"
        else {
            writeErrorLog(
                "[Musixmatch] anonymous token: \(appId) http \(status), unusable response: \(preview)"
            )
            return nil
        }
        return token
    }
}

// MARK: - 「这个令牌是匿名换来的」

extension UserDefaults {
    private static let musixmatchAnonymousFlagKey = "musixmatchTokenIsAnonymous"

    /// `musixmatchToken` 里那个令牌**是不是匿名换来的**。
    ///
    /// 为什么要记：匿名令牌会过期。401 时如果是匿名的，正确做法是**丢掉它、下次重新换一个**；
    /// 而用户自己填的令牌 401 了只能提示他去换（我们不能替他重填）。
    static var musixmatchTokenIsAnonymous: Bool {
        get { container.bool(forKey: musixmatchAnonymousFlagKey) }
        set { container.set(newValue, forKey: musixmatchAnonymousFlagKey) }
    }
}
