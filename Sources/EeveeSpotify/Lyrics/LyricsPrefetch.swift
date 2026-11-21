import Foundation

/// 在 Spotify 请求歌词内容之前，先把这一首的词取回来，写进结果备忘。
///
/// 触发点是「正在播放页元素列表」（`scrollsita/v1/scroll/spotify:track:<id>`）：
/// 它决定歌词卡片存不存在，且一定早于同曲目那次 `color-lyrics`；path 里自带曲目 id，
/// 所以这里不用轮询播放器，也不会给没打开正在播放页的曲目白跑网络。
///
/// 命中之后，第一次 `color-lyrics` 请求就走 `LyricsResponseCache` 的 `.cached`
/// （0 等待、真词），卡片建出来就是内容 —— 而不是先挂「未找到歌词」等下一次请求。
enum LyricsPrefetch {

    /// 同一个 id 只跑一次；`finished` 用来挡住同一首的多次元素列表响应。
    private static let lock = NSLock()
    private static var inFlightTrackId: String?
    private static var finishedTrackId: String?

    static func consider(scrollsitaURL url: URL) {
        guard !SpotifyResponsePatcher.isLyricsFeatureDisabled,
              UserDefaults.lyricsSource.isReplacingLyrics,
              let trackId = trackId(fromScrollsitaURL: url) else { return }

        // 「显示原始颜色」要的是 Spotify 那份 payload 里的 colors，而预取拿不到它
        // （这里没有 `originalLyrics`）—— 那一档交给正常请求路径，别用合成色顶上去。
        guard !UserDefaults.lyricsColors.displayOriginalColors else { return }

        // 曲目一致性：播放器现在必须就是这一首。否则 `getLyricsDataAndPlaceholderFlag`
        // 会先空等 3 秒、再判 `trackMismatch` 交占位。
        guard let currentId = currentTrackIdentifier(), currentId == trackId else { return }

        let path = "/color-lyrics/v2/track/\(trackId)"
        let signature = LyricsResponseCache.currentSignature
        if LyricsResponseCache.shared.memoizedPayload(forPath: path, signature: signature) != nil {
            return
        }

        lock.lock()
        let alreadyRunning = inFlightTrackId == trackId || finishedTrackId == trackId
        if !alreadyRunning {
            inFlightTrackId = trackId
        }
        lock.unlock()
        guard !alreadyRunning else { return }

        writeDebugLog("[Prefetch] \(trackId): start")
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                lock.lock()
                if inFlightTrackId == trackId {
                    inFlightTrackId = nil
                }
                finishedTrackId = trackId
                lock.unlock()
            }

            guard let result = try? getLyricsDataAndPlaceholderFlag(path) else {
                writeDebugLog("[Prefetch] \(trackId): no payload")
                return
            }
            // 占位是「还不知道」，写进备忘会让第一次真实请求直接命中它 —— 比不预取更差。
            guard !result.isPlaceholder else {
                writeDebugLog("[Prefetch] \(trackId): skipped (placeholder)")
                return
            }
            guard LyricsResponseCache.currentSignature == signature else {
                writeDebugLog("[Prefetch] \(trackId): aborted (settings changed)")
                return
            }
            guard let stillPlaying = currentTrackIdentifier(), stillPlaying == trackId else {
                writeDebugLog("[Prefetch] \(trackId): aborted (track changed)")
                return
            }

            LyricsResponseCache.shared.store(result.data, forPath: path, signature: signature)
            writeDebugLog("[Prefetch] \(trackId): stored \(result.data.count)B")
        }
    }

    /// `/scrollsita/v1/scroll/spotify:track:<id>` → `<id>`。与元素注入那边同一套解析。
    private static func trackId(fromScrollsitaURL url: URL) -> String? {
        let marker = "/scrollsita/v1/scroll/spotify:track:"
        guard let range = url.path.range(of: marker) else { return nil }
        let id = String(url.path[range.upperBound...])
        return id.isEmpty ? nil : id
    }

    private static func currentTrackIdentifier() -> String? {
        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        guard let identifier = track?.trackIdentifier, !identifier.isEmpty else { return nil }
        return identifier
    }
}
