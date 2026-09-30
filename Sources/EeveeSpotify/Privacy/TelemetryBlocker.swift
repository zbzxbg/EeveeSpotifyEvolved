import Foundation

/// 上报拦截的执行、计数与「只观察不拦截」模式。
///
/// 两层，分工写死：
///   · **请求侧**（`TelemetryRequestBlock.x.swift`，挂在 `-[NSURLSessionTask resume]`）
///     —— 真正"不让它出网"的那一层，也是**唯一**计数、**唯一**打日志的地方；
///   · **响应侧**（`SpotifyResponsePatcher.shouldBlock`）—— 只做决策。
///     它被调用时 POST body 早已出网，"丢回复"不叫拦截；留着它是兜底：请求侧 hook
///     没装、或者开关是在请求飞行途中被打开的，至少别让客户端再去处理那份回复。
///
/// 这一层之所以必须存在（静态审查抓出来的）：只有响应侧的实现会把设置页那句
/// "拦截上报"变成一句空话。请求侧 `cancel()` 之后，上报请求不出网。
enum TelemetryBlocker {

    private static let lock = NSLock()

    /// 日志与计数的去重上限分开：日志是给人看的（200 条够了），计数不该在同一个
    /// 上限上冻结 —— 否则"拦了多少"会永远停在 200，越用越不准。
    private static let logCap = 200
    private static let countCap = 1000

    private static var blockedEndpoints: Set<String> = []
    private static var loggedEndpoints: Set<String> = []
    private static var blockedCount = 0

    /// 本次启动里被**取消**的上报请求数（按 host+path 去重）。
    ///
    /// 为什么去重：`resume` 会被同一条端点反复调用（每次上报一个新 task），
    /// 而且 query 里带着曲目 id / 时间戳 —— 按 `absoluteString` 计会把一个端点
    /// 算成几十个。去重后的数字才是"拦了几个端点"。
    static var sessionBlockedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return blockedCount
    }

    static func resetCounters() {
        lock.lock()
        blockedEndpoints.removeAll()
        loggedEndpoints.removeAll()
        blockedCount = 0
        lock.unlock()
    }

    /// 响应侧：只回答"这条该不该拦"，**不计不记**（计数归请求侧，免得两处各加一遍）。
    static func shouldBlock(_ url: URL) -> Bool {
        guard UserDefaults.blockTelemetry, !UserDefaults.telemetryObserveOnly else { return false }
        return isTelemetry(url)
    }

    /// 请求侧：返回 true 表示应当 `cancel()` 而不是 `resume()`。
    ///
    /// 观察模式与拦截开关是**两个独立**的模式：只观察时不拦任何东西，只记端点。
    static func shouldBlockRequest(_ url: URL) -> Bool {
        if UserDefaults.telemetryObserveOnly {
            logEndpointOnce(url, tag: "observed")
            return false
        }

        guard UserDefaults.blockTelemetry, isTelemetry(url) else { return false }

        recordBlockedOnce(url)
        return true
    }

    static func isTelemetry(_ url: URL) -> Bool {
        TelemetryEndpointRules.shouldBlock(
            url,
            extraKeywords: UserDefaults.telemetryExtraKeywords
        )
    }

    /// 去重键 = host + path（丢掉 query）。
    private static func endpointKey(_ url: URL) -> String {
        "\((url.host ?? "").lowercased())\(url.path.lowercased())"
    }

    private static func recordBlockedOnce(_ url: URL) {
        let key = endpointKey(url)

        lock.lock()
        var isNew = false
        if blockedEndpoints.count < countCap, blockedEndpoints.insert(key).inserted {
            blockedCount += 1
            isNew = true
        }
        var shouldLog = false
        if isNew, loggedEndpoints.count < logCap {
            shouldLog = loggedEndpoints.insert(key).inserted
        }
        lock.unlock()

        guard shouldLog else { return }
        writeDebugLog("[Telemetry] cancelled \(DebugLogSanitizer.logSafeURL(url))")
    }

    private static func logEndpointOnce(_ url: URL, tag: String) {
        let key = endpointKey(url)

        lock.lock()
        var isNew = false
        if loggedEndpoints.count < logCap {
            isNew = loggedEndpoints.insert(key).inserted
        }
        lock.unlock()

        guard isNew else { return }
        writeDebugLog("[Telemetry] \(tag) \(DebugLogSanitizer.logSafeURL(url))")
    }
}
