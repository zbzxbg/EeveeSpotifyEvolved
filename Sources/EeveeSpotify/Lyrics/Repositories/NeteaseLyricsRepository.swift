import Foundation
import CommonCrypto

// MARK: - NeteaseLyricsRepository
//
// 网易云音乐歌词源（直连 weapi）。
//
// ── 为什么直连可行
// music.163.com 的 weapi 接口要求每个请求体携带 params / encSecKey 两个
// 加密字段，但整套加密是「无状态」的：AES 密钥、IV 与 RSA 公钥都是全网
// 写死的常量，不涉及任何用户身份，因此无需像 Musixmatch 那样要求用户
// 提供 token。实测 2026 年当前状态下，搜索（search/get）与歌词
// （song/lyric）接口仅需 `Cookie: os=pc` 即可匿名访问；
// register/anonimous 匿名注册接口已废弃（返回「参数错误」），不再调用。
// 若响应下发会话 cookie 会自动持久化并随后续请求携带。
//
// ── weapi 加密流程（与 NeteaseCloudMusicApi/util/crypto.js 一致）
// 1. 随机 16 字符 secKey；
// 2. params = AES-CBC(明文, key="0CoJUm6Qyw8W8jud", iv="0102030405060708")，
// 再对结果用 key=secKey 加密一次，两次结果均做 base64；
// 3. encSecKey = hex( rawRSA( reverse(secKey), e=65537, 固定 1024 位模数 ) )，
// 左补零到 256 个 hex 字符。这里的 RSA 是无填充的原始模幂（m^e mod n），
// 与 JS 端 BigInt.powMod 等价。
//
// ── 失败兜底
// 本仓库的请求失败/查无此歌统一抛 LyricsError，由 CustomLyrics.x.swift 的
// 既有回退逻辑（geniusFallback 等）接管；本文件不参与多级回退编排。

class NeteaseLyricsRepository: LyricsRepository {

    static let shared = NeteaseLyricsRepository()

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration)
    }

    private let session: URLSession

    private class CachedLyrics {
        let dto: LyricsDto

        init(dto: LyricsDto) {
            self.dto = dto
        }
    }

    private let lyricsCache = NSCache<NSString, CachedLyrics>()

    // MARK: - 常量

    private static let weapiBaseUrl = "https://music.163.com"
    private static let aesFirstKey = "0CoJUm6Qyw8W8jud"
    private static let aesIv = "0102030405060708"
    private static let eapiKey = "e82ckenh8dichen8"

    /// weapi 固定 RSA 公钥模数（1024 位，hex，无前导 00）。
    private static let rsaModulusHex =
        "e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725" +
        "152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e031" +
        "2ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b4" +
        "24d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a2" +
        "2b8e7"

    private static let rsaExponent = 65537

    /// 响应下发的 cookie 持久化（部分接口会返回会话 cookie，留作复用）。
    private static let anonymousCookieKey = "ngzhwm_neteaseAnonymousCookie"

    private var anonymousCookie: String {
        get { UserDefaults.standard.string(forKey: Self.anonymousCookieKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.anonymousCookieKey) }
    }

    /// 从匿名 cookie 里提取 __csrf，作为 weapi 请求的 csrf_token。
    private var csrfToken: String {
        let cookie = anonymousCookie
        guard let match = cookie.firstMatch("__csrf=([^;]+)"),
              let tokenRange = Range(match.range(at: 1), in: cookie) else {
            return ""
        }
        return String(cookie[tokenRange])
    }

    // MARK: - weapi 加密
    //
    // AES-128-CBC + PKCS7（密钥为 16 字节 UTF-8 字符串，IV 固定）。
    private func aesCbcEncrypt(_ data: Data, key: String) -> Data? {
        guard let keyData = key.data(using: .utf8),
              let ivData = Self.aesIv.data(using: .utf8) else {
            return nil
        }

        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var bytesEncrypted = 0

        let status: CCCryptorStatus = buffer.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                keyData.withUnsafeBytes { keyBytes in
                    ivData.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, keyData.count,
                            ivBytes.baseAddress,
                            inBytes.baseAddress, data.count,
                            outBytes.baseAddress, bufferSize,
                            &bytesEncrypted
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return buffer.prefix(bytesEncrypted)
    }

    /// AES-128-ECB + PKCS7（eapi 用，无 IV）。
    private func aesEcbEncrypt(_ data: Data, key: String) -> Data? {
        guard let keyData = key.data(using: .utf8) else { return nil }

        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var bytesEncrypted = 0

        let status: CCCryptorStatus = buffer.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                keyData.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                        keyBytes.baseAddress, keyData.count,
                        nil,
                        inBytes.baseAddress, data.count,
                        outBytes.baseAddress, bufferSize,
                        &bytesEncrypted
                    )
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return buffer.prefix(bytesEncrypted)
    }

    /// Data → 小写 hex（eapi params 用；与 weapi 的 base64 不同）。
    private func hexString(_ data: Data) -> String {
        let hexTable = Array("0123456789abcdef".utf8)
        var bytes = [UInt8]()
        bytes.reserveCapacity(data.count * 2)
        for byte in data {
            bytes.append(hexTable[Int(byte) >> 4])
            bytes.append(hexTable[Int(byte) & 0xF])
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    private func md5Hex(_ text: String) -> String {
        guard let data = text.data(using: .utf8) else { return "" }
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { raw in
            digest.withUnsafeMutableBytes { md in
                _ = CC_MD5(
                    raw.baseAddress,
                    CC_LONG(data.count),
                    md.bindMemory(to: UInt8.self).baseAddress
                )
            }
        }
        return hexString(Data(digest))
    }

    /// eapi 参数加密（/api/song/lyric/v1 等新接口）：
    /// params = hex( AES-128-ECB( url + "-36cd479b6b5-" + JSON + "-36cd479b6b5-" + md5("nobody"+url+"use"+JSON+"md5forencrypt") ) )
    private func eapiEncrypt(_ params: [String: Any], url: String) -> String? {
        guard let bodyData = try? JSONSerialization.data(withJSONObject: params),
              let text = String(data: bodyData, encoding: .utf8) else {
            return nil
        }

        let message = "nobody\(url)use\(text)md5forencrypt"
        let digest = md5Hex(message)
        let data = "\(url)-36cd479b6b5-\(text)-36cd479b6b5-\(digest)"

        guard let cipher = aesEcbEncrypt(Data(data.utf8), key: Self.eapiKey) else {
            return nil
        }
        return hexString(cipher)
    }

    /// 生成 (params, encSecKey)，与网易前端 weapi 加密等价。
    private func weapiEncrypt(_ text: String) throws -> (params: String, encSecKey: String) {
        let secKeyCharacters =
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let secKey = String((0..<16).compactMap { _ in secKeyCharacters.randomElement() })

        guard let firstPass = aesCbcEncrypt(Data(text.utf8), key: Self.aesFirstKey) else {
            writeDebugLog("[NetEase] weapiEncrypt AES failure")
            throw LyricsError.decodingError
        }
        let firstPassBase64 = firstPass.base64EncodedString()
        guard let secondPass = aesCbcEncrypt(Data(firstPassBase64.utf8), key: secKey) else {
            writeDebugLog("[NetEase] weapiEncrypt AES failure")
            throw LyricsError.decodingError
        }
        let params = secondPass.base64EncodedString()

        // encSecKey = hex(reverse(secKey) 作为大整数 ^ 65537 mod modulus)，左补零到 256 hex。
        // 手动 hex 表（避免 String(format:) 变参在设备端的类型歧义）。
        let hexTable = Array("0123456789abcdef".utf8)
        var reversedKeyHex = ""
        for byte in String(secKey.reversed()).utf8 {
            reversedKeyHex.append(Character(UnicodeScalar(hexTable[Int(byte) >> 4])))
            reversedKeyHex.append(Character(UnicodeScalar(hexTable[Int(byte) & 0xF])))
        }

        guard let message = NeteaseBigUInt(hex: reversedKeyHex),
              let modulus = NeteaseBigUInt(hex: Self.rsaModulusHex) else {
            writeDebugLog("[NetEase] weapiEncrypt hex parse failure: \(reversedKeyHex)")
            throw LyricsError.decodingError
        }

        let cipher = NeteaseBigUInt.powMod(
            base: message,
            exponent: NeteaseBigUInt(limbs: [UInt64(Self.rsaExponent)]),
            modulus: modulus
        )

        return (params, cipher.hexString(paddedTo: 256))
    }

    // MARK: - 网络

    private func performWeapi(_ path: String, params: [String: Any]) throws -> Data {
        var weapiParams = params
        weapiParams["csrf_token"] = csrfToken

        let bodyText: String
        do {
            let bodyData = try JSONSerialization.data(withJSONObject: weapiParams)
            guard let text = String(data: bodyData, encoding: .utf8) else {
                throw LyricsError.decodingError
            }
            bodyText = text
        } catch let encodingError {
            writeErrorLog("[NetEase] weapi JSONSerialization failure: \(encodingError)")
            throw LyricsError.decodingError
        }

        let (encryptedParams, encSecKey) = try weapiEncrypt(bodyText)

        let csrf = csrfToken
        guard let url = URL(string: "\(Self.weapiBaseUrl)\(path)?csrf_token=\(csrf)") else {
            writeDebugLog("[NetEase] Invalid URL for \(path), csrf=\(csrf)")
            throw LyricsError.decodingError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Origin")
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        var cookie = "os=pc"
        let savedCookie = anonymousCookie
        if !savedCookie.isEmpty {
            cookie += "; " + savedCookie
        }
        request.setValue(cookie, forHTTPHeaderField: "Cookie")

        // 手动拼 form body 并 percent-encode：不能用 URLComponents，
        // 它按 RFC 3986 不编码 query 中的 + / =，而 base64 恰好含这三个字符，
        // 会导致 + 被服务器当成空格、= 被当成键值分隔符，base64 在传输中损坏
        // （服务器解密失败 → 返回空 body）。
        let allowedQueryCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        )
        let encodedParams = encryptedParams.addingPercentEncoding(
            withAllowedCharacters: allowedQueryCharacters
        ) ?? encryptedParams
        let encodedSecKey = encSecKey.addingPercentEncoding(
            withAllowedCharacters: allowedQueryCharacters
        ) ?? encSecKey
        let bodyString = "params=\(encodedParams)&encSecKey=\(encodedSecKey)"
        request.httpBody = bodyString.data(using: .utf8)

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?
        var statusCode = 0
        var responseCookie: String?

        let task = session.dataTask(with: request) { data, response, error in
            responseData = data
            responseError = error
            if let http = response as? HTTPURLResponse {
                statusCode = http.statusCode
                if let headers = http.allHeaderFields as? [String: String] {
                    let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
                    if !cookies.isEmpty {
                        responseCookie = cookies
                            .map { "\($0.name)=\($0.value)" }
                            .joined(separator: "; ")
                    }
                }
            }
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 12) == .timedOut {
            task.cancel()
            throw LyricsError.unknownError
        }

        if let error = responseError {
            throw error
        }

        guard statusCode == 200 else {
            let body = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            writeDebugLog("[NetEase] Non-200 status \(statusCode) for \(path): \(body.prefix(200))")
            throw LyricsError.unknownError
        }

        guard let data = responseData else {
            writeDebugLog("[NetEase] Empty response data for \(path)")
            throw LyricsError.decodingError
        }

        if let cookieValue = responseCookie, !cookieValue.isEmpty {
            anonymousCookie = cookieValue
        }

        return data
    }

    /// eapi 请求：form 只有一个 params 字段（hex，无 encSecKey），
    /// 地址把 /api/ 换成 /eapi/，加密里的 url 仍用 /api/。
    private func performEapi(_ path: String, params: [String: Any]) throws -> Data {
        var eapiParams = params
        eapiParams["csrf_token"] = csrfToken

        guard let encryptedParams = eapiEncrypt(eapiParams, url: path) else {
            writeDebugLog("[NetEase] eapiEncrypt failure for \(path)")
            throw LyricsError.decodingError
        }

        let eapiPath = path.replacingOccurrences(of: "/api/", with: "/eapi/")
        let csrf = csrfToken
        guard let url = URL(string: "\(Self.weapiBaseUrl)\(eapiPath)?csrf_token=\(csrf)") else {
            writeDebugLog("[NetEase] Invalid eapi URL for \(path)")
            throw LyricsError.decodingError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Origin")
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        var cookie = "os=pc"
        let savedCookie = anonymousCookie
        if !savedCookie.isEmpty {
            cookie += "; " + savedCookie
        }
        request.setValue(cookie, forHTTPHeaderField: "Cookie")

        let bodyString = "params=\(encryptedParams)"
        request.httpBody = bodyString.data(using: .utf8)

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?
        var statusCode = 0
        var responseCookie: String?

        let task = session.dataTask(with: request) { data, response, error in
            responseData = data
            responseError = error
            if let http = response as? HTTPURLResponse {
                statusCode = http.statusCode
                if let headers = http.allHeaderFields as? [String: String] {
                    let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
                    if !cookies.isEmpty {
                        responseCookie = cookies
                            .map { "\($0.name)=\($0.value)" }
                            .joined(separator: "; ")
                    }
                }
            }
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 12) == .timedOut {
            task.cancel()
            throw LyricsError.unknownError
        }

        if let error = responseError {
            throw error
        }

        guard statusCode == 200 else {
            let body = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            writeDebugLog("[NetEase] Non-200 eapi status \(statusCode) for \(path): \(body.prefix(200))")
            throw LyricsError.unknownError
        }

        guard let data = responseData else {
            writeDebugLog("[NetEase] Empty eapi response data for \(path)")
            throw LyricsError.decodingError
        }

        if let cookieValue = responseCookie, !cookieValue.isEmpty {
            anonymousCookie = cookieValue
        }

        return data
    }

    // MARK: - 接口
    //
    // 搜索走 **cloudsearch/pc**换）。
    //
    // 旧 `/weapi/search/get` 在「被标记的出口」（机房 IP、共享住宅 IP）会返回**诱饵结果**：
    // 歌名里带一个随机数字、和查询毫无关系（实测 `告白气球 周杰伦` → `48`、`Himitsu MIMI`
    // → `29`），而 cloudsearch 在同样的出口上给的是真结果。成熟项目也都走 cloudsearch：
    // Lyricify 用 `interface.music.163.com/eapi/cloudsearch/pc`（注释写明「可以在外网使用」），
    // 163MusicLyrics 用 `weapi/cloudsearch/get/web`，并在 `abroad: true` 时解码被加密的 result。
    //
    // 字段差异：cloudsearch 用 `ar`（歌手）、`dt`（毫秒时长）、`al`（专辑）、`alia`/`tns`
    // （别名/译名）；旧的 search/get 用 `artists`/`duration`/`album`。选歌那边两种都读。
    private func searchSongs(keyword: String) throws -> [[String: Any]] {
        let data = try performWeapi("/weapi/cloudsearch/pc", params: [
            "s": keyword,
            "type": 1,
            "limit": 30,
            "offset": 0,
        ])

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            writeDebugLog("[NetEase] search response is not JSON (\(data.count) bytes): \(body.prefix(120))")
            throw LyricsError.decodingError
        }

        if let code = json["code"] as? Int, code != 200 {
            writeDebugLog("[NetEase] search returned code \(code)")
            throw LyricsError.noSuchSong
        }

        // 海外出口下 NetEase 可能把 `result` 加密成字符串（163MusicLyrics 会解码）。
        // 我们还没搬那套解码器 ⇒ 显式失败，让上层回退到别的源，而不是把密文当歌词。
        if let result = json["result"], !(result is [String: Any]) {
            writeDebugLog("[NetEase] search result is not an object (abroad-encoded?) — unsupported")
            throw LyricsError.noSuchSong
        }

        guard let result = json["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            writeDebugLog("[NetEase] search response malformed (\(data.count) bytes): \(body.prefix(120))")
            throw LyricsError.decodingError
        }

        return songs
    }

    /// 网易 `/weapi/song/lyric` 一次响应的四块文本 + 两条署名。
    ///
    /// `lyricUser` / `transUser` 是网易云回包自带的
    /// “贡献歌词的人 / 贡献翻译的人”（`nickname`）。以前只取 `lyric`，
    /// 于是页内歌词那块只能写 “NetEase”。现在把这两个名字交给
    /// `LyricsContributor`（`.uploader` / `.translator`）。
    private struct RawLyrics {
        var lrc: String?
        var tlyric: String?
        var romalrc: String?
        var lyricUser: String?
        var transUser: String?
    }

    private func fetchLyricsRaw(songId: Int) throws -> RawLyrics {
        // os/rv 两个参数控制 romalrc（官方日语罗马音）是否下发，参考 Lyricify-Lyrics-Helper。
        let data = try performWeapi("/weapi/song/lyric", params: [
            "id": songId,
            "os": "pc",
            "lv": -1,
            "kv": -1,
            "tv": -1,
            "rv": -1,
        ])

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LyricsError.decodingError
        }

        guard (json["code"] as? Int ?? 200) == 200 else {
            throw LyricsError.noSuchSong
        }

        let lrcBlock = json["lrc"] as? [String: Any]
        let tlyricBlock = json["tlyric"] as? [String: Any]
        return RawLyrics(
            lrc: lrcBlock?["lyric"] as? String,
            tlyric: tlyricBlock?["lyric"] as? String,
            romalrc: (json["romalrc"] as? [String: Any])?["lyric"] as? String,
            // （网易云感觉不展示歌词提供者/翻译提供者）：
            // 真机回包（`/weapi/song/lyric`，id 3366973885）里 `lyricUser` / `transUser`
            // 是 **lrc / tlyric 的同级字段**，不在块里面：
            // top keys = [sgc, sfy, qfy, transUser, lyricUser, lrc, klyric, tlyric, code]
            // 上一版读的是 `lrc.lyricUser` / `tlyric.transUser` ⇒ 永远 nil（署名只剩
            // "NetEase"）。现在先读顶层，再退回块内（别的版本/代理可能嵌一层）。
            lyricUser: Self.userNickname(json["lyricUser"])
                ?? Self.userNickname(lrcBlock?["lyricUser"]),
            transUser: Self.userNickname(json["transUser"])
                ?? Self.userNickname(tlyricBlock?["transUser"])
        )
    }

    /// 网易云用户节点 → 昵称（空串当没有）。
    private static func userNickname(_ raw: Any?) -> String? {
        guard let dict = raw as? [String: Any],
              let name = (dict["nickname"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    /// 回包里的两位署名 → 显示层用的 contributors（顺序：先歌词、后翻译）。
    private func contributors(from raw: RawLyrics) -> [LyricsContributor] {
        var result: [LyricsContributor] = []
        if let name = raw.lyricUser {
            result.append(LyricsContributor(role: .uploader, name: name, url: nil))
        }
        if let name = raw.transUser {
            result.append(LyricsContributor(role: .translator, name: name, url: nil))
        }
        return result
    }

    /// 逐字（yrc）走新接口 /api/song/lyric/v1（eapi 加密）；
    /// 老 weapi /weapi/song/lyric 不下发 yrc。
    /// 返回 (yrc, ytlrc)：ytlrc 是逐字歌词配套的翻译 LRC，行 offset 与 yrc 行头
    /// 一一对应（tlyric 与 lrc 同源、和 yrc 行头不是一套时间轴，无法精确对齐）。
    private func fetchYrcRaw(songId: Int) throws -> (yrc: String?, ytlrc: String?) {
        let data = try performEapi("/api/song/lyric/v1", params: [
            "id": songId,
            "cp": false,
            "tv": -1,
            "lv": -1,
            "rv": -1,
            "kv": -1,
            "yv": -1,
            "ytv": -1,
            "yrv": -1,
        ])

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LyricsError.decodingError
        }
        guard (json["code"] as? Int ?? 200) == 200 else {
            throw LyricsError.noSuchSong
        }

        let yrc = (json["yrc"] as? [String: Any])?["lyric"] as? String
        let ytlrc = (json["ytlrc"] as? [String: Any])?["lyric"] as? String
        writeDebugLog("[NetEase] eapi /api/song/lyric/v1 → yrc \(yrc == nil ? "absent" : "\(yrc!.count) chars"), ytlrc \(ytlrc == nil ? "absent" : "\(ytlrc!.count) chars")")
        if let yrc {
            writeDebugLog("[NetEase] yrc raw head: \(yrc.prefix(600))")
        }
        return (yrc, ytlrc)
    }

    private func songId(from song: [String: Any]) -> Int? {
        if let value = song["id"] as? Int { return value }
        if let value = song["id"] as? Int64 { return Int(value) }
        return nil
    }

    // MARK: - LRC 解析
    //
    // 过滤网易 LRC 里「作词 : XXX」这类歌曲制作信息行。
    private static let creditLinePattern =
        "^\\s*(作词|作曲|编曲|制作人|制作助理|混音|混音师|母带|母带工程师|录音|录音师|" +
        "监制|和声|和音|吉他|贝斯|鼓|键盘|钢琴|小提琴|大提琴|弦乐|制作|出品|发行|" +
        "配唱|统筹|企划|推广|文案|摄影|封面|导演|经纪人|" +
        "Program|Programming|Vocal|Lyrics|Composer|Arranger|Producer|" +
        "Recorded|Mixed|Mastered)\\s*[:：]"

    private func isCreditLine(_ content: String) -> Bool {
        content ~= Self.creditLinePattern
    }

    /// 是否为 ♪ 间奏行：空行，或整行只有 ♪ 符号（含多个 ♪ / 前后空白）。
    ///
    /// 两个用途：
    /// ① **丢弃**间奏行的判据 —— 把原本有的间奏全部删掉，无条件生效
    /// （见下面两处 `.filter { !isInterludeRow(...) }`）；
    /// ② 翻译错位修复时「哪一行算间奏」的判定。
    ///
    /// ⚠️它不再与任何开关有关。原先那对
    /// `shouldRemoveInterludeSymbol`（读 `ngzhwm_removeMxmInterludeSymbol`）与
    /// `cleanedInterludeSymbol`（把含 ♪ 的行清成空白）**已随开关一起删除** ——
    /// 开关开着关着结果一样，留着就是编译错与"按了没反应"的空壳。
    private func isInterludeRow(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.allSatisfy { $0 == "♪" }
    }

    /// 把 LRC 文本解析成 (offsetMs, content)，丢弃非时间戳行与制作信息行。
    /// 网易 LRC 的时间戳混用两种厘秒分隔符：[mm:ss.xx] 与 [mm:ss:xx]，
    /// 且重复段落会合并成一行多时间戳（如 [00:01.00][00:02.00]歌词），
    /// 每个时间戳都拆成独立一行，避免时间戳混进正文显示。
    private func parseLrc(_ text: String) -> [(offsetMs: Int, content: String)] {
        var parsed: [(offsetMs: Int, content: String)] = []

        let timestampPattern = "\\[(?<minute>\\d*):(?<seconds>\\d+(?:[.:]\\d+)?)\\]"
        guard let regex = try? NSRegularExpression(pattern: timestampPattern) else {
            return parsed
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let nsLine = line as NSString

            let matches = regex.matches(
                in: line,
                range: NSRange(location: 0, length: nsLine.length)
            )
            guard let lastMatch = matches.last else { continue }

            // 正文 = 最后一个时间戳之后的内容
            let lastRange = lastMatch.range
            let content = nsLine.substring(from: lastRange.location + lastRange.length)
                .trimmingCharacters(in: .whitespaces)
            guard !isCreditLine(content) else { continue }
            guard !LyricsMarkerFilter.isNonLyricLine(content) else { continue }

            // 每个时间戳拆成独立一行（相同正文、不同 offset）
            for match in matches {
                let minuteRange = match.range(withName: "minute")
                let secondsRange = match.range(withName: "seconds")
                guard minuteRange.location != NSNotFound,
                      secondsRange.location != NSNotFound else {
                    continue
                }

                guard let minute = Int(nsLine.substring(with: minuteRange)),
                      let seconds = Double(
                          nsLine.substring(with: secondsRange)
                              .replacingOccurrences(of: ":", with: ".")
                      ) else {
                    continue
                }

                // Double + rounded：Float32 会把 34.010 算成 34009.998 再截断为 34009，
                // 与 yrc 行头的精确毫秒 34010 对不上，导致逐字翻译按 offset 对齐落空。
                parsed.append((minute * 60 * 1000 + Int((seconds * 1000).rounded()), content))
            }
        }

        return parsed
    }

    /// 解析网易逐字（yrc）格式：`[起始,时长](起始,时长,标志)词(起始,时长,标志)词...`，
    /// 时间单位均为毫秒；行头第二个数字是持续时长，词括号第三个数字是标志位（忽略）。
    /// 返回 (行偏移, 行正文, 词级时间轴)。
    private func parseYrc(_ text: String) -> [(offsetMs: Int, content: String, words: [LyricsWordDto])] {
        var parsed: [(offsetMs: Int, content: String, words: [LyricsWordDto])] = []

        let linePattern = "^\\[(\\d+),(\\d+)\\]"
        let wordPattern = "\\((\\d+),(\\d+)(?:,\\d+)?\\)([^\\(]*)"

        guard let lineRegex = try? NSRegularExpression(pattern: linePattern),
              let wordRegex = try? NSRegularExpression(pattern: wordPattern) else {
            writeDebugLog("[NetEase] yrc regex compile failed")
            return parsed
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let nsLine = line as NSString

            guard
                let lineMatch = lineRegex.firstMatch(
                    in: line,
                    options: [],
                    range: NSRange(location: 0, length: nsLine.length)
                ),
                lineMatch.numberOfRanges >= 3,
                let startMs = Int(nsLine.substring(with: lineMatch.range(at: 1)))
            else {
                continue
            }

            let headerLength = lineMatch.range(at: 0).location + lineMatch.range(at: 0).length
            let rest = nsLine.substring(from: headerLength) as NSString

            var words: [LyricsWordDto] = []
            var content = ""
            let wordMatches = wordRegex.matches(
                in: rest as String,
                options: [],
                range: NSRange(location: 0, length: rest.length)
            )
            for wordMatch in wordMatches {
                guard wordMatch.numberOfRanges >= 4,
                      let wordStart = Int(rest.substring(with: wordMatch.range(at: 1))),
                      let wordDuration = Int(rest.substring(with: wordMatch.range(at: 2))) else {
                    continue
                }
                let wordText = rest.substring(with: wordMatch.range(at: 3))
                content += wordText
                words.append(
                    LyricsWordDto(text: wordText, startMs: wordStart, endMs: wordStart + wordDuration)
                )
            }

            guard !content.isEmpty else { continue }
            // 过滤制作信息行（「编曲 : TOKOTOKO」这类 yrc 行头 credit 行），
            // 与 parseLrc 的 isCreditLine 过滤保持一致；否则会出现在歌词第一行。
            guard !isCreditLine(content) else { continue }
            guard !LyricsMarkerFilter.isNonLyricLine(content) else { continue }
            parsed.append((offsetMs: startMs, content: content, words: words))
        }

        writeDebugLog("[NetEase] yrc parsed \(parsed.count) line(s)")
        return parsed
    }

    // MARK: - 翻译对齐
    //
    // tlyric 与原 lrc 按时间戳对齐；没有对应翻译的行填空串，
    // 保证翻译行数与主歌词行数一致（Spotify 按行展示翻译层）。
    private func buildTranslation(
        _ tlyric: String,
        originalLines: [LyricsLineDto]
    ) -> LyricsTranslationDto? {
        let parsed = parseLrc(tlyric)
        guard !parsed.isEmpty else { return nil }

        var translationByOffset: [Int: String] = [:]
        for entry in parsed {
            if translationByOffset[entry.offsetMs] == nil, !entry.content.isEmpty {
                translationByOffset[entry.offsetMs] = entry.content
            }
        }

        var translatedLines: [String] = []
        var matchedCount = 0

        for line in originalLines {
            guard let offset = line.offsetMs, let translated = translationByOffset[offset] else {
                translatedLines.append("")
                continue
            }
            // 翻译里 ♪ 单独作为一行的，清成空白（保持行数对齐）——
            // 原先由「删除间奏符号 ♪」开关控制，那颗开关已退役，
            // 这里与主歌词同一条纪律：**无条件**处理。
            if translated.trimmingCharacters(in: .whitespaces) == "♪" {
                translatedLines.append("")
            } else {
                translatedLines.append(translated)
            }
            matchedCount += 1
        }

        guard matchedCount > 0 else { return nil }

        // 网易 tlyric 的时间戳偶发与主歌词错位：某行歌词的翻译可能落在
        // 上一行的 ♪ 间奏行上。逐行检查：♪ 间奏行有翻译、而下一行歌词没有
        // 翻译时，把翻译下移给下一行；下一行已有翻译则保持不变。
        // 从左到右处理，连续多行间奏会自动接力下移。
        if translatedLines.count > 1 {
            for i in 0..<(translatedLines.count - 1) where isInterludeRow(originalLines[i].content) {
                let current = translatedLines[i].trimmingCharacters(in: .whitespaces)
                let next = translatedLines[i + 1].trimmingCharacters(in: .whitespaces)
                // 纯 ♪ 占位翻译不算真翻译，不搬；下一行已有翻译则保持不变。
                guard !current.isEmpty,
                      !current.allSatisfy({ $0 == "♪" }),
                      next.isEmpty else { continue }
                translatedLines[i + 1] = translatedLines[i]
                translatedLines[i] = ""
            }
        }

        let languageCode = translatedLines.romanizationLanguageCode ?? "zh"
        return LyricsTranslationDto(languageCode: languageCode, lines: translatedLines)
    }

    /// 逐字（yrc）路径的译文：**ytlrc** → 逐行译文。
    ///
    /// 两条路，按可信度排序：
    ///
    /// ① `buildTranslation` —— 按 **offset 对齐**（与行级 tlyric 完全同一条管线）。
    /// 网易 ytlrc 的行头时间戳与 yrc 行头一一对应，`parseLrc` 侧也早已为这套对齐
    /// 修过精度（见 `parseLrc` 里 "Float32 会把 34.010 算成 34009.998 … 与 yrc 行头的
    /// 精确毫秒 34010 对不上" 那段），所以这是首选路径。
    ///
    /// ② 兜底：offset 一条都没命中时（`buildTranslation` 返回 nil —— 两份文本的时间戳
    /// 不是同一套时就会这样），**按行序配对**：ytlrc 解析出来的第 i 行 → 主歌词第 i 行。
    /// 理由：这两份文本本来就是同一条流水线按同一顺序产出的，**顺序可信、时间戳不一定**；
    /// 宁可错位一格，也不要整首没有翻译（用户要的就是"逐词歌词也要有翻译"）。
    /// 配对的基准是**最终要交出去的 `originalLines`**，而不是 `yrcParsed`：
    /// 中间还隔着 `LyricsMarkerFilter` 的丢行与"删开头间奏空行"，只有对着最终数组
    /// 才能保证 `translation.lines[i]` 与 `lines[i]` 同源同行
    /// （渲染层就是按行号取译文的，见 `LyricLinesAdapter` 的 `translationLines[index]`）。
    ///
    /// 返回 nil = 这份 ytlrc 真的没有可用译文（解析不出行 / 配对后全空）。
    private func buildWordByWordTranslation(
        _ ytlrc: String,
        originalLines: [LyricsLineDto]
    ) -> LyricsTranslationDto? {
        if let aligned = buildTranslation(ytlrc, originalLines: originalLines) {
            let filled = aligned.lines.filter { !$0.isEmpty }.count
            if filled > 0 {
                writeDebugLog("[NetEase] word-by-word — translation built from ytlrc (\(filled) line(s))")
                return aligned
            }
        }

        let parsed = parseLrc(ytlrc)
        guard !parsed.isEmpty else {
            writeDebugLog("[NetEase] word-by-word — ytlrc had no usable line")
            return nil
        }

        var lines: [String] = []
        var filled = 0
        for index in originalLines.indices {
            let text = index < parsed.count ? parsed[index].content : ""
            // 与 buildTranslation 同一条 ♪ 规则：整行只有 ♪ 的译文清成空白
            // （保持行数与主歌词一致，不能把行挤掉）。
            // 不再看「删除间奏符号 ♪」开关（已退役）—— 无条件处理。
            if text.trimmingCharacters(in: .whitespaces) == "♪" {
                lines.append("")
                continue
            }
            lines.append(text)
            if !text.isEmpty { filled += 1 }
        }

        guard filled > 0 else {
            writeDebugLog("[NetEase] word-by-word — ytlrc had no usable line")
            return nil
        }
        writeDebugLog("[NetEase] word-by-word — translation paired by line index (\(filled) line(s))")
        return LyricsTranslationDto(
            languageCode: lines.romanizationLanguageCode ?? "zh",
            lines: lines
        )
    }

    // MARK: - 官方罗马音
    //
    // 用网易官方 romalrc（日语罗马音）按时间戳替换主歌词行。
    // 只有对应 offset 命中时才替换，未命中的行保留原文，返回实际替换的行数。
    private func applyRomanization(
        _ romalrc: String,
        originalLines: [LyricsLineDto]
    ) -> (lines: [LyricsLineDto], matched: Int) {
        let parsed = parseLrc(romalrc)
        guard !parsed.isEmpty else { return (originalLines, 0) }

        var romanizedByOffset: [Int: String] = [:]
        for entry in parsed {
            if romanizedByOffset[entry.offsetMs] == nil, !entry.content.isEmpty {
                romanizedByOffset[entry.offsetMs] = entry.content
            }
        }

        var out: [LyricsLineDto] = []
        var matched = 0
        for line in originalLines {
            if let offset = line.offsetMs, let roma = romanizedByOffset[offset] {
                out.append(LyricsLineDto(content: roma, offsetMs: offset))
                matched += 1
            } else {
                out.append(line)
            }
        }
        return (out, matched)
    }

    // MARK: - LyricsRepository

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        writeDebugLog("[NetEase] Fetching lyrics for \"\(query.title)\" - \(query.primaryArtist)")
        let cacheKey = String(query.hashValue)
        if let cached = lyricsCache.object(forKey: cacheKey as NSString) {
            writeDebugLog("[NetEase] Cache hit")
            // 时间轴偏移**不在这里加**了 —— 改成所有源共用的
            // `LyricsTimingOffset`，施加点统一在 `CustomLyrics.storeLyricsDto`。
            // 缓存里存的永远是**未偏移**的原始 dto，所以命中缓存也拿得到最新偏移。
            return cached.dto
        }

        // ── 搜索重做）
        //
        // ① 查询串按「标题变体」逐个试：NetEase 的搜索对文字敏感，日文名能搜到，
        // 罗马字名常常只搜到翻唱/同曲异名（实测 `Himitsu MIMI` 前 30 条里没有
        // MIMI 的《ヒミツ》，`MIMI ヒミツ` 第 2 条就是）。标题变体来自
        // `trackTitle` + metadata 的本地化 `title`（见 `CustomLyrics`）。
        // ② 候选收齐后按 标题/艺人/时长/专辑 打分，`alia`/`tns`（别名/译名）参与匹配。
        let durationToleranceMs = 5000
        let spotifyDurationMs = query.durationMs

        /// 标题变体（去重、去空白）。
        var titleVariants: [String] = []
        var seenTitles = Set<String>()
        for raw in ([query.title] + query.titleVariants) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seenTitles.insert(key).inserted else { continue }
            titleVariants.append(trimmed)
        }
        let artistVariants = query.allArtistNames

        // 查询串：每个标题各配一次主艺人；再退到「只有标题」。最多 4 条。
        var searchQueries: [String] = []
        var seenQueries = Set<String>()
        func addQuery(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            guard seenQueries.insert(key).inserted else { return }
            searchQueries.append(trimmed)
        }
        for title in titleVariants {
            addQuery("\(title) \(query.primaryArtist)")
        }
        for title in titleVariants {
            addQuery(title)
        }
        searchQueries = Array(searchQueries.prefix(4))

        // 提前收手：这条查询已经给出「标题（含别名/译名）+ 艺人 + 时长 ±2s」的候选，
        // 就不必再发下一条（每次搜索都是一次网络请求）。最终选哪条仍走下面的打分。
        func looksLikeExactMatch(_ song: [String: Any]) -> Bool {
            let wantedTitles = titleVariants.map { $0.lowercased() }
            let fragments = ([song["name"] as? String ?? ""]
                + (song["alia"] as? [String] ?? [])
                + (song["alias"] as? [String] ?? [])
                + (song["tns"] as? [String] ?? [])).map { $0.lowercased() }
            let titleHit = wantedTitles.contains { title in
                !title.isEmpty && fragments.contains { $0 == title || $0.contains(title) }
            }
            guard titleHit else { return false }

            let wantedArtists = artistVariants.map { $0.lowercased() }
            let names = ((song["ar"] as? [[String: Any]]) ?? (song["artists"] as? [[String: Any]]) ?? [])
                .compactMap { $0["name"] as? String }
                .map { $0.lowercased() }
            let artistHit = names.contains { name in
                wantedArtists.contains { !$0.isEmpty && (name == $0 || name.contains($0)) }
            }
            guard artistHit else { return false }

            if let spotify = spotifyDurationMs,
               let ms = (song["dt"] as? NSNumber)?.intValue ?? (song["duration"] as? NSNumber)?.intValue {
                return abs(ms - spotify) <= 2000
            }
            return false
        }

        // 从所有查询里收候选，按 NetEase song id 去重。
        //
        // 记下"这条候选是从**标题 + 主艺人**那条查询里出来的吗"。
        // 前 `artistQueryCount` 条查询是 `标题 + 主艺人`，后面才是只有标题
        // （见上面 `searchQueries` 的组装顺序）。后面选歌时会用这份归属，
        // 因为只有标题那条查询会带进大量同名翻唱。
        let artistQueryCount = titleVariants.count
        var artistQuerySongIDs = Set<Int>()
        var candidates: [[String: Any]] = []
        var seenSongIDs = Set<Int>()
        for (index, keyword) in searchQueries.enumerated() {
            let songs: [[String: Any]]
            do {
                songs = try searchSongs(keyword: keyword)
            } catch {
                writeDebugLog("[NetEase] search #\(index + 1) failed: \(error)")
                continue
            }
            writeDebugLog(
                "[NetEase] search #\(index + 1)/\(searchQueries.count) — \(songs.count) result(s)"
            )
            for song in songs {
                guard let id = songId(from: song) else { continue }
                guard seenSongIDs.insert(id).inserted else { continue }
                if index < artistQueryCount { artistQuerySongIDs.insert(id) }
                candidates.append(song)
            }
            if songs.contains(where: looksLikeExactMatch) { break }
        }

        guard !candidates.isEmpty else {
            writeDebugLog("[NetEase] No search results")
            throw LyricsError.noSuchSong
        }

        // ── 选歌：标题 / 艺人 / 时长 / 专辑 打分
        //
        // 历史：第一版只看第一位；第二版"时长对得上就取"（完全不看歌手），
        // 里的翻唱/伴奏全被选中；中间那版要求歌手 + 时长，但 artist 字段读错了（读 `ar`，
        // 旧 search/get 返回的是 `artists`）⇒ 闸门从未生效，只剩"第一个时长相符的"。
        //
        // 现在：字段按**两种端点都能认**的形状读（`ar`/`artists`、`dt`/`duration`），
        // 再按分数挑最高的一条；`alia`/`tns`（别名/译名）参与标题匹配 —— 罗马字标题
        // 能靠译名对上日文条目（实测 `Zankoku na Tenshi no Thesis` 的 `alia` 里就有英文名）。
        func normalized(_ raw: String) -> String {
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "（", with: "(")
                .replacingOccurrences(of: "）", with: ")")
                .replacingOccurrences(of: "’", with: "'")
                .replacingOccurrences(of: "，", with: ",")
        }

        /// 去空白与常见标点：`Himitsu (feat. X)` 与 `Himitsu(feat.X)` 视为同一串。
        func loose(_ raw: String) -> String {
            normalized(raw).filter { character in
                !character.isWhitespace
                    && character != "-"
                    && character != "'"
                    && character != "("
                    && character != ")"
                    && character != ","
                    && character != "."
                    && character != "!"
                    && character != "?"
                    && character != "&"
            }
        }

        func candidateDuration(_ song: [String: Any]) -> Int? {
            if let value = song["dt"] as? NSNumber { return value.intValue }
            if let value = song["duration"] as? NSNumber { return value.intValue }
            return nil
        }

        /// 候选的歌手（cloudsearch 是 `ar`，旧 search/get 是 `artists`），
        /// 连同各自的别名/译名（`alias` / `tns`）。
        func candidateArtistEntries(_ song: [String: Any]) -> [(name: String, aliases: [String])] {
            let list = (song["ar"] as? [[String: Any]])
                ?? (song["artists"] as? [[String: Any]])
                ?? []
            return list.map { entry in
                let name = entry["name"] as? String ?? ""
                let aliases = (entry["alias"] as? [String] ?? [])
                    + (entry["tns"] as? [String] ?? [])
                return (name, aliases)
            }
        }

        func candidateTitleFragments(_ song: [String: Any]) -> [String] {
            var out: [String] = []
            if let name = song["name"] as? String { out.append(name) }
            out += song["alia"] as? [String] ?? []
            out += song["alias"] as? [String] ?? []
            out += song["tns"] as? [String] ?? []
            return out
        }

        // ──给"同曲同歌手、但没有逐词"的候选找同名的有逐词兄弟 ──
        //
        // A 和 B 的**艺人名字和歌曲名字必须完全一样**，专辑名字不要求一样。
        // 所以这里只比较**主标题**（`name`）与**全体艺人名**的归一化结果，不用
        // `alia`/`tns` 别名（那会退回"相似但不是同一条"的坑），也不看专辑。
        // 归一化沿用上面 `normalized`（去首尾空白、小写、全半角标点统一）——
        // 「独白」和「自白」仍然不同，这正是那版被回退的原因。
        func normalizedSongName(_ song: [String: Any]) -> String {
            (song["name"] as? String).map(normalized) ?? ""
        }

        func normalizedArtistNames(_ song: [String: Any]) -> Set<String> {
            Set(
                candidateArtistEntries(song)
                    .map { normalized($0.name) }
                    .filter { !$0.isEmpty }
            )
        }

        func titleMatchScore(_ song: [String: Any]) -> Int {
            let variants = titleVariants.map { loose($0) }.filter { !$0.isEmpty }
            guard !variants.isEmpty else { return 0 }
            let fragments = candidateTitleFragments(song).map { loose($0) }.filter { !$0.isEmpty }
            guard !fragments.isEmpty else { return 0 }
            var best = 0
            for variant in variants {
                for fragment in fragments {
                    if fragment == variant {
                        best = max(best, 4)
                    } else if fragment.contains(variant) || variant.contains(fragment) {
                        best = max(best, 2)
                    }
                }
            }
            return best
        }

        func artistMatchScore(_ song: [String: Any]) -> Int {
            let wanted = artistVariants.map { $0.lowercased() }.filter { !$0.isEmpty }
            guard !wanted.isEmpty else { return 0 }
            var best = 0
            for entry in candidateArtistEntries(song) {
                for raw in ([entry.name] + entry.aliases) {
                    let name = raw.lowercased()
                    guard !name.isEmpty else { continue }
                    for other in wanted {
                        if name == other {
                            best = max(best, 3)
                        } else if name.contains(other) || other.contains(name) {
                            best = max(best, 2)
                        }
                    }
                }
            }
            return best
        }

        func durationMatchScore(_ song: [String: Any]) -> Int {
            guard let spotify = spotifyDurationMs, let ms = candidateDuration(song) else { return 0 }
            let delta = abs(ms - spotify)
            if delta <= 2000 { return 2 }
            if delta <= durationToleranceMs { return 1 }
            return 0
        }

        func albumMatchScore(_ song: [String: Any]) -> Int {
            guard let wanted = query.albumTitle.map({ loose($0) }), !wanted.isEmpty else { return 0 }
            let album = (song["al"] as? [String: Any]) ?? (song["album"] as? [String: Any])
            guard let name = album?["name"] as? String else { return 0 }
            let candidate = loose(name)
            guard !candidate.isEmpty else { return 0 }
            if candidate == wanted { return 2 }
            if candidate.contains(wanted) || wanted.contains(candidate) { return 1 }
            return 0
        }

        func passesDurationGate(_ song: [String: Any]) -> Bool {
            guard let spotify = spotifyDurationMs, let ms = candidateDuration(song) else { return true }
            return abs(ms - spotify) <= durationToleranceMs
        }

        // ──（网易云会找错很多歌）
        //
        // 四个现场（Spotify 侧是罗马字标题，网易侧是日文标题）：
        // Sakurasou / Natsunose → 桜葬；Moderate (feat. wanko) / MIMI → もでらーと；
        // Telepathy / esoragoto → テレパシー；Answer (feat. wanko) / MIMI → 解答。
        // 正确条目的标题在网易是日文，`titleMatchScore` 拿不到分；而"只有标题"那条
        // 搜索会带回一堆**同名英文翻唱**（Sakurasou / Moderate / Answer …）⇒ 标题 4 分
        // 直接压过正确条目的"艺人 + 时长"。的就是"找错歌"。
        //
        // 修法：**先按时长收窄**。Spotify 的 `trackDurationMilliseconds` 与网易同一条录音
        // 通常只差几百毫秒；如果某个候选的时长落在 ±2s 内，就只在**这些**候选里打分
        // （其中优先"标题 + 主艺人"查询出来的）。没有这种候选时才用原来的全表打分。
        // 翻唱那几条的时长都差 1.4–4.4s，自然被挡在外面；标题的跨文字优势不再能压过
        // "时长完全对上"的正确条目。
        let exactDurationToleranceMs = 2_000
        var selectionIndices = Array(candidates.indices)
        if let spotify = spotifyDurationMs {
            let exact = candidates.indices.filter { index in
                guard let ms = candidateDuration(candidates[index]) else { return false }
                return abs(ms - spotify) <= exactDurationToleranceMs
            }
            if !exact.isEmpty {
                let fromArtistQuery = exact.filter { index in
                    guard let id = songId(from: candidates[index]) else { return false }
                    return artistQuerySongIDs.contains(id)
                }
                selectionIndices = fromArtistQuery.isEmpty ? exact : fromArtistQuery
                writeDebugLog(
                    "[NetEase] pick pool narrowed to \(selectionIndices.count)/\(candidates.count)"
                        + " candidate(s) — duration within \(exactDurationToleranceMs)ms of \(spotify)ms"
                        + (fromArtistQuery.isEmpty ? "" : ", all found by the title+artist search")
                )
            }
        }

        var chosen: [String: Any]?
        var chosenIndex = -1
        var chosenScore = Int.min
        var chosenTitleScore = 0
        var chosenArtistScore = 0
        var chosenDurationScore = 0

        for index in selectionIndices {
            let song = candidates[index]
            guard passesDurationGate(song) else { continue }
            let title = titleMatchScore(song)
            let artist = artistMatchScore(song)
            let duration = durationMatchScore(song)
            let score = title * 10 + artist * 5 + duration + albumMatchScore(song) * 2
            if score > chosenScore {
                chosen = song
                chosenIndex = index
                chosenScore = score
                chosenTitleScore = title
                chosenArtistScore = artist
                chosenDurationScore = duration
            }
        }

        guard let chosen else {
            if let spotifyDurationMs {
                writeDebugLog(
                    "[NetEase] no candidate within ±\(durationToleranceMs / 1000)s of \(spotifyDurationMs)ms"
                        + " (\(candidates.count) candidate(s)) — noSuchSong"
                )
            } else {
                writeDebugLog("[NetEase] no usable candidate (\(candidates.count) candidate(s)) — noSuchSong")
            }
            throw LyricsError.noSuchSong
        }

        // ⚠️ 这个局部量**不能**叫 `songId`：它会遮蔽方法 `songId(from:)`，之后任何
        // `songId(from: …)` 都会被解析成这个 Int ——真机编译错误
        // `cannot call value of non-function type 'Int'` 就是这么来的。
        guard let chosenSongId = songId(from: chosen) else {
            writeDebugLog("[NetEase] Chosen result has no song id")
            throw LyricsError.noSuchSong
        }

        let chosenArtists = candidateArtistEntries(chosen).map { $0.name }.joined(separator: " / ")
        let chosenDuration = candidateDuration(chosen).map { "\($0)ms" } ?? "?"
        // 末尾的 `(id …)` 留给导出层的脱敏规则（`DebugLogSanitizer.redactForSharing`
        // 第 4 条会把 “Chosen[i]: … (id N)” 整段换成 `<title> (id <redacted>)`）。
        writeDebugLog(
            "[NetEase] Chosen[\(chosenIndex)]: \(chosen["name"] as? String ?? "?")"
                + " — \(chosenArtists.isEmpty ? "?" : chosenArtists)"
                + " \(chosenDuration)"
                + " (ours: \(query.primaryArtist) \(spotifyDurationMs.map { "\($0)ms" } ?? "?"))"
                + " (id \(chosenSongId))"
        )
        writeDebugLog(
            "[NetEase] pick score — title \(chosenTitleScore), artist \(chosenArtistScore),"
                + " duration \(chosenDurationScore), total \(chosenScore)"
                + " (\(candidates.count) candidate(s), \(searchQueries.count) query/queries)"
        )

        let rawLyrics: RawLyrics
        do {
            rawLyrics = try fetchLyricsRaw(songId: chosenSongId)
        } catch {
            writeDebugLog("[NetEase] Fetch lyrics error: \(error)")
            throw error
        }

        // 网易「纯音乐，请欣赏」= 这首歌是纯音乐（可信分类）：直接返回纯音乐占位。
        if let lrc = rawLyrics.lrc, lrc.contains("纯音乐") {
            writeDebugLog("[NetEase] Instrumental — returning empty lyrics")
            var dto = LyricsDto(lines: [], timeSynced: false, romanization: .original)
            // **把"源说过这是纯音乐"记在 dto 上** —— 听歌页那层据此写
            // 「此歌曲为纯音乐。」而不是「未找到歌词」（两者数据都是空行，只有这个字段能区分）。
            dto.isInstrumental = true
            lyricsCache.setObject(CachedLyrics(dto: dto), forKey: cacheKey as NSString)
            return dto
        }

        // 不把上游「空歌词 → 纯音乐占位」的 bug 带过来：没有可用歌词就抛查无此歌。
        guard let lrc = rawLyrics.lrc, !lrc.isEmpty else {
            writeDebugLog("[NetEase] No usable lyrics")
            throw LyricsError.noSuchSong
        }

            var lines: [LyricsLineDto]
            var timeSynced = true

            // 逐字歌词：开关开启且网易下发 yrc 时，优先用词级（逐字）时间轴；
            // yrc 缺失/解析为空时回退到 lrc 行级时间轴（下面原逻辑不变）。
            let preferWordByWord = NgzhwmSettingsViewModel.isWordByWordLyricsEnabled
            // yrc 与 **ytlrc** 必须从同一次 eapi 响应里一起取出（元组解构）。
            //
            // 以前这里写的是 `yrcText = try fetchYrcRaw(songId: songId).yrc` —— 取 `.yrc`
            // 这一个成员就等于把元组里的 `ytlrc` 当场丢掉。而 ytlrc 是逐字歌词配套的
            // 翻译（`fetchYrcRaw` 自己那行日志 `yrc … chars, ytlrc … chars` 就写着它一直在
            // 下发），丢了它，下面的逐字分支就永远没有译文可取 ——
            // 当返回逐词歌词的时候，不展示歌词翻译。
            // `[NPVLyrics] expanded … translation 0/29` 成对出现，就是这条路径。
            // ⚠️ **不能**为了拿 ytlrc 再调一次 `fetchYrcRaw`：那是一次额外的网络请求。
            var yrcText: String? = nil
            var ytlrcText: String? = nil
            var yrcParsed: [(offsetMs: Int, content: String, words: [LyricsWordDto])] = []

            // 逐词开启时，yrc 有两种"不可用"要分开处理：
            //
            // ① **残 yrc**：选中的条目有 yrc，但正文缺字（现场「ただ声一つ —
            // Rokudenashi」：yrc 123 字 vs lrc 357 字；ytlrc 只有 55 字符 ⇒
            // "歌词缺少 + 翻译不见"）。判据：yrc 正文 < lrc 正文的 90%。
            // 这种 yrc 一律丢掉，先保证正文与翻译正确（走 lrc + tlyric）。
            // ② **没有 yrc**：的规则 —— 找**同名同艺人**（专辑不比）
            // 的兄弟条目用它的 yrc/ytlrc；时长夹 ±5s。
            //
            // ⚠️ 残 yrc 还有一条**修复**路径（阶段 B）：同名 + 时长差 ≤2s，且兄弟的
            // yrc 正文同样覆盖 lrc ≥90% ⇒ 采用。这一档**不要求艺人名相同**：
            // 正文覆盖已经证明是同一份词，而"Rokudenashi"与"ロクデナシ"本来就是
            // 同一个艺人的罗马字/日文写法（报的现场）。
            // 没有覆盖率这道门就不会用 —— 那正是那版被回退的原因。
            if preferWordByWord {
                var yrcRaw: (yrc: String?, ytlrc: String?)? = nil
                do {
                    yrcRaw = try fetchYrcRaw(songId: chosenSongId)
                } catch {
                    writeDebugLog("[NetEase] yrc (eapi) fetch failed: \(error)")
                }
                yrcParsed = parseYrc(yrcRaw?.yrc ?? "")

                let lrcBody = parseLrc(lrc).map(\.content).joined()
                /// yrc 正文至少要有 lrc 的 90%（lrc 太短就不比）。
                func yrcCoversTheLrc(
                    _ candidate: [(offsetMs: Int, content: String, words: [LyricsWordDto])]
                ) -> Bool {
                    guard !candidate.isEmpty else { return false }
                    guard lrcBody.count >= 40 else { return true }
                    let body = candidate.map(\.content).joined()
                    return body.count >= Int(Double(lrcBody.count) * 0.9)
                }

                // ① 残 yrc ⇒ 丢掉，当作"没有可用 yrc"。
                if !yrcParsed.isEmpty, !yrcCoversTheLrc(yrcParsed) {
                    writeDebugLog(
                        "[NetEase] yrc looks truncated — \(yrcParsed.map(\.content).joined().count)"
                            + " char(s) vs lrc \(lrcBody.count) char(s); dropping it"
                    )
                    yrcParsed = []
                    yrcRaw = nil
                }

                // ② 没有可用 yrc ⇒ 找兄弟条目。
                if yrcParsed.isEmpty {
                    let chosenName = normalizedSongName(chosen)
                    let chosenArtists = normalizedArtistNames(chosen)
                    let referenceDuration = candidateDuration(chosen) ?? spotifyDurationMs
                    var probedStrict = 0
                    var probedRepair = 0

                    if chosenName.isEmpty {
                        writeDebugLog("[NetEase] chosen entry has no comparable title — not probing siblings")
                    } else {
                        // 阶段 A（用户规则）：同名 + 同艺人。
                        if !chosenArtists.isEmpty {
                            for song in candidates {
                                guard probedStrict < 2 else { break }
                                guard let altId = songId(from: song), altId != chosenSongId else { continue }
                                guard normalizedSongName(song) == chosenName,
                                      normalizedArtistNames(song) == chosenArtists else { continue }
                                if let reference = referenceDuration,
                                   let ms = candidateDuration(song),
                                   abs(ms - reference) > durationToleranceMs {
                                    continue
                                }
                                probedStrict += 1
                                guard let alt = try? fetchYrcRaw(songId: altId) else {
                                    // （`DebugLogSanitizer`）认这个形状，会换成 `<redacted>`。
                                    writeDebugLog("[NetEase] same-name sibling (id \(altId)) — yrc fetch failed")
                                    continue
                                }
                                let altParsed = parseYrc(alt.yrc ?? "")
                                guard !altParsed.isEmpty, yrcCoversTheLrc(altParsed) else {
                                    writeDebugLog("[NetEase] same-name sibling (id \(altId)) — no usable yrc")
                                    continue
                                }
                                yrcRaw = alt
                                writeDebugLog(
                                    "[NetEase] adopted a same-name sibling's yrc (id \(altId)),"
                                        + " \(altParsed.count) line(s); the chosen entry had none"
                                )
                                break
                            }
                        }

                        // 阶段 B（修复残 yrc）：同名 + 时长差 ≤2s + 兄弟 yrc 覆盖 lrc。
                        // 不要求艺人名相同（理由见上面那段）；严格同名的条目在阶段 A 已经探过。
                        if yrcRaw == nil, let reference = referenceDuration {
                            for song in candidates {
                                guard probedRepair < 3 else { break }
                                guard let altId = songId(from: song), altId != chosenSongId else { continue }
                                guard normalizedSongName(song) == chosenName else { continue }
                                guard let ms = candidateDuration(song),
                                      abs(ms - reference) <= 2_000 else { continue }
                                if normalizedArtistNames(song) == chosenArtists { continue }
                                probedRepair += 1
                                guard let alt = try? fetchYrcRaw(songId: altId) else { continue }
                                let altParsed = parseYrc(alt.yrc ?? "")
                                guard !altParsed.isEmpty, yrcCoversTheLrc(altParsed) else {
                                    writeDebugLog("[NetEase] repair sibling (id \(altId)) — no usable yrc")
                                    continue
                                }
                                yrcRaw = alt
                                writeDebugLog(
                                    "[NetEase] adopted a verified same-title sibling's yrc (id \(altId)),"
                                        + " \(altParsed.count) line(s); the chosen entry's yrc was unusable"
                                )
                                break
                            }
                        }

                        if yrcRaw == nil, probedStrict == 0, probedRepair == 0 {
                            writeDebugLog(
                                "[NetEase] no usable yrc and no sibling to probe"
                                    + " (\(candidates.count) candidate(s))"
                            )
                        }
                    }
                }

                yrcText = yrcRaw?.yrc
                ytlrcText = yrcRaw?.ytlrc
                if let finalYrc = yrcText {
                    yrcParsed = parseYrc(finalYrc)
                }
            }

            if !yrcParsed.isEmpty {
                writeDebugLog("[NetEase] Word-by-word (yrc) lyrics — \(yrcParsed.count) line(s)")
                // `LyricsMarkerFilter.isNonLyricLine` = 与其他源共用的"结构标注行"过滤器。
                // 网易的 `<Music>` 间奏标记就靠它拦掉。判为标注行的**丢掉整行**，
                // 而不是留个空行 —— 空行在 AM 渲染层里会占一行高度，看着像"漏了一句"。
                lines = yrcParsed
                    // （把**原本有的间奏全部删掉**）：♪ / `<Music>` 那类
                    // **整行丢掉**，而不是"清成空白、保留位置"。
                    // 判据用现成的 `isInterludeRow`（空行、或整行只有 ♪，含多个 ♪ 与前后空白）。
                    //
                    // 为什么丢掉是对的：**间奏不该由一行文字表达** —— AM 那边是三个呼吸点，
                    // 而"这一行到下一行之间有多久没词"这件事，`LyricInterludeTimeline` 是**按
                    // 时间间隙**推出来的（Melox 的检测逻辑），不靠一个占位行 ✓。
                    // 留空行反而有害：AM 渲染层里空行照样占一行高度，看着像漏了一句。
                    .filter { !isInterludeRow($0.content.lyricsNoteIfEmpty) }
                    .map {
                        LyricsLineDto(
                            content: $0.content.lyricsNoteIfEmpty,
                            offsetMs: $0.offsetMs,
                            words: $0.words
                        )
                    }
                    .filter { !LyricsMarkerFilter.isNonLyricLine($0.content) }
            } else {
                if preferWordByWord {
                    writeDebugLog("[NetEase] yrc unavailable — falling back to line-synced (lrc)")
                }
                let parsed = parseLrc(lrc)
                if parsed.isEmpty {
                    // 网易部分歌只有静态歌词（无 [mm:ss] 时间戳、没做滚动歌词）：
                    // 按行拆分、过滤制作信息行与空行，作为非同步歌词收录传给上游。
                    // 先剥掉行首残留时间戳（如 [00:00.00-1]，parseLrc 解析不出），
                    // 否则「作曲 : xxx」这类制作信息会被误当成歌词收录。
                    var fallbackLines: [LyricsLineDto] = []
                    for rawLine in lrc.components(separatedBy: .newlines) {
                        let content = rawLine.trimmingCharacters(in: .whitespaces)
                        guard !content.isEmpty else { continue }
                        let stripped = content.replacingOccurrences(
                            of: "^\\s*\\[[^\\]]*\\]\\s*",
                            with: "",
                            options: .regularExpression
                        ).trimmingCharacters(in: .whitespaces)
                        guard !stripped.isEmpty, !isCreditLine(stripped),
                              !LyricsMarkerFilter.isNonLyricLine(stripped) else { continue }
                        // 合并式制作信息（如「作词/作曲 : xxx」）isCreditLine 匹配不到，单独兜住：
                        // 以制作关键词开头且后面带冒号，视为制作信息，不收录。
                        let creditKeywords = ["作词", "作曲", "编曲", "混音", "混音师", "母带",
                                              "录音", "录音师", "制作", "出品", "发行", "监制",
                                              "和声", "配唱", "统筹", "企划", "推广", "文案",
                                              "摄影", "封面", "导演", "经纪人"]
                        if creditKeywords.contains(where: { stripped.hasPrefix($0) }),
                           stripped.contains(":") || stripped.contains("：") {
                            continue
                        }
                        fallbackLines.append(LyricsLineDto(content: content, offsetMs: nil))
                    }
                    guard !fallbackLines.isEmpty else {
                        writeDebugLog("[NetEase] No usable lyrics")
                        throw LyricsError.noSuchSong
                    }
                    lines = fallbackLines
                    timeSynced = false
                    writeDebugLog("[NetEase] Unsynced lyrics fallback (\(lines.count) line(s))")
                } else {
                    lines = parsed
                        // 与逐字那条路同一条纪律 —— 间奏行**整行丢掉**
                        // （见上面那段说明：间奏交给三个呼吸点与时间间隙，不交给一行文字）。
                        .filter { !isInterludeRow($0.content.lyricsNoteIfEmpty) }
                        .map {
                            LyricsLineDto(
                                content: $0.content.lyricsNoteIfEmpty,
                                offsetMs: $0.offsetMs
                            )
                        }
                        .filter { !LyricsMarkerFilter.isNonLyricLine($0.content) }
                }
            }

        // **无条件**删掉开头的空行 —— 间奏行已经在上面被整行剔掉了，
        // 这里兜的是"其他源形态留下的空头"（静态歌词路径会把空行原样收进来）。
        // 旧版这颗由「删除间奏符号 ♪」开关控制；那颗开关现在无论开还是关都不该再影响结果
        // （A：间奏一律删掉），所以这一句不再看它。
        lines = Array(lines.drop(while: { $0.content.isEmpty }))

        // 网易云翻译只有简体中文。开启「不展示网易云歌词翻译」开关时，
        // 跳过翻译层构建，不把简体中文翻译交给上游（不影响中日韩罗马化）。
        var translation: LyricsTranslationDto? = nil
        let hideNetEaseTranslation = NgzhwmSettingsViewModel.isNeteaseHideTranslationEnabled
        if hideNetEaseTranslation {
            writeDebugLog("[NetEase] Hide translation enabled — skipping translation layer")
        } else if !yrcParsed.isEmpty {
            // 「当返回逐词歌词的时候，不展示歌词翻译」。
            //
            // 逐字路径的译文来自 **ytlrc**（与 yrc 同一次 eapi 下发、行头一一对应），
            // 不是 `raw.tlyric` —— 后者与行级 lrc 同源，和 yrc 行头不是一套时间轴。
            // 这里以前只有一句 `[NetEase] word-by-word — skipping translation layer`
            // 就结束了：从不给 `translation` 赋值，于是逐字歌永远没有翻译层
            if let ytlrc = ytlrcText, !ytlrc.isEmpty {
                translation = buildWordByWordTranslation(ytlrc, originalLines: lines)
            } else {
                // ytlrc 真的没下发（`fetchYrcRaw` 的日志会写着 `ytlrc absent`）——
                // 这种情况下确实没有译文可用，如实记账，不再假装"逐字歌词不显示翻译"。
                writeDebugLog("[NetEase] word-by-word — ytlrc absent")
            }
        } else if let tlyric = rawLyrics.tlyric, !tlyric.isEmpty {
            translation = buildTranslation(tlyric, originalLines: lines)
        }

        let contents = lines.map(\.content)
        var romanization: LyricsRomanizationStatus = contents.canBeRomanized
            ? .canBeRomanized : .original
        let languageCode = contents.romanizationLanguageCode

        // 官方罗马音：日语歌、用户开启日语罗马化、且网易下发了 romalrc 时，
        // 直接用官方罗马音替换主歌词行（标记 .romanized 跳过本地转换）。
        // 若开启「修改 NetEase 日语罗马字展示方式」开关，则跳过官方罗马音，
        // 保持原文 + .canBeRomanized，把所有日语行统一交给显示层本地罗马化。
        // 未命中上述条件时同样保持原文 + .canBeRomanized，交给显示层本地转换。
        let preferLocalRomaji = UserDefaults.standard.bool(
            forKey: NgzhwmSettingsViewModel.neteaseRomajiLocalKey
        )
        if preferLocalRomaji,
           languageCode == "ja",
           UserDefaults.standard.bool(forKey: "ngzhwm_japaneseRomanization") {
            writeDebugLog("[NetEase] Local romaji display enabled — skipping official romaji")
        }

        // 逐字歌词（preferWordByWord 且拿到 yrc）时跳过官方罗马音 + 本地兜底：
        // 这两步会把 yrc 的 words 词级时间轴丢掉、且产出小写罗马字；
        // 改为保持原文 + .canBeRomanized，交给显示层 romanizedForWordByWordIfEnabled
        // （罗马化 + 首词大写 + 词级对齐）与原生 romanizeLine 处理。
        let usingWordByWord = preferWordByWord && !yrcParsed.isEmpty
        if usingWordByWord {
            writeDebugLog("[NetEase] word-by-word path — skipping repo-side romaji (defer to display layer)")
        }

        // **官方罗马音也不再替换正文。**
        //
        // 「开启歌词内的日语歌词罗马化后，是直接把原日文替换了，不是在原文的上面
        // 展示罗马字」，并选了"原生那页也回到日文原文，罗马字只由我们这层画"。
        //
        // 这一段以前是把 `lines[i].content` **换成**官方 `romalrc`（并顺带把残留日文的行
        // 用本地转换补齐），于是屏幕上**日文原文整个没了** —— 正是用户报的那件事，
        // 只是走的是另一条路（逐字 yrc 那条已经在 `storeLyricsDto` / `toSpotifyLyricsData` 改掉）。
        //
        // 现在：官方那份**留着**（它质量比本地转换好），但存进 `officialRomanizedLines`
        // —— 显示层把它当"原文**上方**那一行"（`LyricLinesAdapter.romanizedContentsForDisplay`
        // 首选它，缺的行再退回本地转换）。正文一个字都不动。
        //
        // ⚠️ 「修改 NetEase 日语罗马字展示方式」那个开关（`preferLocalRomaji`）**语义不变**：
        // 它仍然是"宁可要本地那份、也不用官方那份"—— 打开时这里就不存官方罗马字。
        var officialRomanizedLines: [String] = []
        if let romalrc = rawLyrics.romalrc, !romalrc.isEmpty,
           languageCode == "ja",
           UserDefaults.standard.bool(forKey: "ngzhwm_japaneseRomanization"),
           !preferLocalRomaji,
           !usingWordByWord {
            let romanized = applyRomanization(romalrc, originalLines: lines)
            if romanized.matched > 0 {
                // 与 `lines` **同序同长**：没命中的行留空（显示层会退回本地转换）。
                officialRomanizedLines = romanized.lines.enumerated().map { index, line -> String in
                    guard index < lines.count, lines[index].content != line.content else { return "" }
                    return line.content
                }
                writeDebugLog(
                    "[NetEase] official romaji kept for the line above"
                        + " (\(romanized.matched) line(s)) — the lyrics text stays as-is"
                )
            }
        }

        var dto = LyricsDto(
            lines: lines,
            timeSynced: timeSynced,
            romanization: romanization,
            translation: translation,
            languageCode: languageCode,
            officialRomanizedLines: officialRomanizedLines
        )
        // 把网易云回包里的"贡献歌词 / 贡献翻译"带给显示层
        // （页内歌词署名第二行、自绘歌词页页脚）。
        dto.providerContributors = contributors(from: rawLyrics)
        writeDebugLog(
            "[NetEase] credits — lyricUser=\(rawLyrics.lyricUser ?? "nil"),"
                + " transUser=\(rawLyrics.transUser ?? "nil")"
                + " → \(dto.providerContributors.count) contributor(s)"
        )

        writeDebugLog("[NetEase] Synced lyrics — \(lines.count) line(s)")
        // 缓存**原始** dto：时间轴偏移统一在 `CustomLyrics.storeLyricsDto` 加
        // （见 `LyricsTimingOffset`），这里不再碰时间戳。
        lyricsCache.setObject(CachedLyrics(dto: dto), forKey: cacheKey as NSString)
        return dto
    }
}

// MARK: - Japanese Script Detection

private extension String {
    /// 是否仍含日文假名/汉字（用于判定官方罗马音是否完整、需要本地兜底）。
    var containsJapaneseScriptForRomajiFallback: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, // 平假名 + 片假名
                 0x31F0...0x31FF, // 片假名拼音扩展
                 0xFF66...0xFF9D, // 半角片假名
                 0x3400...0x4DBF, // CJK 扩展 A
                 0x4E00...0x9FFF, // CJK 统一表意文字
                 0xF900...0xFAFF: // CJK 兼容表意文字
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - NeteaseBigUInt
//
// 仅为 weapi 的 encSecKey 服务的最小无符号大整数（小端 limbs）：
// 模数是固定 1024 位、指数 65537，因此只需 乘法 / 减法 / 比较 /
// 二进制长除法取模 / 平方-乘模幂。加密对象只有 16 字节，远小于模数，
// 与网易前端 BigInt.powMod 的 raw RSA（无填充）完全等价。

private struct NeteaseBigUInt {

    var limbs: [UInt64] // little-endian，恒无前导零 limb

    static let zero = NeteaseBigUInt(limbs: [0])

    init(limbs: [UInt64]) {
        var trimmed = limbs
        while trimmed.count > 1, trimmed.last == 0 {
            trimmed.removeLast()
        }
        self.limbs = trimmed
    }

    init?(hex: String) {
        var limbs: [UInt64] = [0]
        for character in hex {
            guard let digit = character.hexDigitValue else { return nil }
            // limbs = limbs << 4 | digit
            var carry = UInt64(digit)
            for i in 0..<limbs.count {
                let shifted = limbs[i] << 4
                let sum = shifted &+ carry
                carry = (limbs[i] >> 60) &+ (sum < shifted ? 1 : 0)
                limbs[i] = sum
            }
            if carry != 0 {
                limbs.append(carry)
            }
        }
        self.init(limbs: limbs)
    }

    var isZero: Bool {
        limbs.allSatisfy { $0 == 0 }
    }

    var bitWidth: Int {
        guard let top = limbs.lastIndex(where: { $0 != 0 }) else { return 0 }
        return top * 64 + (64 - limbs[top].leadingZeroBitCount)
    }

    func bit(at index: Int) -> UInt64 {
        let word = index / 64
        guard word < limbs.count else { return 0 }
        return (limbs[word] >> UInt64(index % 64)) & 1
    }

    func shiftedLeftOneBit(insertingBit bit: UInt64) -> NeteaseBigUInt {
        guard !limbs.isEmpty else { return NeteaseBigUInt(limbs: [bit & 1]) }
        var out = [UInt64](repeating: 0, count: limbs.count + 1)
        var carry = bit & 1
        for i in 0..<limbs.count {
            out[i] = (limbs[i] << 1) | carry
            carry = limbs[i] >> 63
        }
        out[limbs.count] = carry
        return NeteaseBigUInt(limbs: out)
    }

    func shiftedRightOneBit() -> NeteaseBigUInt {
        var out = [UInt64](repeating: 0, count: limbs.count)
        var carry: UInt64 = 0
        for i in stride(from: limbs.count - 1, through: 0, by: -1) {
            let nextCarry = limbs[i] & 1
            out[i] = (limbs[i] >> 1) | (carry << 63)
            carry = nextCarry
        }
        return NeteaseBigUInt(limbs: out)
    }

    func hexString(paddedTo digits: Int) -> String {
        var result = ""
        var started = false
        for limb in limbs.reversed() {
            let hex = String(limb, radix: 16)
            if !started {
                if limb != 0 {
                    result += hex
                    started = true
                }
            } else {
                result += String(repeating: "0", count: 16 - hex.count) + hex
            }
        }
        if result.isEmpty { result = "0" }
        while result.count < digits {
            result = "0" + result
        }
        return result
    }

    static func < (lhs: NeteaseBigUInt, rhs: NeteaseBigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count
        }
        var i = lhs.limbs.count - 1
        while i >= 0 {
            if lhs.limbs[i] != rhs.limbs[i] {
                return lhs.limbs[i] < rhs.limbs[i]
            }
            i -= 1
        }
        return false
    }

    /// 假定 lhs >= rhs。
    static func - (lhs: NeteaseBigUInt, rhs: NeteaseBigUInt) -> NeteaseBigUInt {
        var out = [UInt64](repeating: 0, count: lhs.limbs.count)
        var borrow: UInt64 = 0
        for i in 0..<lhs.limbs.count {
            let r = i < rhs.limbs.count ? rhs.limbs[i] : 0
            let (d1, b1) = lhs.limbs[i].subtractingReportingOverflow(r)
            let (d2, b2) = d1.subtractingReportingOverflow(borrow)
            out[i] = d2
            borrow = (b1 ? 1 : 0) &+ (b2 ? 1 : 0)
        }
        return NeteaseBigUInt(limbs: out)
    }

    static func * (lhs: NeteaseBigUInt, rhs: NeteaseBigUInt) -> NeteaseBigUInt {
        if lhs.isZero || rhs.isZero { return .zero }

        let m = lhs.limbs.count
        let n = rhs.limbs.count
        var result = [UInt64](repeating: 0, count: m + n)

        for i in 0..<m {
            let a = lhs.limbs[i]
            if a == 0 { continue }

            var carry: UInt64 = 0
            // carry 溢出 2^64 的部分（0 或 1），作为下一轮的额外进位。
            var carryHigh: UInt64 = 0

            for j in 0..<n {
                let (hi, lo) = a.multipliedFullWidth(by: rhs.limbs[j])
                let idx = i + j

                let t1 = result[idx] &+ lo
                let c1: UInt64 = t1 < result[idx] ? 1 : 0
                let t2 = t1 &+ carry
                let c2: UInt64 = t2 < t1 ? 1 : 0
                result[idx] = t2

                let (h1, o1) = hi.addingReportingOverflow(c1)
                let (h2, o2) = h1.addingReportingOverflow(c2)
                let (h3, o3) = h2.addingReportingOverflow(carryHigh)
                carry = h3
                carryHigh = (o1 || o2 || o3) ? 1 : 0
            }

            var idx = i + n
            while carry != 0 || carryHigh != 0 {
                if idx >= result.count { result.append(0) }
                let t1 = result[idx] &+ carry
                let c1: UInt64 = t1 < result[idx] ? 1 : 0
                result[idx] = t1
                let (h, o) = c1.addingReportingOverflow(carryHigh)
                carry = h
                carryHigh = o ? 1 : 0
                idx += 1
            }
        }

        return NeteaseBigUInt(limbs: result)
    }

    static func % (lhs: NeteaseBigUInt, rhs: NeteaseBigUInt) -> NeteaseBigUInt {
        if rhs.isZero { return lhs }
        if lhs < rhs { return lhs }

        // 二进制长除法：1024 位被除数约 2048 位，循环次数固定且有限。
        var remainder = NeteaseBigUInt.zero
        var i = lhs.bitWidth - 1
        while i >= 0 {
            remainder = remainder.shiftedLeftOneBit(insertingBit: lhs.bit(at: i))
            if !(remainder < rhs) {
                remainder = remainder - rhs
            }
            i -= 1
        }
        return remainder
    }

    static func powMod(
        base: NeteaseBigUInt,
        exponent: NeteaseBigUInt,
        modulus: NeteaseBigUInt
    ) -> NeteaseBigUInt {
        if modulus.isZero {
            return NeteaseBigUInt(limbs: [1])
        }

        var result = NeteaseBigUInt(limbs: [1])
        var b = base % modulus
        var e = exponent

        while !e.isZero {
            if e.bit(at: 0) == 1 {
                result = (result * b) % modulus
            }
            b = (b * b) % modulus
            e = e.shiftedRightOneBit()
        }

        return result
    }
}
