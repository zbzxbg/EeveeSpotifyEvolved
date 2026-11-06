import Foundation

/// 换歌词源之后，把**当前这一首**的歌词响应从 URL 缓存里删掉。
///
/// ── 为什么需要
/// 我们只替换响应、从不发请求（`color-lyrics/v2` 的请求由 Spotify 自己建）。所以"换了来源
/// 什么时候生效"取决于它下一次**真的问**的时候。服务端给歌词响应的头是
/// `Cache-Control: public, max-age=3600` —— 正是会被 URL 缓存原样收下的那种。如果客户端吃缓存，
/// 它就不会发请求，我们也就没有机会换 payload（表现就是"换了源要重启"）。
///
/// 这里在"设置变了"的那一刻把**上一次歌词请求**那一条从会话自己的 URL 缓存里删掉。
/// 下一个请求必然回到网络上 ⇒ 钩子重新取词、注入新来源的词。删除范围只有那一条 URL，
/// 不碰图片 / 其它接口。
///
/// ── 为什么记会话而不只用 `URLCache.shared`
/// `URLSessionConfiguration.default` 默认用 `URLCache.shared`，但 `ephemeral` 配置用的是
/// 各自的**内存**缓存（重启就没了 —— 与"重启后就能换过来"这一现象吻合）。会话对象在
/// `URLSession` 的 delegate 回调里直接拿得到，所以记下它、用 `configuration.urlCache` 删除，
/// 两种配置都能覆盖。
///
/// 删除时打一行：命中 → 删掉了多少字节（说明这一层确实在缓存歌词）；没命中 → 说明歌词不在
/// 这个 URL 缓存里（客户端自己攥着解析后的歌词），那种情况只有重启能换过来。
enum LyricsURLCachePurge {

    private static let lock = NSLock()
    /// 上一次歌词请求的会话（弱引用：会话被重建后自然失效）。
    private static weak var lastSession: URLSession?
    /// 上一次歌词请求的 URL（带完整 query —— URL 缓存的键就是整条 URL）。
    private static var lastURL: URL?

    /// 每来一次 `color-lyrics` 请求就记一次（钩子里调用，主线程/后台都可能）。
    static func remember(session: URLSession, url: URL) {
        lock.lock()
        lastSession = session
        lastURL = url
        lock.unlock()
    }

    /// 设置变了：删掉上一次歌词请求那一条缓存。
    ///
    /// 不联网、不重发请求；只让**下一次**请求回到网络。
    static func purgeLastRequest(reason: String) {
        lock.lock()
        let session = lastSession
        let url = lastURL
        lock.unlock()

        guard let url else {
            writeDebugLog("[Lyrics] \(reason) — no color-lyrics request seen yet, URL cache untouched")
            return
        }

        // 会话已经没了时退回共享缓存：`default` 配置用的就是它。
        let cache = session?.configuration.urlCache ?? URLCache.shared
        let request = URLRequest(url: url)
        let cached = cache.cachedResponse(for: request)
        cache.removeCachedResponse(for: request)

        if let cached {
            writeDebugLog(
                "[Lyrics] \(reason) — removed \(cached.data.count) byte(s) of color-lyrics from the"
                    + " URL cache (\(url.path)); the next request will go to the network"
            )
        } else {
            writeDebugLog(
                "[Lyrics] \(reason) — color-lyrics was not in the URL cache (\(url.path));"
                    + " the client keeps its own copy, so this track needs a restart to switch"
            )
        }
    }
}
