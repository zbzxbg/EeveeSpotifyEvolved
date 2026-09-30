import Foundation

/// 上报拦截的执行、计数与「只观察不拦截」模式。
///
/// 两层，分工写死：
///   · **请求侧**（`TelemetryRequestBlock.x.swift`，挂在 `-[NSURLSessionTask resume]`）
///     —— 真正"不让它出网"的那一层，也是**唯一**计数、**唯一**打日志的地方；
///   · **响应侧**（`SpotifyResponsePatcher.shouldBlock`）—— 只做决策。
///     它被调用时 POST body 早已出网，"丢回复"不叫拦截；留着它是兜底：请求侧 hook
///     拿不到 URL（极少数 task）、或者开关是在请求飞行途中被打开的，至少别让客户端
///     再去处理那份回复。
///
/// 这一层之所以必须存在（静态审查抓出来的）：只有响应侧的实现会把设置页那句
/// "拦截上报"变成一句空话。
enum TelemetryBlocker {

    private static let lock = NSLock()

    /// 两份日志的去重集合**必须分开**（静态审查抓到的质量缺陷）：观察模式的
    /// 工作流是"先开只观察、抄端点、再开拦截"，如果两份日志共用一个集合，
    /// 一个已经以 `observed` 记过的端点就再也不会以 `cancelled` 出现，
    /// 用户按日志核对时会以为拦截没生效。
    private static let logCap = 200
    private static var loggedObserved: Set<String> = []
    private static var loggedCancelled: Set<String> = []

    /// 取消次数：**不去重、不封顶**。
    ///
    /// 设置页那行写的就是"已取消的上报请求"，计数与文案必须一致；早前把去重集合的
    /// 上限同时当计数上限，结果是计数在 1000 处静默冻结。
    private static var cancelledCount = 0

    /// 本次启动以来被**取消**的上报请求次数。
    static var sessionBlockedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cancelledCount
    }

    static func resetCounters() {
        lock.lock()
        loggedObserved.removeAll()
        loggedCancelled.removeAll()
        cancelledCount = 0
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

        recordCancelled(url)
        return true
    }

    static func isTelemetry(_ url: URL) -> Bool {
        TelemetryEndpointRules.shouldBlock(
            url,
            extraKeywords: UserDefaults.telemetryExtraKeywords
        )
    }

    /// 去重键 = host + path（丢掉 query）：query 里带曲目 id / 时间戳，
    /// 用 `absoluteString` 会让同一个端点每首歌都算一条新记录。
    private static func endpointKey(_ url: URL) -> String {
        "\((url.host ?? "").lowercased())\(url.path.lowercased())"
    }

    private static func recordCancelled(_ url: URL) {
        lock.lock()
        cancelledCount += 1

        var shouldLog = false
        if loggedCancelled.count < logCap {
            shouldLog = loggedCancelled.insert(endpointKey(url)).inserted
        }
        lock.unlock()

        guard shouldLog else { return }
        writeDebugLog("[Telemetry] cancelled \(DebugLogSanitizer.logSafeURL(url))")
    }

    private static func logEndpointOnce(_ url: URL, tag: String) {
        lock.lock()
        var isNew = false
        if loggedObserved.count < logCap {
            isNew = loggedObserved.insert(endpointKey(url)).inserted
        }
        lock.unlock()

        guard isNew else { return }
        writeDebugLog("[Telemetry] \(tag) \(DebugLogSanitizer.logSafeURL(url))")
    }
}
