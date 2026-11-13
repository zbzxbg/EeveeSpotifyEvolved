import Foundation
import MediaPlayer
import ObjectiveC.runtime
import Orion
import UIKit

/// 锁屏动态封面的挂点：Spotify 每次写 `nowPlayingInfo`，我们在这份字典里补上
/// `MPMediaItemAnimatedArtwork`。系统自己决定什么时候向我们要预览图和视频。
///
/// 为什么挂在这里而不是"每 0.3 秒自己设一遍"：Now Playing 是**系统**的状态，
/// Spotify 才是它的主人。我们只在它写的时候搭一段，不抢所有权 —— 也就不会和
/// 播放进度、锁屏控制那些字段打架。
struct LockScreenArtworkGroup: HookGroup {}
struct LockScreenArtworkPrivateGroup: HookGroup {}

class NowPlayingInfoCenterHook: ClassHook<NSObject> {
    typealias Group = LockScreenArtworkGroup
    static let targetName = "MPNowPlayingInfoCenter"

    func setNowPlayingInfo(_ info: NSDictionary?) {
        orig.setNowPlayingInfo(LockScreenArtworkInjector.inject(info))
    }
}

/// `MPNowPlayingInfoCenter` 在系统里可能是一个类簇：真正被写的那份实现有时挂在
/// 私有子类上。子类覆写了 setter 时，只挂基类不会命中 —— 两个都挂，注入本身是幂等的
/// （字典里已经有那两个键就原样返回），所以不会重复。
class NowPlayingInfoCenterPrivateHook: ClassHook<NSObject> {
    typealias Group = LockScreenArtworkPrivateGroup
    static let targetName = "MPCNowPlayingInfoCenter"

    func setNowPlayingInfo(_ info: NSDictionary?) {
        orig.setNowPlayingInfo(LockScreenArtworkInjector.inject(info))
    }
}

enum LockScreenArtworkInjector {

    private static let lock = NSLock()
    /// `artworkID` → 构造好的 `MPMediaItemAnimatedArtwork` + 注入时抓到的封面静帧。
    ///
    /// 必须缓存：Spotify 每写一次进度都会经过这里，而 `artworkID` 没变时系统不会
    /// 重新要素材。每次新建对象只会白扔掉系统已经拿到的请求状态。
    private static var artworks: [String: (artwork: Any, still: UIImage)] = [:]
    private static var lastLogged = ""
    private static var reportedUnsupported = false
    private static var reportedNoMatchingKey = false
    private static var loggedPreviews = Set<String>()
    private static var loggedClips = Set<String>()
    private static var waitingForStill = Set<String>()
    private static var supportedKeys: [String]?
    private static var activated = false
    /// Spotify 最近一次自己写进来的字典与时间。静帧准备好后我们要主动重写一次
    /// now-playing，重写时按速率把播放位置往前推，避免进度条倒跳。
    private static var reportedInfo: [String: Any]?
    private static var reportedAt: CFAbsoluteTime = 0
    /// 正在**我们自己**写 now-playing。写的那一下会从 hook 绕回来，
    /// 不能把"我们推进过时间的那份字典"当成 Spotify 的基准。
    private static var republishing = false

    /// 两个 hook 共用的入口：`nil` 原样传回，非字典也原样传回。
    static func inject(_ info: NSDictionary?) -> NSDictionary? {
        guard let info else { return nil }
        guard let dictionary = info as? [String: Any] else { return info }
        return inject(into: dictionary) as NSDictionary
    }

    static func inject(into info: [String: Any]) -> [String: Any] {
        guard #available(iOS 26.0, *) else { return info }

        // 记"Spotify 最后写成什么样"的报时点。
        //
        // 判据是"这一次不是我们自己写的"，而**不是**"字典里没有我们的键"：
        // Spotify 可能读回 `nowPlayingInfo` 再整体写一遍（参考实现也给 getter 打了同样的
        // 补丁），那种字典是带着我们的键回来的，它才是新的基准；把它们排除掉会让基准
        // 冻结在第一次注入之前，之后每次重写都会算错播放位置。
        //
        // 这一段必须在开关判断**之前**：两个开关都关着时也要记 —— 歌词是用户中途打开的，
        // 那一刻手上得有一份快照，才能立刻重写一次。
        lock.lock()
        let isRepublishing = republishing
        lock.unlock()
        if !isRepublishing {
            lock.lock()
            reportedInfo = info
            reportedAt = CFAbsoluteTimeGetCurrent()
            lock.unlock()
        }

        // 歌词与动态封面共用同一对动画键。歌词开着时它优先：一行一段短片，
        // ID 跟着行走（见 `LockScreenLyricsController`）；没准备好就退回动态封面。
        let lyricsOn = LockScreenLyrics.isEnabled
        guard LockScreenArtwork.isEnabled || lyricsOn else {
            // 关掉之后不再有任何新素材，旧 artwork 的 handler 也要失效（空标识 ≠ 上一首）。
            LockScreenArtworkResolver.shared.noteNowPlaying(identifier: "")
            return info
        }
        guard let title = info[MPMediaItemPropertyTitle] as? String, !title.isEmpty else {
            return info
        }

        // 系统给的是"当前平台收哪些键"：问一次、缓存起来。空集不能缓存 —— 框架刚起来
        // 时它可能还没把清单填上，下一次写入再问就会有了。
        let supported = animatedArtworkKeys()
        guard !supported.isEmpty else {
            noteUnsupportedOnce()
            return info
        }

        let artist = info[MPMediaItemPropertyArtist] as? String ?? ""
        let album = info[MPMediaItemPropertyAlbumTitle] as? String ?? ""
        let duration = (info[MPMediaItemPropertyPlaybackDuration] as? NSNumber)?.doubleValue ?? 0
        let identifier = LockScreenArtwork.artworkID(
            title: title,
            artist: artist,
            duration: duration
        )
        LockScreenArtworkResolver.shared.noteNowPlaying(identifier: identifier)

        let cover = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        let resolver = LockScreenArtworkResolver.shared
        var still = resolver.cachedStill(title: title, artist: artist)
        if still == nil, let cover,
           let image = cover.image(at: CGSize(width: 720, height: 720)) {
            resolver.keepStill(image, title: title, artist: artist)
            still = image
        }

        let lyrics = LockScreenLyrics.isEnabled ? LockScreenLyricsController.shared : nil
        let lyricsTrackKey = LockScreenLyrics.trackKey(
            title: title,
            artist: artist,
            duration: duration
        )
        if let still, let lyrics {
            // 这一首的封面只留一张：预览与短片都拿它做模糊底。
            lyrics.noteCover(still, trackKey: lyricsTrackKey)
        } else if let lyrics {
            // 歌词也用封面做底。字典里没有 artwork 时照旧去元数据补一张，
            // 补到之后 resolver 会再触发一次注入，这一首后面的行就用上了。
            resolver.prepareStill(title: title, artist: artist)
        }

        if let lyrics {
            lyrics.noteNowPlaying(info)
            let prepared = lyrics.preparedArtwork(trackKey: lyricsTrackKey)
            if !prepared.isEmpty {
                var output = info
                var changed = false
                for (key, value) in prepared {
                    guard supported.contains(key),
                          let artwork = value as? MPMediaItemAnimatedArtwork else {
                        continue
                    }
                    // 同一个对象再写一遍不算变化；换行时它是新对象、新 ID。
                    if let existing = output[key] as? MPMediaItemAnimatedArtwork,
                       existing === artwork {
                        continue
                    }
                    output[key] = artwork
                    changed = true
                }
                if changed {
                    noteInjectedOnce(
                        identifier: "\(identifier)-lyrics",
                        title: title,
                        supported: supported
                    )
                    return output
                }
                return info
            }
        }

        guard LockScreenArtwork.isEnabled else {
            return info
        }

        guard let still else {
            // 动画键没有预览图时系统会画成灰色占位图，比静态封面还糟。没有静帧就先
            // 别注入：让 metadata 的封面地址去补一张，补到了再重写一次 now-playing。
            resolver.prepareStill(title: title, artist: artist)
            noteWaitingForStillOnce(
                identifier: identifier,
                title: title,
                coverPresent: cover != nil
            )
            return info
        }

        var output = info
        var changed = false

        for aspect in LockScreenArtwork.Aspect.allCases {
            let key: String
            switch aspect {
            case .square: key = MPNowPlayingInfoProperty1x1AnimatedArtwork
            case .tall: key = MPNowPlayingInfoProperty3x4AnimatedArtwork
            }
            guard supported.contains(key) else { continue }

            let expected = artwork(
                identifier: identifier,
                aspect: aspect,
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                still: still
            )
            // 同一个对象再写一遍不算变化；但 Spotify（或别的组件）把上一首的 artwork
            // 原样带回来时，这里要换成当前这一首的 —— 不能只看"键在不在"。
            if let existing = output[key] as? MPMediaItemAnimatedArtwork, existing === expected {
                continue
            }
            output[key] = expected
            changed = true
        }

        guard changed else {
            if !supported.contains(MPNowPlayingInfoProperty1x1AnimatedArtwork),
               !supported.contains(MPNowPlayingInfoProperty3x4AnimatedArtwork) {
                noteNoMatchingKeyOnce(supported: supported)
            }
            return info
        }
        noteInjectedOnce(identifier: identifier, title: title, supported: supported)
        return output
    }

    // MARK: - 构造

    @available(iOS 26.0, *)
    private static func artwork(
        identifier: String,
        aspect: LockScreenArtwork.Aspect,
        title: String,
        artist: String,
        album: String,
        duration: Double,
        still: UIImage
    ) -> MPMediaItemAnimatedArtwork {
        let variant = "\(identifier).\(aspect.rawValue)"

        lock.lock()
        if let cached = artworks[variant],
           let artwork = cached.artwork as? MPMediaItemAnimatedArtwork {
            lock.unlock()
            return artwork
        }
        lock.unlock()

        let resolver = LockScreenArtworkResolver.shared
        let artwork = MPMediaItemAnimatedArtwork(
            artworkID: variant,
            previewImageRequestHandler: { size, completion in
                let image = resolver.previewImage(
                    title: title,
                    artist: artist,
                    duration: duration,
                    aspect: aspect,
                    size: size,
                    still: still
                )
                notePreviewOnce(
                    identifier: identifier,
                    aspect: aspect,
                    size: size,
                    result: image
                )
                completion(image)
            },
            videoAssetFileURLRequestHandler: { _, completion in
                noteClipAskedOnce(identifier: identifier, aspect: aspect, title: title)
                Task {
                    let file = await resolver.videoFileURL(
                        identifier: identifier,
                        title: title,
                        artist: artist,
                        album: album,
                        duration: duration,
                        aspect: aspect,
                        size: aspect.renderSize,
                        still: still
                    )
                    completion(file)
                }
            }
        )

        lock.lock()
        if artworks.count > 16 {
            artworks.removeAll()
        }
        artworks[variant] = (artwork, still)
        lock.unlock()
        return artwork
    }

    @available(iOS 26.0, *)
    private static func animatedArtworkKeys() -> [String] {
        lock.lock()
        if let cached = supportedKeys {
            lock.unlock()
            return cached
        }
        let keys = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
        if !keys.isEmpty {
            supportedKeys = keys
        }
        lock.unlock()
        return keys
    }

    // MARK: - 日志

    /// 两段 init 都会调 `activateLockScreenArtwork`（版本分支互斥，这里只是防御），
    /// 重复 `activate()` 没有意义，也可能把同一个 setter 挂两遍。
    @discardableResult
    static func markActivatedOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !activated else { return false }
        activated = true
        return true
    }

    private static func noteUnsupportedOnce() {
        lock.lock()
        let first = !reportedUnsupported
        reportedUnsupported = true
        lock.unlock()

        guard first else { return }
        writeDebugLog(
            "[\(LockScreenArtwork.logTag)] this platform supports no animated artwork key —"
                + " nothing is injected"
        )
    }

    private static func noteNoMatchingKeyOnce(supported: [String]) {
        lock.lock()
        let first = !reportedNoMatchingKey
        reportedNoMatchingKey = true
        lock.unlock()

        guard first else { return }
        writeDebugLog(
            "[\(LockScreenArtwork.logTag)] platform keys [\(supported.joined(separator: ","))]"
                + " contain none of the two animated artwork keys — nothing is injected"
        )
    }

    private static func noteInjectedOnce(identifier: String, title: String, supported: [String]) {
        lock.lock()
        let changed = identifier != lastLogged
        if changed { lastLogged = identifier }
        lock.unlock()

        guard changed else { return }
        writeDebugLog(
            "[\(LockScreenArtwork.logTag)] now playing carries animated artwork —"
                + " keys \(supported.joined(separator: ",")), \"\(title)\""
        )
    }

    private static func noteWaitingForStillOnce(
        identifier: String,
        title: String,
        coverPresent: Bool
    ) {
        lock.lock()
        let first = waitingForStill.insert(identifier).inserted
        if waitingForStill.count > 32 {
            waitingForStill.removeAll()
        }
        lock.unlock()

        guard first else { return }
        writeDebugLog(
            "[\(LockScreenArtwork.logTag)] no cover still yet — deferring injection,"
                + " \"\(title)\" (MPMediaItemPropertyArtwork: \(coverPresent ? "yes" : "no"))"
        )
    }

    private static func notePreviewOnce(
        identifier: String,
        aspect: LockScreenArtwork.Aspect,
        size: CGSize,
        result: UIImage?
    ) {
        let key = "\(identifier)|\(aspect.rawValue)"
        lock.lock()
        let first = loggedPreviews.insert(key).inserted
        if loggedPreviews.count > 64 {
            loggedPreviews.removeAll()
        }
        lock.unlock()

        guard first else { return }
        let resultText = result.map {
            "\(Int($0.size.width))x\(Int($0.size.height))"
        } ?? "nil"
        writeDebugLog(
            "[\(LockScreenArtwork.logTag)] preview asked —"
                + " \(Int(size.width))x\(Int(size.height)) -> \(resultText)"
        )
    }

    private static func noteClipAskedOnce(
        identifier: String,
        aspect: LockScreenArtwork.Aspect,
        title: String
    ) {
        let key = "\(identifier)|\(aspect.rawValue)"
        lock.lock()
        let first = loggedClips.insert(key).inserted
        if loggedClips.count > 64 {
            loggedClips.removeAll()
        }
        lock.unlock()

        guard first else { return }
        writeDebugLog(
            "[\(LockScreenArtwork.logTag)] clip asked — \(aspect.rawValue), \"\(title)\""
        )
    }

    /// 静帧/素材准备好之后由 resolver 调一次：Spotify 不会为了我们重写 now-playing，
    /// 不补这一下，动画键要等下一次播放状态变化才会被注入。
    static func refreshNowPlayingInfo(title: String, artist: String) {
        guard #available(iOS 26.0, *),
              LockScreenArtwork.isEnabled || LockScreenLyrics.isEnabled else {
            return
        }
        DispatchQueue.main.async {
            lock.lock()
            guard let info = reportedInfo else {
                lock.unlock()
                return
            }
            let reported = reportedAt
            lock.unlock()

            // 静帧是异步抓的：抓完时可能已经切歌了，别拿上一首的封面去重写当前这首。
            let reportedTitle = info[MPMediaItemPropertyTitle] as? String ?? ""
            guard LockScreenArtwork.looksLikeSameSong(reportedTitle, title) else { return }
            republish(info, reportedAt: reported)
        }
    }

    /// 锁屏歌词换行时用：把 Spotify 最近一次写的那份字典推进到现在，再走一遍注入。
    /// 不经过这一步，换行只能等 Spotify 下一次自己写 now-playing —— 那是十几秒一次的级别。
    static func republishForLockScreen() {
        guard #available(iOS 26.0, *) else { return }
        DispatchQueue.main.async {
            lock.lock()
            guard let info = reportedInfo else {
                lock.unlock()
                return
            }
            let reported = reportedAt
            lock.unlock()
            republish(info, reportedAt: reported)
        }
    }

    /// 重设 now-playing 会把系统的播放位置基准重置到这份字典里的旧值；
    /// 按速率补上"从 Spotify 上次写到现在的距离"，进度条就不会倒跳。
    private static func republish(_ info: [String: Any], reportedAt reported: CFAbsoluteTime) {
        var info = info
        if let elapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber {
            let rate = (info[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue ?? 1
            let distance = max(0, CFAbsoluteTimeGetCurrent() - reported)
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = NSNumber(
                value: elapsed.doubleValue + rate * distance
            )
        }

        // 我们自己写的这一下会从 setter hook 绕回来；标上记号，别让它覆盖基准。
        lock.lock()
        republishing = true
        lock.unlock()
        MPNowPlayingInfoCenter.default().nowPlayingInfo =
            LockScreenArtworkInjector.inject(into: info)
        lock.lock()
        republishing = false
        lock.unlock()
    }
}

/// 启动时调一次。开关是**实时读**的，所以这里总是装 —— 只有 Canvas 那条 flag
/// 要重启才生效（它走 Spotify 的远端配置）。
func activateLockScreenArtwork() {
    guard #available(iOS 26.0, *) else {
        writeDebugLog("[\(LockScreenArtwork.logTag)] skipped — animated artwork needs iOS 26")
        return
    }

    guard NSClassFromString("MPMediaItemAnimatedArtwork") != nil else {
        writeDebugLog(
            "[\(LockScreenArtwork.logTag)] skipped — MPMediaItemAnimatedArtwork not found"
        )
        return
    }

    let name = NowPlayingInfoCenterHook.targetName
    guard let target = NSClassFromString(name),
          class_getInstanceMethod(target, Selector(("setNowPlayingInfo:"))) != nil else {
        writeDebugLog("[\(LockScreenArtwork.logTag)] skipped — \(name) has no setter")
        return
    }

    guard LockScreenArtworkInjector.markActivatedOnce() else { return }
    LockScreenArtworkGroup().activate()
    writeDebugLog(
        "[\(LockScreenArtwork.logTag)] hook installed on \(name), platform keys:"
            + " \(MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys.joined(separator: ","))"
    )

    // 类簇的私有实现：存在才挂，不存在就只留一行 —— 挂一个不存在的类没有意义。
    let privateName = NowPlayingInfoCenterPrivateHook.targetName
    if let privateTarget = NSClassFromString(privateName),
       class_getInstanceMethod(privateTarget, Selector(("setNowPlayingInfo:"))) != nil {
        LockScreenArtworkPrivateGroup().activate()
        writeDebugLog("[\(LockScreenArtwork.logTag)] also hooked \(privateName)")
    }

    // 锁屏歌词：同一对动画键，按行走。开关实时读，这里只是把调度器接上。
    LockScreenLyricsController.shared.activate()
}
