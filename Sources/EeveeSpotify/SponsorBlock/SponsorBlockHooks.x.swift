import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

private var eeveeObserverRegistered = false
private let eeveeObserver = EeveeSponsorBlockObserver()

@objc final class EeveeSponsorBlockObserver: NSObject {
    @objc func player(_ player: AnyObject, stateDidChange newState: AnyObject) {
        SponsorBlockSkipper.shared.processStateChange(player: player, state: newState)
    }

    @objc func player(_ player: AnyObject, stateDidChange newState: AnyObject, fromState oldState: AnyObject) {
        SponsorBlockSkipper.shared.processStateChange(player: player, state: newState)
    }

    @objc func player(_ player: AnyObject, didEncounterError error: AnyObject) {}
    @objc func player(_ player: AnyObject, didMoveToRelativeTrack relativeIndex: Int) {}
    @objc func player(_ player: AnyObject, queueDidChange queue: AnyObject) {}
}

class ProgressBarSliderHook: ClassHook<UIView> {
    typealias Group = SponsorBlockGroup
    static let targetName = "_TtCO17NowPlaying_ECMKit11ProgressBar6Slider"

    func layoutSubviews() {
        orig.layoutSubviews()
        SponsorBlockOverlay.shared.attach(to: target)
    }
}

class PlayerServiceObserverHook: ClassHook<NSObject> {
    typealias Group = SponsorBlockGroup
    /// ⚠️ ObjC 名 `SPTPlayerServiceImplementation` 在 9.1.86 上**不存在**：
    /// `.spotify-ipa/objc-classnames.txt` 里没有它，日志 8 也直接报了
    /// `[SB] activate: … class=<missing>` —— 于是这个 hook 从来没装上过，SB 永远拿不到
    /// 播放状态（`lastPlayer` 一直是 nil，连累"双击前后跳 15 秒"也一起失效）。
    /// 真名是 Swift 混淆名，来自 `dump-9.1.86.txt`：
    ///   `_TtC17Player_CommonImpl30SPTPlayerServiceImplementation`
    static let targetName = "_TtC17Player_CommonImpl30SPTPlayerServiceImplementation"

    func addPlayerObserver(_ observer: AnyObject) {
        orig.addPlayerObserver(observer)
        if !eeveeObserverRegistered {
            eeveeObserverRegistered = true
            writeDebugLog("[SB] registering observer on service")
            orig.addPlayerObserver(eeveeObserver)
        }
    }
}

struct SponsorBlockGroup: HookGroup {}

func activateSponsorBlock() {
    let opts = UserDefaults.sponsorBlockOptions
    let cls = NSClassFromString(PlayerServiceObserverHook.targetName)

    // 类找得到还不够：真正要 hook 的是 `addPlayerObserver:`。`dump-9.1.86.txt` 只给了类名、
    // 没有方法表，所以这里用 runtime 探测一次并写进日志 —— 免得再猜错第二次。
    let hasObserverSelector = cls.map {
        class_getInstanceMethod($0, Selector("addPlayerObserver:")) != nil
    } ?? false

    writeDebugLog("[SB] activate: enabled=\(opts.enabled ? "Y" : "N") logOnly=\(opts.logOnly ? "Y" : "N") cats=\(opts.enabledCategoriesArray().joined(separator: ",")) server=\(opts.serverURL) class=\(cls == nil ? "<missing>" : "<found>") addPlayerObserver=\(hasObserverSelector ? "Y" : "N")")

    if cls == nil || !hasObserverSelector {
        writeDebugLog("[SB] player observer hook cannot install — SB will not see playback state")
    }

    SponsorBlockGroup().activate()
    writeDebugLog("[SB] hook group activated")
}
