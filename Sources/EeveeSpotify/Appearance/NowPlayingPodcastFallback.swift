import Foundation
import ObjectiveC.runtime

/// 「现在放的是不是播客/有声书」—— 听歌页几何让位的唯一判据。
///
/// `NowPlayingIOS27` 的几何是按**音乐**播放页算的（封面 0.58 屏、底部栈整体上移 55pt、
/// 页脚三颗字形）。播客那一行多出快退 / 快进 / 倍速，照音乐几何摆会被挤出屏幕 ⇒ 播客
/// 必须**整层让位**、交回 Spotify 自己的布局，而不是"少摆几样东西"。
///
/// 判据按顺序取，任一命中即为播客：
///
/// 1. 曲目 URI 的 `spotify:episode:` / `spotify:show:` 前缀（`/episode/` 形式也算）；
/// 2. `spt_trackIdentifier()` 里带 `spotify:episode:`（URI 对象读不到 `absoluteString` 时）；
/// 3. 曲目对象上的 `isPodcast`。
///
/// ⚠️ 不能**只**信 `isPodcast`：视频播客上那个标记会翻成 false，而 URI 不会
/// （`SponsorBlockSkipper` 同样因此改用 URI 判）。反过来也不能只信 URI：本地文件 /
/// 播客片段可能读不到 URI。
///
/// 数据源优先实时播放器状态，其次播放页自己的 `loadedTrack`（歌词模块关着时
/// `statefulPlayer` 抓不到，见 `BlockedArtistSkip` 那条说明）。两条都拿不到时返回 false：
/// 保持现状（音乐照旧铺），不把"读不到"当成播客。
enum NowPlayingPodcastFallback {

    /// 页面上正在放的是播客或其它非音乐内容。
    static var isActive: Bool {
        guard let track = currentTrack() else { return false }
        return isPodcastTrack(track)
    }

    /// 一条给日志用的现场（判定翻转的那一拍才取，别放进每拍路径）。
    static var debugDescription: String {
        guard let track = currentTrack() else { return "no track" }
        let uri = uriString(of: track) ?? "<nil>"
        let identifier = identifierString(of: track) ?? "<nil>"
        return "uri=\(uri) identifier=\(identifier)"
    }

    private static func currentTrack() -> SPTPlayerTrack? {
        statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
    }

    private static func isPodcastTrack(_ track: SPTPlayerTrack) -> Bool {
        if let uri = uriString(of: track), isPodcastURI(uri) { return true }
        if let identifier = identifierString(of: track), isPodcastURI(identifier) { return true }
        return isFlaggedPodcast(track)
    }

    private static func isPodcastURI(_ uri: String) -> Bool {
        uri.hasPrefix("spotify:episode:")
            || uri.hasPrefix("spotify:show:")
            || uri.contains("/episode/")
    }

    /// `SPTURL` 是手写的 `@objc protocol`（真身是 NSURL），声明里只有
    /// `spt_trackIdentifier` / `isPlaylistURL` —— `absoluteString` 只能运行时取，
    /// 写成 `track.URI()?.absoluteString` 编译期就会报 "has no member"。
    private static func uriString(of track: SPTPlayerTrack) -> String? {
        let object: AnyObject = track.URI() as AnyObject
        if let url = object as? URL { return url.absoluteString }
        if let string = object as? String { return string }
        guard let nsObject = object as? NSObject,
              nsObject.responds(to: Selector("absoluteString")) else { return nil }
        return nsObject.perform(Selector("absoluteString"))?.takeUnretainedValue() as? String
    }

    /// 曲目上是裸 id；播客上有的版本给的是整条 `spotify:episode:…`。认不出就返回 nil，
    /// 别拿裸 id 去比前缀。
    private static func identifierString(of track: SPTPlayerTrack) -> String? {
        let identifier = track.URI().spt_trackIdentifier()
        return identifier.isEmpty ? nil : identifier
    }

    /// 曲目对象上的 `isPodcast`：`SPTPlayerTrack` 协议里没有声明，用 KVC 读。
    /// 读之前先 `responds(to:)` —— 与 `SponsorBlockSkipper.safeRead` 同一条纪律，
    /// 不然缺失的 getter 会抛 `NSUnknownKeyException`。
    private static func isFlaggedPodcast(_ track: SPTPlayerTrack) -> Bool {
        guard let object = track as? NSObject,
              object.responds(to: Selector("isPodcast")) else { return false }
        return (object.value(forKey: "isPodcast") as? Bool) ?? false
    }
}
