import Foundation
import Orion

// Bearer token captured from premium-relevant requests; reused by lyrics fetch etc.
public var spotifyAccessToken: String?

// ng（Reborn-ng）歌词仓库（SpicyLyrics 等）通过下面这两个访问器读写 token。
// ★ 2026-10-13：**SpicyLyrics 已经不再消费它了** —— 那个源搬到了官方 v1 API，
//   只认自己的 `sl_pk_` key（见 `SpicyLyricsRepository` 文件头），那条路本来就要抓
//   Spotify 凭据，属于旧 `/query` 时代的产物。
//   ⇒ 现在这里**没有歌词侧消费者**（`spotifyAccessTokenSnapshot()` 零调用点）。
//   捕获本身先留着：`spotifyAccessToken` 是 public 既有读取点，而且同处的日志
//   （token 形状 / 轮换序号，见 `SpotifyTokenOrdinal`）是排查登录态时唯一能看的信号。
//   ⚠️ 别把"改歌词源"和这里联系起来 —— 两者已经无关。
// URLSession 回调与歌词仓库跑在不同队列上，直接读写无保护的全局 String 有数据竞争，
// 这里用锁串行化；`spotifyAccessToken` 变量本身保留，兼容既有读取点。
private let spotifyAccessTokenLock = NSLock()

func setSpotifyAccessToken(_ token: String?) {
    spotifyAccessTokenLock.lock()
    spotifyAccessToken = token
    spotifyAccessTokenLock.unlock()
}

func spotifyAccessTokenSnapshot() -> String? {
    spotifyAccessTokenLock.lock()
    defer { spotifyAccessTokenLock.unlock() }
    return spotifyAccessToken
}

// Spotify's primary URLSession delegate (wg-spclient: bootstrap, customize, PAM).
// Patching lives in SpotifyResponsePatcher so HttpClientURLSessionHook can share it.

class SPTDataLoaderServiceHook: ClassHook<NSObject>, SpotifySessionDelegate {
    typealias Group = PremiumBootstrapGroup
    static let targetName = "SPTDataLoaderService"

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
            // 只记**形状**与来源，绝不记 token 本身。见 `HttpClientURLSessionHooks` 同处的说明：
            // 2026-09-30 起 `prefix=前6字符` 换成轮换序号，URL 只留 scheme+host+path。
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

        // 304 already served — suppress the second completion.
        if SpotifyResponsePatcher.consumeCustomizeTask(task.taskIdentifier) {
            orig.URLSession(session, task: task, didCompleteWithError: nil)
            return
        }

        guard error == nil, SpotifyResponsePatcher.shouldModify(url) else {
            orig.URLSession(session, task: task, didCompleteWithError: error)
            return
        }

        guard let buffer = URLSessionHelper.shared.obtainData(for: task) else {
            // Customize 304 fallback — wg-spclient returned 304, no buffer
            // to patch, but we have a cached body from a prior 200.
            // ⚠️ 2026-10-12：改走 `customizeReplay` —— **同版本的落盘真 body 优先，种子兜底**
            //   （以前内存里的种子永远优先 ⇒ 磁盘上那份更好的 body 一次都没用上，日志 69 的现象）。
            if url.isCustomize, let cached = SpotifyResponsePatcher.customizeReplay?.data {
                orig.URLSession(session, dataTask: task, didReceiveData: cached)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
            } else {
                // Some Spotify builds complete "modified" tasks with 0 body bytes.
                // Forwarding completion only can crash consumers that assume at least
                // one didReceiveData callback before completion.
                writeDebugLog("[DL] Missing buffered body for \(DebugLogSanitizer.logSafeURL(url)) (taskId=\(task.taskIdentifier))")
                orig.URLSession(session, dataTask: task, didReceiveData: Data())
                // Always forward completion; otherwise Spotify may hang and get watchdog-killed.
                orig.URLSession(session, task: task, didCompleteWithError: error)
            }
            return
        }

        do {
            // Lyrics — async fetch with 18s budget, falls back to Spotify's own response on failure.
            //
            // iOS 27 / Spotify 9.1.60 fix: Spotify's URLSession delegate handler for
            // didReceiveData now accesses @MainActor-isolated state. When we call orig.*
            // from the SPTDataLoaderService delegate queue (a background serial queue),
            // Swift's strict concurrency runtime trips _swift_task_checkIsolatedSwift and
            // kills the process with EXC_BREAKPOINT / SIGTRAP.
            //
            // Fix: dispatch the two orig.URLSession calls onto the main queue.
            // This matches the execution context Spotify's renderer expects and eliminates
            // the @MainActor isolation violation entirely.
            if url.isLyrics {
                let originalLyrics = try? Lyrics(serializedBytes: buffer)

                // 「禁用歌词功能」：**主动挡掉 Spotify 自带的那份歌词**。
                // 理由同 `HttpClientURLSessionHooks`：选项说明就写着"还会阻止 Spotify 返回
                // 其自带的歌词"，而这条路以前是 `lyricsPayload = buffer`（把官方歌词放行）。
                if SpotifyResponsePatcher.isLyricsFeatureDisabled {
                    let blocked = SpotifyResponsePatcher.disabledLyricsPayload(original: originalLyrics)
                    writeDebugLog("[DL] lyrics feature disabled — blocking Spotify's own lyrics")
                    // 顺手清掉结果备忘：重新打开歌词功能后不该再拿旧 payload 顶上。
                    LyricsResponseCache.shared.reset()
                    DispatchQueue.main.async { [self] in
                        orig.URLSession(session, dataTask: task, didReceiveData: blocked)
                        orig.URLSession(session, task: task, didCompleteWithError: nil)
                    }
                    return
                }

                // ── 分档预算 + 结果备忘（v4.11）─────────────────────────────────────
                //
                // 真机四档实测（2026-10-02 日志 34，同一首"全网没词"的歌，Spotify 9.1.88）：
                //   不回退 ≤1s → 卡片在；＋Genius 回退 4s → 开始丢；＋AMLL 优先 6s → 更差；
                //   多级回退（4 源串行）13s → 最差。
                // ⇒ NPV 的模块列表是"组件加载完之后"才建的（`…WithDidLoadComponents…`），
                //   响应晚于约 1~4s 就赶不上这一轮；"退出重进就好"= 让列表重建一次。
                //
                // 对策（完整理由写在 `LyricsResponseCache` 的注释里）：
                //   · 刚产出过且曲目/设置都没变 → 直接交（0 等待）；
                //   · 这首歌的**第一次**请求 → 只等 1.5s，先交占位把卡片建出来；
                //   · **后续**请求（Spotify 交完占位后会立刻再来一次 —— 日志 34 里 4/4）
                //     → 用长预算，把真词带上去。
                // ⚠️ 2026-10-02（v4.11.1）：改用 `budgetPlan` —— 与 `HttpClientURLSessionHooks`
                // **共用同一个 `LyricsResponseCache` 实例与同一套计数**（原先两边各算各的，
                // 而真机日志 28→35 里只有 `[HCUS]` 一条路在跑，这套调度等于没生效）。
                let cache = LyricsResponseCache.shared
                let cacheSignature = LyricsResponseCache.currentSignature
                let requestPlan = cache.budgetPlan(forPath: url.path, signature: cacheSignature)
                let startedAt = Date()

                if case let .cached(payload) = requestPlan.plan {
                    cache.recordOutcome(.memoHit(bytes: payload.count), route: "DL", plan: requestPlan)
                    DispatchQueue.main.async { [self] in
                        orig.URLSession(session, dataTask: task, didReceiveData: payload)
                        orig.URLSession(session, task: task, didCompleteWithError: nil)
                    }
                    return
                }

                let budget = requestPlan.budget
                let semaphore = DispatchSemaphore(value: 0)
                var customLyricsData: Data?

                DispatchQueue.global(qos: .userInitiated).async {
                    customLyricsData = try? getLyricsDataForCurrentTrack(url.path, originalLyrics: originalLyrics)
                    semaphore.signal()
                }

                let waitResult = semaphore.wait(timeout: .now() + budget)
                // ⚠️ 超时以前只是"退回 Spotify 原始响应"，这里必须补一层兜底：
                // 取词没能在预算内完成时（`customLyricsData` 仍是 nil），仍然交一份
                // 可解析的占位。原因是 NPV 的歌词卡片**等数据到达才创建** —— 一个字节
                // 都不投递就等于"这首歌没有歌词模块"，比内容不完美严重得多。
                //
                // ⚠️ v4.11：占位**不进备忘** —— 它是"还不知道"，不是"查完了没有"；
                // 紧接着那次请求要照旧耐心等，把真结果拿回来。
                let lyricsPayload: Data
                if let customLyricsData {
                    lyricsPayload = customLyricsData
                    cache.store(customLyricsData, forPath: url.path, signature: cacheSignature)
                    cache.recordOutcome(
                        .fetched(bytes: customLyricsData.count, elapsed: Date().timeIntervalSince(startedAt)),
                        route: "DL", plan: requestPlan
                    )
                } else if waitResult == .timedOut {
                    lyricsPayload = unavailableLyricsBytes(original: originalLyrics) ?? buffer
                    cache.recordOutcome(
                        .placeholder(dueToTimeout: true, elapsed: Date().timeIntervalSince(startedAt)),
                        route: "DL", plan: requestPlan
                    )
                } else {
                    // 取词在预算内失败（报错/没有词）→ 仍要交一份占位，否则卡片不建。
                    lyricsPayload = unavailableLyricsBytes(original: originalLyrics) ?? buffer
                    cache.recordOutcome(
                        .placeholder(dueToTimeout: false, elapsed: Date().timeIntervalSince(startedAt)),
                        route: "DL", plan: requestPlan
                    )
                }
                DispatchQueue.main.async { [self] in
                    orig.URLSession(session, dataTask: task, didReceiveData: lyricsPayload)
                    orig.URLSession(session, task: task, didCompleteWithError: nil)
                    // 交付时刻自报（与 HttpClient 那条路同族）——决定"卡片这一帧建不建得出来"。
                    writeDebugLog("[DL] lyrics delivered to Spotify - \(lyricsPayload.count) bytes (\(String(format: "%.1f", Date().timeIntervalSince(startedAt)))s since the request)")
                }
                return
            }

            if let result = try SpotifyResponsePatcher.patch(url: url, buffer: buffer) {
                writeDebugLog("[DL] Patched \(result.tag.rawValue)")
                orig.URLSession(session, dataTask: task, didReceiveData: result.data)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                return
            }
            // patch() returned nil but didReceiveData already suppressed the original —
            // replay the buffer or the consumer hangs (casita/browsita with no ad sections).
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
           let replay = SpotifyResponsePatcher.customizeReplay {
            let cached = replay.data
            // 304, but our cache holds the already-patched body; force 200 so the
            // consumer accepts the cached data we replay next.
            guard let synthetic = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: [:]) else {
                orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
                return
            }
            // ⚠️ 这行不是装饰：它是"回放了什么"的**唯一**直接证据（并说清用的是哪一份）。
            writeDebugLog("[DL] customize 304 -> replaying \(replay.source), \(cached.count) bytes")
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

        // Lyrics 4xx/5xx — replace with our custom fetch result so the
        // consumer doesn't show "no lyrics available".
        //
        // IMPORTANT: getLyricsDataForCurrentTrack is a blocking network call.
        // Calling it synchronously here deadlocks because this delegate queue is
        // also needed to deliver subsequent delegate callbacks (didReceiveData,
        // didCompleteWithError). The fix is to fetch on a background queue while
        // holding the URLSession completion handler open — URLSession won't
        // proceed until we call handler(.allow/.cancel), so we have time to fetch
        // and then deliver everything ourselves.
        guard let url = task.currentRequest?.url, url.isLyrics, response.statusCode != 200 else {
            orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
            return
        }

        // 「禁用歌词功能」：这条路以前会**无条件**合成 200 + 我们的占位（"未找到歌词"）。
        // 禁用时直接放行原始 404 —— 不取词、不合成，真正的"什么都不做"。
        if SpotifyResponsePatcher.isLyricsFeatureDisabled {
            writeDebugLog("[DL] lyrics feature disabled — passing the \(response.statusCode) through")
            orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let data = try? getLyricsDataForCurrentTrack(url.path)
            // 取词失败（或返回 nil）时也要给出一份占位：这条路径的原始响应是 404，
            // 放行 404 = Spotify 不创建歌词卡片 = 这首歌看起来"根本没有歌词模块"。
            let payload = data ?? unavailableLyricsBytes(original: nil)

            guard let lyricsData = payload else {
                // 连占位都构造不出来（序列化失败，几乎不可能）——只能放行原始响应。
                handler(.allow)
                orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: { _ in })
                return
            }

            guard let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: [:]) else {
                handler(.allow)
                orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: { _ in })
                return
            }

            DispatchQueue.main.async { [self] in
                orig.URLSession(session, dataTask: task, didReceiveResponse: ok, completionHandler: handler)
                orig.URLSession(session, dataTask: task, didReceiveData: lyricsData)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
            }
        }
    }

    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveData data: Data
    ) {
        guard let url = task.currentRequest?.url else { return }

        // Suppress original data for endpoints we'll replace in
        // didCompleteWithError — otherwise the consumer sees both.
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
