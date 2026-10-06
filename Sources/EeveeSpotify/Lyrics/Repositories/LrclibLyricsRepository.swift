import Foundation

// ★ 2026-10-13：传输层加固，从上游 `EeveeSpotifyReincarnated` 的同名文件移植
// （上游 313 行 / 我们原来 145 行）。移植的是**取词之前的那一段**，不是取词逻辑本身：
//
//   ① `LrclibTLSDelegate` —— 用对端证书链**重建** trust 再按原域名验链。
//      对"直连 IP"的请求，直接复用 URLSession 给的那个 trust 对象做链构建会失败
//      （errSSLXCertChainInvalid / -9802），哪怕证书本身没问题。
//   ② `resolveIPv4` —— 有些网络到 lrclib.net 的 IPv6 路径是坏的（TCP 层 ETIMEDOUT），
//      显式解成 IPv4 直连，TLS 域名校验交给上面那个 delegate。
//   ③ 会话：`ephemeral` + 10s 超时。原来用 `.default` 且用系统默认超时（LRCLIB 偶尔
//      慢到 4s 都回不来，实测会稳定超时）；直连失败还会**回退域名再试一次**。
//   ④ `perform` 不再强解 `URL(...)!` / `data!`，并把解码失败时的响应体前 300 字节写进日志
//      （原来只报 `decodingError`，看不出是"没这首歌"还是"回了个 HTML"）。
//
// 取词语义（instrumental 的 `isInstrumental` 标记、逐条调试日志、plainLyrics 缺失即
// `decodingError`）**保持本仓库原样**，没有跟着上游改 —— 那几处是我们按听歌页需求
// 特意加的（见下面 `getLyrics` 里的说明）。

/// 对"直连 IP"的请求，按**原域名**重建并校验证书链。
private class LrclibTLSDelegate: NSObject, URLSessionTaskDelegate {
    let expectedHost: String

    init(expectedHost: String) {
        self.expectedHost = expectedHost
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Build a fresh trust object from the peer's certificate chain, evaluated
        // against the original hostname. Re-using and mutating the trust object
        // supplied by URLSession for a raw-IP connection can fail chain building
        // (errSSLXCertChainInvalid / -9802) even when the certificate is valid.
        //
        // SecTrustGetCertificateAtIndex is deprecated in iOS 15 and returns nil on
        // iOS 16+ / iOS 26+. Use SecTrustCopyCertificateChain where available.
        //
        // FIX: SecTrustCopyCertificateChain returns a plain CFTypeRef/CFArray on
        // iOS 26; the Swift conditional cast `as? [SecCertificate]` can silently
        // return nil on some OS builds when the bridging isn't automatic.
        // Use CFArrayGetCount / CFArrayGetValueAtIndex to extract the chain safely.
        let certChain: [SecCertificate]
        if #available(iOS 15.0, *) {
            guard let chainRef = SecTrustCopyCertificateChain(serverTrust) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let count = CFArrayGetCount(chainRef)
            guard count > 0 else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            certChain = (0..<count).compactMap { i in
                CFArrayGetValueAtIndex(chainRef, i)
                    .map { Unmanaged<SecCertificate>.fromOpaque($0).takeUnretainedValue() }
            }
        } else {
            let count = SecTrustGetCertificateCount(serverTrust)
            guard count > 0 else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            certChain = (0..<count).compactMap { SecTrustGetCertificateAtIndex(serverTrust, $0) }
            guard !certChain.isEmpty else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
        }

        let policy = SecPolicyCreateSSL(true, expectedHost as CFString)

        var freshTrust: SecTrust?
        guard SecTrustCreateWithCertificates(certChain as CFArray, policy, &freshTrust) == errSecSuccess,
              let freshTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        var error: CFError?
        if SecTrustEvaluateWithError(freshTrust, &error) {
            completionHandler(.useCredential, URLCredential(trust: freshTrust))
        } else {
            writeDebugLog("[LRCLIB] TLS validation failed for \(expectedHost): \(String(describing: error))")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// 显式解 IPv4。坏掉的 IPv6 路径在 TCP 层就超时，症状是"所有取词都超时"。
private func resolveIPv4(_ host: String) -> String? {
    var hints = addrinfo(
        ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
        ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
    )
    var result: UnsafeMutablePointer<addrinfo>?

    guard getaddrinfo(host, nil, &hints, &result) == 0, let addr = result else {
        return nil
    }
    defer { freeaddrinfo(result) }

    var ipBuffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    let sockaddrIn = addr.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0 }
    var sinAddr = sockaddrIn.pointee.sin_addr

    guard inet_ntop(AF_INET, &sinAddr, &ipBuffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
        return nil
    }

    return String(cString: ipBuffer)
}

class LrclibLyricsRepository: LyricsRepository {
    var apiUrl: String
    private let session: URLSession

    private init(apiUrl: String) {
        self.apiUrl = apiUrl

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [
            "User-Agent": "EeveeSpotify v\(EeveeSpotify.version) https://github.com/zbzxbg/EeveeSpotifyEvolved"
        ]
        // LRCLIB 偶尔很慢：给 10s（原来用系统默认值，直连与回退两次尝试都会卡在同一拍上）。
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.waitsForConnectivity = false

        if let host = URL(string: apiUrl)?.host {
            session = URLSession(
                configuration: configuration,
                delegate: LrclibTLSDelegate(expectedHost: host),
                delegateQueue: nil
            )
        } else {
            // 设置页里填的 URL 解析不出 host：退回普通会话（请求会按原样子发出去，
            // 由 `perform` 的 `guard let url` 决定要不要报错）。
            session = URLSession(configuration: configuration)
        }
    }
    
    static let originalApiUrl = "https://lrclib.net/api"
    
    static let shared = LrclibLyricsRepository(
        apiUrl: UserDefaults.lyricsOptions.lrclibUrl
    )
    
    private func perform(
        _ path: String, 
        query: [String:Any] = [:]
    ) throws -> Data {
        var stringUrl = "\(apiUrl)\(path)"

        if !query.isEmpty {
            let queryString = query.queryString
            stringUrl += "?\(queryString)"
        }
        
        guard let url = URL(string: stringUrl) else {
            writeDebugLog("[LRCLIB] Bad URL: \(stringUrl)")
            throw LyricsError.decodingError
        }

        var request = URLRequest(url: url)

        // 能解出 IPv4 就直连它，并把原域名放进 `Host` 头；TLS 的域名校验由
        // `LrclibTLSDelegate` 按原域名完成。
        if let host = url.host, let ip = resolveIPv4(host) {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.host = ip
            if let ipUrl = components?.url {
                request = URLRequest(url: ipUrl)
                request.setValue(host, forHTTPHeaderField: "Host")
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var error: Error?

        let task = session.dataTask(with: request) { responseData, _, err in
            error = err
            data = responseData
            semaphore.signal()
        }

        task.resume()
        semaphore.wait()

        if error != nil, request.url != url {
            // 直连失败 ⇒ 用原域名再试一次（有些网络反过来：只认域名不认裸 IP）。
            writeDebugLog("[LRCLIB] IPv4-direct attempt failed (\(error!)), retrying via hostname")

            let fallbackSemaphore = DispatchSemaphore(value: 0)
            let fallbackRequest = URLRequest(url: url)

            let fallbackTask = session.dataTask(with: fallbackRequest) { response, _, err in
                error = err
                data = response
                fallbackSemaphore.signal()
            }

            fallbackTask.resume()
            fallbackSemaphore.wait()
        }

        if let error = error {
            writeDebugLog("[LRCLIB] Request error for \(stringUrl): \(error)")
            throw error
        }

        guard let data else {
            writeDebugLog("[LRCLIB] No data returned for \(stringUrl)")
            throw LyricsError.decodingError
        }

        writeDebugLog("[LRCLIB] \(stringUrl) -> \(data.count) bytes")
        return data
    }
    
    private func getSong(trackName: String, artistName: String) throws -> LrclibSong {
        let data: Data = try perform("/get", query: [
            "track_name": trackName,
            "artist_name": artistName
        ])
        do {
            return try JSONDecoder().decode(LrclibSong.self, from: data)
        } catch {
            // 只报 decodingError 看不出是"没这首歌"还是"回了个 HTML/错误页" ⇒ 带上响应体。
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            writeDebugLog("[LRCLIB] Decode error for \(trackName)/\(artistName): \(error). Body: \(body.prefix(300))")
            throw error
        }
    }
    
    private func mapSyncedLyricsLines(_ lines: [String]) -> [LyricsLineDto] {
        return lines.compactMap { line in
            guard let match = line.firstMatch(
                "\\[(?<minute>\\d*):(?<seconds>\\d+\\.\\d+|\\d+)\\] ?(?<content>.*)"
            ) else {
                return nil
            }
            
            var captures: [String: String] = [:]
            
            for name in ["minute", "seconds", "content"] {
                let matchRange = match.range(withName: name)
                
                if let substringRange = Range(matchRange, in: line) {
                    captures[name] = String(line[substringRange])
                }
            }
            
            let minute = Int(captures["minute"]!)!
            let seconds = Float(captures["seconds"]!)!
            let content = captures["content"]!
            
            return LyricsLineDto(
                content: content.lyricsNoteIfEmpty,
                offsetMs: Int(minute * 60 * 1000 + Int(seconds * 1000))
            )
        }
    }

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        writeDebugLog("[LRCLIB] Fetching lyrics for \"\(query.title)\" - \(query.primaryArtist)")
        let song: LrclibSong

        do {
            song = try getSong(trackName: query.title, artistName: query.primaryArtist)
        } catch let firstError {
            writeDebugLog("[LRCLIB] Initial fetch failed (retrying stripped title): \(firstError)")
            let strippedTitle = query.title.strippedTrackTitle
            do {
                song = try getSong(trackName: strippedTitle, artistName: query.primaryArtist)
            } catch {
                throw LyricsError.noSuchSong
            }
        }

        if song.instrumental {
            writeDebugLog("[LRCLIB] Instrumental — returning empty lyrics")
            return LyricsDto(
                lines: [],
                timeSynced: false,
                romanization: .original,
                // ★ 2026-10-11：同上 —— 源明确判定过，听歌页据此写「此歌曲为纯音乐。」。
                isInstrumental: true
            )
        }

        // `!syncedLyrics.isEmpty`：LRCLIB 有时回一个**空字符串**的 syncedLyrics，
        // 那会做出一个"0 行但标记为 timeSynced"的结果（听歌页上就是一片空白），
        // 落到下面按 plainLyrics 取才是对的。
        if let syncedLyrics = song.syncedLyrics, !syncedLyrics.isEmpty {
            let lines = Array(syncedLyrics.components(separatedBy: "\n").dropLast())
            writeDebugLog("[LRCLIB] Synced lyrics — \(lines.count) line(s)")
            return LyricsDto(
                lines: mapSyncedLyricsLines(lines),
                timeSynced: true,
                romanization: lines.canBeRomanized ? .canBeRomanized : .original
            )
        }
        
        guard let plainLyrics = song.plainLyrics else {
            throw LyricsError.decodingError
        }
        
        let lines = Array(plainLyrics.components(separatedBy: "\n").dropLast())
        writeDebugLog("[LRCLIB] Plain lyrics — \(lines.count) line(s)")
        return LyricsDto(
            lines: lines.map { content in LyricsLineDto(content: content) },
            timeSynced: false,
            romanization: lines.canBeRomanized ? .canBeRomanized : .original
        )
    }
}
