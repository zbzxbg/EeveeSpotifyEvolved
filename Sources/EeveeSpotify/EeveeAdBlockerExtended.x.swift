// TESTING: extended ad blocker for Swift Service-based ad surfaces
// (Evo home brand-ads, NPV under-player ad, in-stream audio, native ads).
// Hooks SPTService -load on each ad service and skips orig so the service
// stays inert. Per-surface bool flips below if one needs disabling.
// In-stream audio additionally goes through the player core's own URLSession,
// which never reaches those services — see `CoreURLSessionAdsKill`.

import Orion
import Foundation
import UIKit

// Every service has its own group. Spotify rolls these modules out
// independently, so one missing/renamed class must not disable the rest of the
// blocker on sideloaded/rootless builds either.
struct AdsServiceImplGroup: HookGroup {}
struct InStreamAdsServiceGroup: HookGroup {}
struct EmbeddedNPVServiceGroup: HookGroup {}
struct LeavebehindAdsBaseServiceGroup: HookGroup {}
struct LeavebehindAdsBaseInternalServiceGroup: HookGroup {}
struct SponsoredContextServiceGroup: HookGroup {}
struct SponsoredContextNPBAttachmentServiceGroup: HookGroup {}
struct SponsoredPlaylistHeaderServiceGroup: HookGroup {}
struct SponsoredPlaylistHeaderViewGroup: HookGroup {}
struct NativeAdsLoggerServiceGroup: HookGroup {}
struct SponsoredCtxAttachmentGroup: HookGroup {}
/// 播放器 core 自己的 URLSession（`SPTCoreURLSessionDataDelegate`）—— 语音广告走这条。
struct CoreURLSessionAdsGroup: HookGroup {}

private let killAdsServiceImpl         = true
private let killInStreamAdsService     = true
private let killEmbeddedNPVService     = true
private let killNativeAdsLoggerService = true
private let killSponsoredCtxAttachment = true
private let logAdBlockerEvents         = true

@inline(__always)
private func adlog(_ what: String) {
    if logAdBlockerEvents { NSLog("[EeveeSpotify][AdBlock] suppressed %@", what) }
}

class AdsServiceImplKill: ClassHook<NSObject> {
    typealias Group = AdsServiceImplGroup
    static let targetName: String = "_TtC19AdsPlatform_AdsImpl14AdsServiceImpl"
    func load() {
        if killAdsServiceImpl { adlog("AdsServiceImpl.load"); return }
        orig.load()
    }
}

class InStreamAdsServiceKill: ClassHook<NSObject> {
    typealias Group = InStreamAdsServiceGroup
    static let targetName: String = "_TtC29AdsNowPlaying_InStreamAdsImpl18InStreamAdsService"
    func load() {
        if killInStreamAdsService { adlog("InStreamAdsService.load"); return }
        orig.load()
    }
}

class EmbeddedNPVServiceImplKill: ClassHook<NSObject> {
    typealias Group = EmbeddedNPVServiceGroup
    static let targetName: String = "_TtC29AdsNowPlaying_EmbeddedNPVImpl22EmbeddedNPVServiceImpl"
    func load() {
        if killEmbeddedNPVService { adlog("EmbeddedNPVServiceImpl.load"); return }
        orig.load()
    }
}

// Spotify 9.1.66+ can render the under-player card through a separate
// "unified leavebehind" pipeline. It does not depend on EmbeddedNPVServiceImpl.
class LeavebehindAdsBaseServiceKill: ClassHook<NSObject> {
    typealias Group = LeavebehindAdsBaseServiceGroup
    static let targetName: String =
        "_TtC36AdsStandalone_LeavebehindAdsBaseImpl25LeavebehindAdsBaseService"

    func load() {
        adlog("LeavebehindAdsBaseService.load")
        return
    }
}

class LeavebehindAdsBaseInternalServiceKill: ClassHook<NSObject> {
    typealias Group = LeavebehindAdsBaseInternalServiceGroup
    static let targetName: String =
        "_TtC36AdsStandalone_LeavebehindAdsBaseImpl33LeavebehindAdsBaseInternalService"

    func load() {
        adlog("LeavebehindAdsBaseInternalService.load")
        return
    }
}

// Native sponsored surfaces are separate from AdsServiceImpl in 9.1.x.
// Blocking their SPTService entry points keeps sponsored headers and the
// Now Playing Bar attachment from being constructed at all.
class SponsoredContextServiceKill: ClassHook<NSObject> {
    typealias Group = SponsoredContextServiceGroup
    static let targetName =
        "_TtC35AdsEmbedded_AdsSponsoredContextImpl30AdsSponsoredContextServiceImpl"

    func load() {
        adlog("AdsSponsoredContextServiceImpl.load")
        return
    }
}

class SponsoredContextNPBAttachmentServiceKill: ClassHook<NSObject> {
    typealias Group = SponsoredContextNPBAttachmentServiceGroup
    static let targetName =
        "_TtC48AdsEmbedded_AdsSponsoredContextNPBAttachmentImpl43AdsSponsoredContextNPBAttachmentServiceImpl"

    func load() {
        adlog("AdsSponsoredContextNPBAttachmentServiceImpl.load")
        return
    }
}

class SponsoredPlaylistHeaderServiceKill: ClassHook<NSObject> {
    typealias Group = SponsoredPlaylistHeaderServiceGroup
    static let targetName =
        "_TtC42AdsEmbedded_AdsSponsoredPlaylistHeaderImpl37AdsSponsoredPlaylistHeaderServiceImpl"

    func load() {
        adlog("AdsSponsoredPlaylistHeaderServiceImpl.load")
        return
    }
}

// Rendering fallback for a sponsored header that was already materialized
// before its service hook became active. Generic Spotify banners stay intact.
class SponsoredPlaylistHeaderViewKill: ClassHook<UIView> {
    typealias Group = SponsoredPlaylistHeaderViewGroup
    static let targetName =
        "_TtC18AdsPlatform_ECMKit37AdsSponsoredPlaylistHeaderCentralView"

    func didMoveToSuperview() {
        orig.didMoveToSuperview()
        target.isHidden = true
        target.isUserInteractionEnabled = false
        if target.superview != nil {
            adlog("AdsSponsoredPlaylistHeaderCentralView")
            target.removeFromSuperview()
        }
    }
}

class NativeAdsLoggerServiceImplKill: ClassHook<NSObject> {
    typealias Group = NativeAdsLoggerServiceGroup
    static let targetName: String = "_TtC20NativeAds_LoggerImpl26NativeAdsLoggerServiceImpl"
    func load() {
        if killNativeAdsLoggerService { adlog("NativeAdsLoggerServiceImpl.load"); return }
        orig.load()
    }
}

// Passive log only — returning nil from init would crash the alloc chain.
// Upstream events are starved by killing AdsServiceImpl above.
class SponsoredCtxAttachmentProbe: ClassHook<NSObject> {
    typealias Group = SponsoredCtxAttachmentGroup
    static let targetName: String =
        "_TtC48AdsEmbedded_AdsSponsoredContextNPBAttachmentImpl25AdModelChangedEventSource"
    func `init`() -> Target {
        if killSponsoredCtxAttachment {
            adlog("SponsoredCtxAttachment.init (passive)")
        }
        return orig.`init`()
    }
}

// In-stream audio ads. The player core does its HTTP through its own
// `SPTCoreURLSessionDataDelegate`, not through SPTDataLoaderService or
// HttpClientURLSession, so the `/ads/` and `/ad-logic/` rules in
// `URL+Extension.isAdRelated` never see the core's ad-break requests
// (`ads/v3/ads`, `ad-logic/prefetch`, `ad-logic/v3/config`, ...). Cancelling the
// response makes the core treat the ad fetch as failed and skip the break.
//
// Deliberately narrower than `isAdRelated`: this delegate carries everything the
// core fetches, so only the two ad path families are cancelled and every other
// request is forwarded untouched.
private func isCoreAdRequest(_ url: URL) -> Bool {
    let host = (url.host ?? "").lowercased()
    guard host.contains("spotify") || host.contains("spclient") else { return false }
    let path = url.path.lowercased()
    return path.contains("/ads/") || path.hasSuffix("/ads") || path.contains("/ad-logic/")
}

/// 取消次数：日志只留前几条，避免长播客里刷屏。
private var coreAdRequestCancelled = 0

class CoreURLSessionAdsKill: ClassHook<NSObject> {
    typealias Group = CoreURLSessionAdsGroup
    static let targetName: String = "SPTCoreURLSessionDataDelegate"

    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveResponse response: URLResponse,
        completionHandler handler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let url = task.currentRequest?.url ?? task.originalRequest?.url, isCoreAdRequest(url) {
            coreAdRequestCancelled += 1
            if coreAdRequestCancelled <= 5 || coreAdRequestCancelled % 20 == 0 {
                writeDebugLog(
                    "[AdBlock] cancelled core ad request #\(coreAdRequestCancelled): "
                        + "\(url.host ?? "?")\(url.path)"
                )
            }
            adlog("core request \(url.host ?? "?")\(url.path)")
            handler(.cancel)
            return
        }
        orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
    }
}

func activateEeveeAdBlockerExtended() {
    let loadSelector = Selector(("load"))
    let initSelector = Selector(("init"))

    let loadTargets: [(String, String, () -> Void)] = [
        (AdsServiceImplKill.targetName, "AdsServiceImpl", { AdsServiceImplGroup().activate() }),
        (InStreamAdsServiceKill.targetName, "InStreamAdsService", { InStreamAdsServiceGroup().activate() }),
        (EmbeddedNPVServiceImplKill.targetName, "EmbeddedNPVServiceImpl", { EmbeddedNPVServiceGroup().activate() }),
        (LeavebehindAdsBaseServiceKill.targetName, "LeavebehindAdsBaseService", { LeavebehindAdsBaseServiceGroup().activate() }),
        (LeavebehindAdsBaseInternalServiceKill.targetName, "LeavebehindAdsBaseInternalService", { LeavebehindAdsBaseInternalServiceGroup().activate() }),
        (SponsoredContextServiceKill.targetName, "AdsSponsoredContextServiceImpl", { SponsoredContextServiceGroup().activate() }),
        (SponsoredContextNPBAttachmentServiceKill.targetName, "AdsSponsoredContextNPBAttachmentServiceImpl", { SponsoredContextNPBAttachmentServiceGroup().activate() }),
        (SponsoredPlaylistHeaderServiceKill.targetName, "AdsSponsoredPlaylistHeaderServiceImpl", { SponsoredPlaylistHeaderServiceGroup().activate() }),
        (NativeAdsLoggerServiceImplKill.targetName, "NativeAdsLoggerServiceImpl", { NativeAdsLoggerServiceGroup().activate() }),
    ]

    var activated = 0
    for (className, label, activate) in loadTargets {
        guard let cls = NSClassFromString(className),
              class_getInstanceMethod(cls, loadSelector) != nil else {
            NSLog("[EeveeSpotify][AdBlock] %@/load unavailable; skipping", label)
            continue
        }
        activate()
        activated += 1
        NSLog("[EeveeSpotify][AdBlock] %@ hook activated", label)
    }

    if let cls = NSClassFromString(SponsoredCtxAttachmentProbe.targetName),
       class_getInstanceMethod(cls, initSelector) != nil {
        SponsoredCtxAttachmentGroup().activate()
        activated += 1
        NSLog("[EeveeSpotify][AdBlock] SponsoredCtxAttachment hook activated")
    } else {
        NSLog("[EeveeSpotify][AdBlock] SponsoredCtxAttachment/init unavailable; skipping")
    }

    let viewSelector = Selector(("didMoveToSuperview"))
    if let cls = NSClassFromString(SponsoredPlaylistHeaderViewKill.targetName) as? UIView.Type,
       class_getInstanceMethod(cls, viewSelector) != nil {
        SponsoredPlaylistHeaderViewGroup().activate()
        activated += 1
        NSLog("[EeveeSpotify][AdBlock] SponsoredPlaylistHeader view fallback activated")
    } else {
        NSLog("[EeveeSpotify][AdBlock] SponsoredPlaylistHeader view unavailable; skipping")
    }

    // 播放器 core 的语音广告：类在、且真的实现了那个 delegate 方法才装。
    // 只给类名不够 —— 9.1.x 上 delegate 的签名改过名的先例有过，这里用 runtime 探一次。
    let responseSelector = Selector(("URLSession:dataTask:didReceiveResponse:completionHandler:"))
    if let cls = NSClassFromString(CoreURLSessionAdsKill.targetName),
       class_getInstanceMethod(cls, responseSelector) != nil {
        CoreURLSessionAdsGroup().activate()
        activated += 1
        NSLog("[EeveeSpotify][AdBlock] core URLSession ad requests hook activated")
        writeDebugLog("[AdBlock] core URLSession ad requests hook activated")
    } else {
        NSLog("[EeveeSpotify][AdBlock] core URLSession ad requests unavailable; skipping")
        writeDebugLog(
            "[AdBlock] core URLSession ad requests unavailable"
                + " — SPTCoreURLSessionDataDelegate or its response delegate method is missing"
        )
    }

    NSLog("[EeveeSpotify][AdBlock] activated %d/%d compatible extended hooks",
          activated, loadTargets.count + 3)
}
