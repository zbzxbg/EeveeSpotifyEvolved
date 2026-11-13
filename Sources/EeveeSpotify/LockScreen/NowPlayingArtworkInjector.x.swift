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
    /// `artworkID` → `MPMediaItemAnimatedArtwork`。
    ///
    /// 必须缓存：Spotify 每写一次进度都会经过这里，而 `artworkID` 没变时系统不会
    /// 重新要素材。每次新建对象只会白扔掉系统已经拿到的请求状态。
    private static var artworks: [String: Any] = [:]
    private static var lastLogged = ""
    private static var reportedUnsupported = false
    private static var reportedNoMatchingKey = false
    private static var supportedKeys: [String]?
    private static var activated = false

    /// 两个 hook 共用的入口：`nil` 原样传回，非字典也原样传回。
    static func inject(_ info: NSDictionary?) -> NSDictionary? {
        guard let info else { return nil }
        guard let dictionary = info as? [String: Any] else { return info }
        return inject(into: dictionary) as NSDictionary
    }

    static func inject(into info: [String: Any]) -> [String: Any] {
        guard #available(iOS 26.0, *) else { return info }
        guard LockScreenArtwork.isEnabled else {
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
                cover: cover
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
        cover: MPMediaItemArtwork?
    ) -> MPMediaItemAnimatedArtwork {
        // 封面晚到（Spotify 先写标题、后写封面）时，artworkID 跟着变一次，
        // 系统才会重新来要预览图；一直用同一个 ID 的话它不会再看新对象。
        let variant = "\(identifier).\(aspect.rawValue).\(cover != nil ? "c" : "n")"

        lock.lock()
        if let cached = artworks[variant] as? MPMediaItemAnimatedArtwork {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolver = LockScreenArtworkResolver.shared
        let artwork = MPMediaItemAnimatedArtwork(
            artworkID: variant,
            previewImageRequestHandler: { size, completion in
                completion(
                    resolver.previewImage(
                        title: title,
                        artist: artist,
                        duration: duration,
                        aspect: aspect,
                        size: size,
                        cover: cover
                    )
                )
            },
            videoAssetFileURLRequestHandler: { _, completion in
                Task {
                    let file = await resolver.videoFileURL(
                        identifier: identifier,
                        title: title,
                        artist: artist,
                        album: album,
                        duration: duration,
                        aspect: aspect,
                        size: aspect.renderSize,
                        cover: cover
                    )
                    completion(file)
                }
            }
        )

        lock.lock()
        if artworks.count > 16 {
            artworks.removeAll()
        }
        artworks[variant] = artwork
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
}
