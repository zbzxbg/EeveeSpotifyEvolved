import Foundation

/// 自己向 Spotify 问 Canvas：锁屏动态封面用的那段循环短片。
///
/// 为什么不再沿用它那条 `ios-feature-canvas.canvas_enabled` flag：
/// 那条是**服务端配置**，而客户端还有自己的 Canvas 偏好（Spotify 设置 → 播放 → Canvas），
/// 两者都为真播放核心才会把 `canvas.url` 填进 track metadata。强制 flag 只能骗过前者，
/// 于是会出现两种都不对的结果：用户关着 Spotify 的 Canvas 时我们什么都拿不到；
/// 用户开着时，播放页也会跟着显示 Canvas（同一个 flag 带出来的副作用）。
///
/// 这里直接问 `canvaz-cache`，与那个 flag、与播放页的 Canvas 完全解耦。
/// 鉴权用仓库里已经抓到的 Spotify Bearer token（`DataLoaderServiceHooks` 从
/// Spotify 自己的请求头里截下来的那条，不含 `Bearer ` 前缀）。
enum SpotifyCanvasClient {

    private static let endpoint = URL(
        string: "https://spclient.wg.spotify.com/canvaz-cache/v0/canvases"
    )!

    /// - Parameter trackIdentifier: 曲目 id（`trackIdentifier`），也接受完整的 `spotify:track:…`。
    static func canvas(
        trackIdentifier: String,
        session: URLSession
    ) async -> SpotifyCanvasProto.Canvas? {
        guard !trackIdentifier.isEmpty else { return nil }
        guard let token = spotifyAccessTokenSnapshot(), !token.isEmpty else {
            writeDebugLog(
                "[\(LockScreenArtwork.logTag)] canvaz skipped — no Spotify token captured yet"
            )
            return nil
        }

        let uri = trackIdentifier.hasPrefix("spotify:")
            ? trackIdentifier
            : "spotify:track:\(trackIdentifier)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = SpotifyCanvasProto.requestBody(entityURI: uri)
        request.timeoutInterval = 8
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            writeDebugLog("[\(LockScreenArtwork.logTag)] canvaz request failed — no response")
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            writeDebugLog(
                "[\(LockScreenArtwork.logTag)] canvaz request failed — HTTP \(http.statusCode)"
            )
            return nil
        }

        let canvas = SpotifyCanvasProto.parseResponse(data)
        writeDebugLog(
            "[\(LockScreenArtwork.logTag)] canvaz — "
                + (canvas == nil ? "none" : "video")
                + ", \(data.count) byte(s)"
        )
        return canvas
    }
}
