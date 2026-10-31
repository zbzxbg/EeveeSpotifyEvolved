import Foundation

/// 新加的几个歌词源共用的一层薄 HTTP。
///
/// 为什么单独抽：BiniLyrics / Unison / QQ 音乐 / 酷狗 每个都要 2 个请求（搜索 + 取词），
/// 四个源各抄一份 URLSession + 信号量 + 状态码判断，出错时的日志格式也会各飘一套。
///
/// ⚠️ 全部是**同步**的：调用方（`CustomLyrics.autoSelectLyrics`）本来就在后台队列上
///   串行跑整条链路，用信号量等结果是这套代码一贯的写法（见 `LrclibLyricsRepository.perform`）。
///   ⚠️ 不要把这里的东西挪到主线程上调用。
enum LyricsSourceHTTP {

    /// 中文曲库（QQ / 酷狗）要浏览器 UA，否则有些接口直接 403。
    /// BiniLyrics / Unison 不挑 UA，一并用它 —— 四个都是网页接口，浏览器身份最不容易被拦。
    /// 与 Taurus 里 `SGLyricsBrowserAgent` 同一串。
    static let browserUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15"
        + " (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static func getJSON(
        _ url: URL,
        headers: [String: String] = [:],
        tag: String
    ) -> Any? {
        guard let data = send(URLRequest(url: url), headers: headers, tag: tag) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func postJSON(
        _ url: URL,
        body: Any,
        headers: [String: String] = [:],
        tag: String
    ) -> Any? {
        guard JSONSerialization.isValidJSONObject(body),
              let payload = try? JSONSerialization.data(withJSONObject: body) else {
            writeDebugLog("[\(tag)] request body is not JSON-serialisable")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload

        var allHeaders = headers
        allHeaders["Content-Type"] = "application/json"

        guard let data = send(request, headers: allHeaders, tag: tag) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func getText(
        _ url: URL,
        headers: [String: String] = [:],
        tag: String
    ) -> String? {
        guard let data = send(URLRequest(url: url), headers: headers, tag: tag) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 查字典用的小工具：`dig(root, ["req", "data", "lyric"])`。
    /// 中间任何一层不是字典就返回 nil（JSON 的形状经常随接口版本变）。
    static func dig(_ root: Any?, _ path: [String]) -> Any? {
        var current = root
        for key in path {
            guard let dictionary = current as? [String: Any] else { return nil }
            current = dictionary[key]
        }
        return current
    }

    private static func send(
        _ original: URLRequest,
        headers: [String: String],
        tag: String
    ) -> Data? {
        var request = original
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let host = request.url?.host ?? "?"

        let semaphore = DispatchSemaphore(value: 0)
        var body: Data?
        var status = 0
        var failure: Error?

        session.dataTask(with: request) { responseData, response, taskError in
            body = responseData
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            failure = taskError
            semaphore.signal()
        }.resume()

        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            writeDebugLog("[\(tag)] \(host) timed out")
            return nil
        }
        if let failure {
            writeDebugLog("[\(tag)] \(host) failed: \(failure.localizedDescription)")
            return nil
        }
        guard (200..<300).contains(status) else {
            writeDebugLog("[\(tag)] \(host) answered \(status)")
            return nil
        }
        return body
    }
}
