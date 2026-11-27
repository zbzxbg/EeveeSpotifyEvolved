import Foundation

/// Canvas 的**第二条路**：`canvas.url` 不在 track metadata 里时，直接问 Spotify 的
/// `canvaz-cache` 服务。
///
/// 为什么需要：metadata 那条路依赖播放核心把 `canvas.url` 填进来（账号属性
/// `canvas-disabled=false` + 对应的 flag / 取词节奏），有些会话里它干脆是空的。
/// Taurus 的做法就是"先读 metadata，拿不到再用账号 token 查一次 canvaz-cache" ——
/// 这里按同一思路实现，protobuf 的字段号来自公开的 Canvas 抓取实现（见文件底部的
/// 请求/响应结构）。
///
/// 只在锁屏要一条短片、而 metadata 没给 `canvas.url` 时调用；出错（401/404/超时）
/// 一律返回 nil，让上层继续走 Apple Music / 本地 Fill。
enum SpotifyCanvasCache {

    private static let endpoint = URL(
        string: "https://spclient.wg.spotify.com/canvaz-cache/v0/canvases"
    )!

    /// 与其它目录请求共用一个上限：单次最多 4 秒，别把锁屏那 30 秒预算吃掉。
    private static let requestTimeout: TimeInterval = 4
    private static var didReportMissingToken = false

    static func asset(
        trackURI: String,
        session: URLSession,
        deadline: Date
    ) async -> AnimatedArtworkAsset? {
        guard trackURI.hasPrefix("spotify:track:") else { return nil }
        guard Date() < deadline else { return nil }

        guard let token = spotifyAccessTokenSnapshot(), !token.isEmpty else {
            if !didReportMissingToken {
                didReportMissingToken = true
                writeDebugLog(
                    "[\(LockScreenArtwork.logTag)] canvas cache skipped — no Spotify access token"
                )
            }
            return nil
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = max(0.5, min(requestTimeout, deadline.timeIntervalSinceNow))
        request.httpBody = requestBody(trackURI: trackURI)
        request.setValue("application/protobuf", forHTTPHeaderField: "Accept")
        // 公开实现里这个端点收的是 protobuf 正文，但 Content-Type 就是
        // `application/x-www-form-urlencoded`；别"顺手改成 application/protobuf"。
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue(
            "Spotify/8.5.49 iOS/Version 13.3.1 (Build 17D50)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let status: Int
        do {
            let (body, response) = try await session.data(for: request)
            data = body
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            writeDebugLog(
                "[\(LockScreenArtwork.logTag)] canvas cache failed —"
                    + " \(error.localizedDescription)"
            )
            return nil
        }

        guard (200..<300).contains(status) else {
            writeDebugLog(
                "[\(LockScreenArtwork.logTag)] canvas cache HTTP \(status)"
                    + " — keeping the metadata / Apple Music / Fill order"
            )
            return nil
        }
        guard Date() < deadline else { return nil }

        guard let raw = canvasURL(trackURI: trackURI, in: data),
              let url = URL(string: raw),
              url.pathExtension.lowercased() == "mp4" || raw.contains(".mp4") else {
            writeDebugLog(
                "[\(LockScreenArtwork.logTag)] canvas cache —"
                    + " no playable .mp4 at track \(trackURI)"
            )
            return nil
        }

        writeDebugLog(
            "[\(LockScreenArtwork.logTag)] canvas cache — hit, \(data.count) byte(s)"
        )
        return AnimatedArtworkAsset(source: .canvas, videoURL: url, isHLS: false)
    }

    // MARK: - 请求体（手写最小 protobuf）

    /// `CanvasRequest { repeated Track tracks = 1; }` / `Track { string track_uri = 1; }`
    private static func requestBody(trackURI: String) -> Data {
        let uri = Array(trackURI.utf8)
        let track = lengthDelimited(field: 1, payload: uri)
        let body = lengthDelimited(field: 1, payload: track)
        return Data(body)
    }

    // MARK: - 响应体
    //
    // `CanvasResponse { repeated Canvas canvases = 1; }`
    // `Canvas { id = 1; canvas_url = 2; track_uri = 5; artist = 6; … }`
    // 字段号来自公开的 `_canvas.proto` 生成的代码；只取 `canvas_url` 与 `track_uri`。

    private static func canvasURL(trackURI: String, in data: Data) -> String? {
        let bytes = [UInt8](data)
        var index = 0
        var first: String?

        while let tag = readTag(bytes, &index) {
            if tag.field == 1, tag.wire == 2 {
                guard let payload = readDelimited(bytes, &index) else { return nil }
                if let canvas = parseCanvas(payload) {
                    if canvas.uri == trackURI { return canvas.url }
                    if first == nil { first = canvas.url }
                }
            } else if !skip(bytes, &index, tag) {
                return nil
            }
        }

        // 只请求了一首；万一响应里的 track_uri 没填，单条结果就是它的。
        return first
    }

    private static func parseCanvas(_ bytes: [UInt8]) -> (uri: String, url: String)? {
        var index = 0
        var uri: String?
        var url: String?

        while let tag = readTag(bytes, &index) {
            switch (tag.field, tag.wire) {
            case (2, 2):
                if let payload = readDelimited(bytes, &index),
                   let value = String(bytes: payload, encoding: .utf8) {
                    url = value
                }
            case (5, 2):
                if let payload = readDelimited(bytes, &index),
                   let value = String(bytes: payload, encoding: .utf8) {
                    uri = value
                }
            default:
                if !skip(bytes, &index, tag) { return nil }
            }
        }

        guard let uri, let url, !url.isEmpty else { return nil }
        return (uri, url)
    }

    // MARK: - 最小 protobuf 读写

    private struct Tag {
        let field: Int
        let wire: Int
    }

    private static func lengthDelimited(field: Int, payload: [UInt8]) -> [UInt8] {
        var out = varint(UInt64(field << 3 | 2))
        out += varint(UInt64(payload.count))
        out += payload
        return out
    }

    private static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    private static func readVarint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    private static func readTag(_ bytes: [UInt8], _ index: inout Int) -> Tag? {
        guard let raw = readVarint(bytes, &index) else { return nil }
        let field = Int(raw >> 3)
        let wire = Int(raw & 0x7)
        guard field > 0 else { return nil }
        return Tag(field: field, wire: wire)
    }

    private static func readDelimited(_ bytes: [UInt8], _ index: inout Int) -> [UInt8]? {
        guard let length = readVarint(bytes, &index) else { return nil }
        let count = Int(length)
        guard count >= 0, index + count <= bytes.count else { return nil }
        let payload = Array(bytes[index..<(index + count)])
        index += count
        return payload
    }

    private static func skip(_ bytes: [UInt8], _ index: inout Int, _ tag: Tag) -> Bool {
        switch tag.wire {
        case 0:
            return readVarint(bytes, &index) != nil
        case 1:
            guard index + 8 <= bytes.count else { return false }
            index += 8
            return true
        case 2:
            guard let length = readVarint(bytes, &index) else { return false }
            let count = Int(length)
            guard count >= 0, index + count <= bytes.count else { return false }
            index += count
            return true
        case 5:
            guard index + 4 <= bytes.count else { return false }
            index += 4
            return true
        default:
            return false
        }
    }
}
