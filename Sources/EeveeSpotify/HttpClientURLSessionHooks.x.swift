import Foundation
import Orion

// Sibling delegate to SPTDataLoaderService. Some regions (e.g. gae2) ship
// bootstrap / customize / PAM responses through this delegate instead — without
// hooking both, server-rendered free-tier strings slip through.
class HttpClientURLSessionHook: ClassHook<NSObject>, SpotifySessionDelegate {
    typealias Group = PremiumBootstrapGroup
    static let targetName = "Connectivity_HttpClientKit.HttpClientURLSession"

    func URLSession(
        _ session: URLSession,
        task: URLSessionDataTask,
        didCompleteWithError error: Error?
    ) {
        if let request = task.currentRequest,
           let headers = request.allHTTPHeaderFields,
           let auth = headers["Authorization"] ?? headers["authorization"],
           auth.hasPrefix("Bearer ") {
            let token = String(auth.dropFirst(7))
            setSpotifyAccessToken(token)
            // 只记**形状**与来源，绝不记 token 本身。
            // 2026-09-30 再加两道：① `prefix=前6字符` 换成轮换序号 —— token 的任何片段
            // 都没有调试价值，"这一场里有没有换过 token"才是判据；
            // ② 整条 URL 只留 scheme+host+path：query 里带着歌单/曲目/时区
            // （19 号日志里 73 条 `[TokenCapture]` 每条都背着一整个 query）。
            let dotCount = token.filter { $0 == "." }.count
            let shape = "len=\(token.count) dots=\(dotCount) \(SpotifyTokenOrdinal.label(for: token))"
            writeDebugLog("[TokenCapture] \(shape) from \(DebugLogSanitizer.logSafeURL(task.currentRequest?.url))")
        }

        guard let url = task.currentRequest?.url else {
            orig.URLSession(session, task: task, didCompleteWithError: error)
            return
        }

        if CasitaResponseProbe.shouldProbe(url) {
            CasitaResponseProbe.flush(task, url: url)
        }

        if SpotifyResponsePatcher.shouldBlock(url) {
            orig.URLSession(session, dataTask: task, didReceiveData: SpotifyResponsePatcher.blockedResponseData(for: url))
            orig.URLSession(session, task: task, didCompleteWithError: nil)
            return
        }

        if SpotifyResponsePatcher.consumeCustomizeTask(task.taskIdentifier) {
            orig.URLSession(session, task: task, didCompleteWithError: nil)
            return
        }

        guard error == nil, SpotifyResponsePatcher.shouldModify(url) else {
            orig.URLSession(session, task: task, didCompleteWithError: error)
            return
        }

        guard let buffer = URLSessionHelper.shared.obtainData(for: task) else {
            // marked for modify but no body bytes (0-byte/early-completion/redirect).
            // Always forward completion or Spotify hangs and gets watchdog-killed.
            if url.isCustomize, let cached = SpotifyResponsePatcher.cachedCustomizeData {
                orig.URLSession(session, dataTask: task, didReceiveData: cached)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
            } else {
                // Some Spotify builds complete "modified" tasks with 0 body bytes.
                // We previously forwarded completion only, which can crash callers that
                // assume at least one didReceiveData before completion.
                writeDebugLog("[HCUS] Missing buffered body for \(DebugLogSanitizer.logSafeURL(url)) (taskId=\(task.taskIdentifier))")
                orig.URLSession(session, dataTask: task, didReceiveData: Data())
                orig.URLSession(session, task: task, didCompleteWithError: error)
            }
            return
        }

        do {
            if url.isLyrics {
                let originalLyrics = try? Lyrics(serializedBytes: buffer)

                // 「禁用歌词功能」：**主动挡掉 Spotify 自带的那份歌词**。
                //
                // 选项说明原话就是"还会阻止 Spotify 返回其自带的歌词"，而这里以前走的是
                // 下面的 `lyricsPayload = buffer`（取词抛 `.invalidSource` → 放行原始响应），
                // 于是开关打开后官方歌词照旧显示 —— 观感即"选项不生效"。
                if SpotifyResponsePatcher.isLyricsFeatureDisabled {
                    let blocked = SpotifyResponsePatcher.disabledLyricsPayload(original: originalLyrics)
                    writeDebugLog("[HCUS] lyrics feature disabled — blocking Spotify's own lyrics")
                    orig.URLSession(session, dataTask: task, didReceiveData: blocked)
                    orig.URLSession(session, task: task, didCompleteWithError: nil)
                    return
                }

                // ── 分档预算 + 结果备忘（与 `SPTDataLoaderService` 那条路**对齐**）──────
                //
                // ⚠️ 2026-10-02（v4.11.1）：v4.11 把这套调度只写在了
                // `DataLoaderServiceHooks`（`SPTDataLoaderService`）那一条路上，
                // 但真机日志 28→35 **每一份**都是 `[DL]` 零行、`[HCUS]` 若干行 ——
                // 这台设备上歌词响应走的是 `Connectivity_HttpClientKit.HttpClientURLSession`
                // ⇒ 分档预算与结果备忘**一次都没真正生效**（用户"看不出修了什么"的直接原因）。
                //
                // 现在两条路共用 `LyricsResponseCache`（同一个共享实例、同一套计数），
                // 各自打自己的 `[DL]` / `[HCUS]` 结果行。语义与理由见
                // `LyricsResponseCache` 的文件头（含真机四档实测数据）。
                let cache = LyricsResponseCache.shared
                let cacheSignature = LyricsResponseCache.currentSignature
                let plan = cache.budgetPlan(forPath: url.path, signature: cacheSignature)

                if case let .cached(payload) = plan.plan {
                    // 备忘命中 = 刚产出过、曲目与设置都没变 → 一个字节都不用等。
                    cache.recordOutcome(.memoHit(bytes: payload.count), route: "HCUS", plan: plan)
                    orig.URLSession(session, dataTask: task, didReceiveData: payload)
                    orig.URLSession(session, task: task, didCompleteWithError: nil)
                    return
                }

                let budget = plan.budget
                let startedAt = Date()
                let semaphore = DispatchSemaphore(value: 0)
                var customLyricsData: Data?
                DispatchQueue.global(qos: .userInitiated).async {
                    customLyricsData = try? getLyricsDataForCurrentTrack(url.path, originalLyrics: originalLyrics)
                    semaphore.signal()
                }
                let waitResult = semaphore.wait(timeout: .now() + budget)
                // 同 SPTDataLoaderService：预算内没拿到词也要给一份可解析的占位，
                // 否则这次歌词请求等于"没有响应"，NPV 不会创建歌词卡片。
                // 见 `unavailableLyricsBytes`（CustomLyrics.x.swift 文件作用域函数）。
                let lyricsPayload: Data
                if let customLyricsData {
                    lyricsPayload = customLyricsData
                    // 真结果才进备忘（占位不进 —— 那是"还不知道"，不是结论）。
                    cache.store(customLyricsData, forPath: url.path, signature: cacheSignature)
                    cache.recordOutcome(
                        .fetched(bytes: customLyricsData.count, elapsed: Date().timeIntervalSince(startedAt)),
                        route: "HCUS", plan: plan
                    )
                } else {
                    // ⚠️ 2026-10-03：这里**不再交占位**，放行 Spotify 原始响应 ——
                    // 日志 36 证明了"1.5s 到点就交占位"的代价：占位被按曲目留下，
                    // 3 秒后真词到手也刷不进去（用户看到的就是"未找到歌词"）。
                    // 详见 `LyricsResponseCache.firstAttemptBudget` 的说明。
                    // 现在两条路都只交真结果；这条边只在"取词真的失败/超时"时走到。
                    lyricsPayload = buffer
                    cache.recordOutcome(
                        .placeholder(dueToTimeout: waitResult == .timedOut,
                                     elapsed: Date().timeIntervalSince(startedAt)),
                        route: "HCUS", plan: plan
                    )
                }
                orig.URLSession(session, dataTask: task, didReceiveData: lyricsPayload)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                // 交付时刻自报：**这是肉眼唯一看不见、却决定"卡片这一帧建不建得出来"的量**
                // （NPV 的模块列表在组件加载完之后才建）。和 `[Lyrics] Request for …` 配对读。
                writeDebugLog("[HCUS] lyrics 交付给 Spotify — \(lyricsPayload.count) bytes（请求起算 \(String(format: "%.1f", Date().timeIntervalSince(startedAt)))s）")
                return
            }

            if let result = try SpotifyResponsePatcher.patch(url: url, buffer: buffer) {
                writeDebugLog("[HCUS] Patched \(result.tag.rawValue)")
                orig.URLSession(session, dataTask: task, didReceiveData: result.data)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                return
            }
            // patch() returned nil — no transform, but didReceiveData already
            // suppressed the original. Replay or consumer hangs.
            orig.URLSession(session, dataTask: task, didReceiveData: buffer)
            orig.URLSession(session, task: task, didCompleteWithError: nil)
        } catch {
            orig.URLSession(session, task: task, didCompleteWithError: error)
        }
    }

    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveResponse response: HTTPURLResponse,
        completionHandler handler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let url = task.currentRequest?.url, url.isCustomize, response.statusCode == 304,
           let cached = SpotifyResponsePatcher.cachedCustomizeData {
            guard let synthetic = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: [:]) else {
                orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
                return
            }
            // ⚠️ 这行不是装饰：它是"种子真的被回放了"的**唯一**直接证据。
            writeDebugLog("[HCUS] customize 304 → 回放种子 \(cached.count) 字节")
            orig.URLSession(session, dataTask: task, didReceiveResponse: synthetic, completionHandler: handler)
            orig.URLSession(session, dataTask: task, didReceiveData: cached)
            SpotifyResponsePatcher.markCustomizeTaskHandled(task.taskIdentifier)
            return
        }

        // 诊断：记录歌词响应的原始状态与响应头（**200 与 404 两种都记**）。
        // 见 `SpotifyResponsePatcher.probeLyricsResponseHeaders` 的说明。
        if let probeURL = task.currentRequest?.url {
            SpotifyResponsePatcher.probeLyricsResponseHeaders(url: probeURL, response: response)
            // 正在播放页的「旁路模块」（预热卡嫌疑来源）：状态 + Content-Type。
            SpotifyResponsePatcher.probeNPVModuleHeaders(url: probeURL, response: response)
        }

        guard let url = task.currentRequest?.url, url.isLyrics, response.statusCode != 200 else {
            orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
            return
        }

        // 「禁用歌词功能」：这条路以前会**无条件**合成 200 + 我们的占位（"未找到歌词"），
        // 于是开关打开后我们那份照样出现。禁用时直接放行原始 404（等于"这首歌没有歌词"），
        // 既不取词、也不合成 —— 真正的"什么都不做"。
        if SpotifyResponsePatcher.isLyricsFeatureDisabled {
            writeDebugLog("[HCUS] lyrics feature disabled — passing the \(response.statusCode) through")
            orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
            return
        }

        // Fetch on a background queue while holding the completion handler open.
        // Calling getLyricsDataForCurrentTrack synchronously here would block the
        // delegate queue and prevent subsequent delegate callbacks from firing.
        // ⚠️ 这条路**没走** `LyricsResponseCache` 的分档预算（它是"服务端说这首歌没词"的
        // 404 分支，一条请求只来一次，没有"第二次请求"可指望）——所以这里只量耗时。
        let responseStartedAt = Date()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let data = try? getLyricsDataForCurrentTrack(url.path)
            // 同 SPTDataLoaderService：404 也要给出 200 + 占位，
            // 否则 Spotify 不会为这首歌创建歌词卡片。见 `unavailableLyricsBytes`。
            let payload = data ?? unavailableLyricsBytes(original: nil)

            guard let lyricsData = payload,
                  let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: [:]) else {
                handler(.allow)
                orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: { _ in })
                return
            }

            orig.URLSession(session, dataTask: task, didReceiveResponse: ok, completionHandler: handler)
            orig.URLSession(session, dataTask: task, didReceiveData: lyricsData)
            orig.URLSession(session, task: task, didCompleteWithError: nil)
            // 404 分支的交付时刻（与上面 200 分支同族；`hasData=` 区分"取到了词"还是"只有占位"）。
            writeDebugLog("[HCUS] lyrics 交付给 Spotify（404 合成 200）— \(lyricsData.count) bytes, hasData=\(data != nil)，服务端 404 起算 \(String(format: "%.1f", Date().timeIntervalSince(responseStartedAt)))s")
        }
    }

    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveData data: Data
    ) {
        guard let url = task.currentRequest?.url else { return }
        if SpotifyResponsePatcher.shouldBlock(url) { return }
        // 排障：扫一下这块数据里有没有 `has_lyrics`，定位它的线上来源（只读、不改字节）。
        SpotifyResponsePatcher.probeHasLyricsKey(url: url, taskID: task.taskIdentifier, data: data)
        // 排障：正在播放页的「旁路模块」响应体（预热卡的嫌疑来源）。只读、不改字节。
        SpotifyResponsePatcher.probeNPVModuleBody(url: url, taskID: task.taskIdentifier, data: data)
        // 排障：全响应扫「预热 / 预发行」关键字（坏卡的数据来源）。只读、不改字节。
        SpotifyResponsePatcher.probePreReleaseNeedles(url: url, taskID: task.taskIdentifier, data: data)
        if CasitaResponseProbe.shouldProbe(url) {
            CasitaResponseProbe.append(data, for: task)
        }
        if SpotifyResponsePatcher.shouldModify(url) {
            URLSessionHelper.shared.setOrAppend(data, for: task)
            return
        }
        orig.URLSession(session, dataTask: task, didReceiveData: data)
    }
}
