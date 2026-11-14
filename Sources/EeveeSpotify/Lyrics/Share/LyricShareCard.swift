import Foundation
import UIKit

/// 「把这一句歌词做成图片发出去」。
///
/// 链路：长按歌词行 → 这一层在后台拼图（封面走 `LyricsArtworkResolver` 的
/// 同一套元数据取法，因此和歌词背景、锁屏用的是同一张图）→ 主线程弹系统分享面板。
///
/// 为什么自己在后台队列上跑、而不是用 Swift concurrency：绘制是同步的 CoreGraphics，
/// 而调用点（SwiftUI 手势回调）在主线程。放进一个串行队列最省事，也不会和播放器那一层
/// 抢主线程的帧预算。
enum LyricShareCard {

    private static let renderQueue = DispatchQueue(
        label: "com.eevee.lyrics.sharecard",
        qos: .userInitiated
    )

    /// 同一张封面在连续分享里只下载一次。只缓存最近一条：
    /// 分享是低频操作，缓存表没有必要，而留在内存里的旧图反而会用错歌的封面。
    private static var cachedCover: (url: URL, image: UIImage)?

    static func present(
        line: LyricLine,
        title: String,
        artist: String,
        credit: String
    ) {
        let lyric = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lyric.isEmpty else { return }

        // iOS 27 播放页里的页内歌词层挂载时曲名/歌手传的是空串（那一层的标题由播放器自己画），
        // 分享卡上不能跟着空着 —— 从播放器 metadata 兜底，两边都没有就留空，不编。
        let names = trackNames(title: title, artist: artist)
        var content = LyricShareCardRenderer.Content(
            title: names.title,
            artist: names.artist,
            lyric: lyric,
            romanization: trimmed(line.romanization),
            translation: trimmed(line.translation),
            credit: credit.trimmingCharacters(in: .whitespacesAndNewlines),
            cover: nil
        )
        writeDebugLog("[LyricsShare] preparing — \(content.title) / \(String(lyric.prefix(24)))")

        renderQueue.async {
            content.cover = coverImage()
            let image = LyricShareCardRenderer.image(for: content)
            DispatchQueue.main.async {
                present(image)
            }
        }
    }

    // MARK: - 封面

    private static func coverImage() -> UIImage? {
        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        guard let url = LyricsArtworkResolver.artworkURL(for: track) else {
            writeDebugLog("[LyricsShare] no artwork URL for this track")
            return nil
        }
        if let cachedCover, cachedCover.url == url {
            return cachedCover.image
        }
        guard let data = fetch(url), let image = UIImage(data: data) else {
            writeDebugLog("[LyricsShare] could not fetch the artwork")
            return nil
        }
        cachedCover = (url, image)
        return image
    }

    /// 同步取一次封面。调用点已经在串行后台队列上，阻塞它是安全的；
    /// 超时兜底是为了不把分享面板卡在一个不响应的图片服务器上。
    private static func fetch(_ url: URL) -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        var payload: Data?
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            payload = data
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 10)
        return payload
    }

    // MARK: - 呈现

    private static func present(_ image: UIImage) {
        guard let window = EntityPageAppearance.frontWindow(),
              var host = window.rootViewController else {
            writeDebugLog("[LyricsShare] no host view controller")
            return
        }
        // 全屏歌词页、播放器、`⋯` 菜单都可能已经弹了一层，分享面板要挂在最上面那一层。
        while let presented = host.presentedViewController, !presented.isBeingDismissed {
            host = presented
        }
        let activity = UIActivityViewController(
            activityItems: [image],
            applicationActivities: nil
        )
        // iPad 上没有 sourceView 会直接崩；箭头不需要，所以给一个零尺寸锚点。
        if let popover = activity.popoverPresentationController {
            popover.sourceView = host.view
            popover.sourceRect = CGRect(
                x: host.view.bounds.midX,
                y: host.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }
        host.present(activity, animated: true)
        writeDebugLog("[LyricsShare] share sheet presented")
    }

    private static func trimmed(_ text: String?) -> String? {
        let value = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// 曲名/歌手兜底。
    ///
    /// iOS 27 播放页里那一层（`NowPlayingLyricsHost`）挂载时传的是两个空串 —— 它的标题由
    /// 播放器自己画。分享卡不能跟着空着，所以缺哪一项就从播放器 metadata 补哪一项；
    /// 两边都没有就保持空，不编造。
    private static func trackNames(
        title: String,
        artist: String
    ) -> (title: String, artist: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.isEmpty || trimmedArtist.isEmpty else {
            return (trimmedTitle, trimmedArtist)
        }
        guard let track = statefulPlayer?.currentTrack()
            ?? nowPlayingScrollViewController?.loadedTrack else {
            return (trimmedTitle, trimmedArtist)
        }
        let metadata = track.metadata()
        let resolvedTitle = trimmedTitle.isEmpty ? (metadata["title"] ?? "") : trimmedTitle
        let resolvedArtist = trimmedArtist.isEmpty ? (metadata["artist_name"] ?? "") : trimmedArtist
        return (resolvedTitle, resolvedArtist)
    }
}
