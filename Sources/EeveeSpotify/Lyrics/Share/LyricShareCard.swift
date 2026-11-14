import Foundation
import UIKit

/// 「把这一句歌词做成图片发出去」。
///
/// 链路：长按歌词行 → 主线程上把播放器那一份快照取全（曲名/歌手、封面地址、封面取色）→
/// 后台队列拼图 → 主线程弹系统分享面板。
///
/// 为什么手动分线程、而不是用 Swift concurrency：绘制是同步的 CoreGraphics，
/// 调用点（SwiftUI 手势回调）在主线程。放进一个串行队列最省事，也不会和播放器那一层
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

        // ⚠️ 这些都在**主线程**上取：`statefulPlayer.currentTrack()` / `metadata()` 是播放器
        // 那边的快照，给后台队列留下一个"回头问它"的口子迟早会读到半新半旧的状态。
        let track = statefulPlayer?.currentTrack()
            ?? nowPlayingScrollViewController?.loadedTrack
        let metadata = track?.metadata()
        let names = resolvedNames(title: title, artist: artist, metadata: metadata)
        let artworkURL = track.flatMap { LyricsArtworkResolver.artworkURL(for: $0) }

        var content = LyricShareCardRenderer.Content(
            title: names.title,
            artist: names.artist,
            lyric: lyric,
            romanization: trimmed(line.romanization),
            translation: trimmed(line.translation),
            credit: credit.trimmingCharacters(in: .whitespacesAndNewlines),
            cover: nil,
            backgroundColorHex: metadata?["extracted_color"],
            template: UserDefaults.shareCardTemplate,
            background: UserDefaults.shareCardBackground,
            ink: UserDefaults.shareCardInk
        )
        writeDebugLog("[LyricsShare] preparing — \(content.title) / \(String(lyric.prefix(24)))")

        renderQueue.async {
            content.cover = coverImage(url: artworkURL)
            let image = LyricShareCardRenderer.image(for: content)
            DispatchQueue.main.async {
                present(image)
            }
        }
    }

    // MARK: - 快照

    /// 曲名/歌手。
    ///
    /// iOS 27 播放页里那一层（`NowPlayingLyricsHost`）挂载时传的是两个空串 —— 它的标题由
    /// 播放器自己画。分享卡不能跟着空着，所以缺哪一项就从 metadata 补哪一项；
    /// 两边都没有就保持空，不编造。
    private static func resolvedNames(
        title: String,
        artist: String,
        metadata: [String: String]?
    ) -> (title: String, artist: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.isEmpty || trimmedArtist.isEmpty else {
            return (trimmedTitle, trimmedArtist)
        }
        let resolvedTitle = trimmedTitle.isEmpty ? (metadata?["title"] ?? "") : trimmedTitle
        let resolvedArtist = trimmedArtist.isEmpty ? (metadata?["artist_name"] ?? "") : trimmedArtist
        return (resolvedTitle, resolvedArtist)
    }

    // MARK: - 封面

    private static func coverImage(url: URL?) -> UIImage? {
        guard let url else {
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
}
