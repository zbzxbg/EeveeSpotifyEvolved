// TESTING: extended ad blocker for Swift Service-based ad surfaces
// (Evo home brand-ads, NPV under-player ad, in-stream audio, native ads).
// Hooks SPTService -load on each ad service and skips orig so the service
// stays inert. Per-surface bool flips below if one needs disabling.
// In-stream audio additionally goes through the player core's own URLSession,
// which never reaches those services — see `CoreURLSessionAdsKill`.
//
// 9.1.88 moved ad delivery into standalone Swift services across the
// AdsPlatform / AdsStandalone / AdsEmbedded / NativeAds / Betamax modules.
// Those services still load, so the player is handed a slot to fill even when
// every ad HTTP request is cancelled; each one is killed at load() below.

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
struct RealTimeAdControllerServiceGroup: HookGroup {}
struct AdsBaseSwiftServiceGroup: HookGroup {}
struct AudioAdPiPCoordinatorServiceGroup: HookGroup {}
struct AdsInstrumentationServiceGroup: HookGroup {}
struct AdsElementServiceGroup: HookGroup {}
struct RewardedAdFetchControllerServiceGroup: HookGroup {}
struct AdOnAppOpenServiceGroup: HookGroup {}
struct EmbeddedCTACardsServiceGroup: HookGroup {}
struct EmbeddedPlaylistServiceGroup: HookGroup {}
struct NativeAdsElementServiceGroup: HookGroup {}
struct OnDemandAdEventLoggerServiceGroup: HookGroup {}
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

// Spotify 9.1.88 real-time ad controller and the sibling Swift services behind
// in-stream and embedded ads. Their load() hands the player a slot to fill, so
// the break survives even after the ad HTTP requests are cancelled. Each one
// gets its own group: a class missing from a build only drops that service.
class RealTimeAdControllerServiceKill: ClassHook<NSObject> {
    typealias Group = RealTimeAdControllerServiceGroup
    static let targetName =
        "_TtC36AdsPlatform_RealTimeAdControllerImpl31RealTimeAdControllerServiceImpl"

    func load() {
        adlog("RealTimeAdControllerServiceImpl.load")
    }
}

class AdsBaseSwiftServiceKill: ClassHook<NSObject> {
    typealias Group = AdsBaseSwiftServiceGroup
    static let targetName =
        "_TtC28AdsPlatform_AdsBaseSwiftImpl23AdsBaseSwiftServiceImpl"

    func load() {
        adlog("AdsBaseSwiftServiceImpl.load")
    }
}

class AudioAdPiPCoordinatorServiceKill: ClassHook<NSObject> {
    typealias Group = AudioAdPiPCoordinatorServiceGroup
    static let targetName =
        "_TtC46Betamax_AudioAdPictureInPictureCoordinatorImpl41AudioAdPictureInPictureCoordinatorService"

    func load() {
        adlog("AudioAdPictureInPictureCoordinatorService.load")
    }
}

class AdsInstrumentationServiceKill: ClassHook<NSObject> {
    typealias Group = AdsInstrumentationServiceGroup
    static let targetName =
        "_TtC34AdsPlatform_AdsInstrumentationImpl29AdsInstrumentationServiceImpl"

    func load() {
        adlog("AdsInstrumentationServiceImpl.load")
    }
}

class AdsElementServiceKill: ClassHook<NSObject> {
    typealias Group = AdsElementServiceGroup
    static let targetName =
        "_TtC23AdsPlatform_ElementImpl18ElementServiceImpl"

    func load() {
        adlog("ElementServiceImpl.load")
    }
}

class RewardedAdFetchControllerServiceKill: ClassHook<NSObject> {
    typealias Group = RewardedAdFetchControllerServiceGroup
    static let targetName =
        "_TtC28AdsStandalone_RewardedAdImpl32RewardedAdFetchControllerService"

    func load() {
        adlog("RewardedAdFetchControllerService.load")
    }
}

class AdOnAppOpenServiceKill: ClassHook<NSObject> {
    typealias Group = AdOnAppOpenServiceGroup
    static let targetName =
        "_TtC29AdsStandalone_AdOnAppOpenImpl22AdOnAppOpenServiceImpl"

    func load() {
        adlog("AdOnAppOpenServiceImpl.load")
    }
}

class EmbeddedCTACardsServiceKill: ClassHook<NSObject> {
    typealias Group = EmbeddedCTACardsServiceGroup
    static let targetName =
        "_TtC32AdsEmbedded_EmbeddedCTACardsImpl23EmbeddedCTACardsService"

    func load() {
        adlog("EmbeddedCTACardsService.load")
    }
}

class EmbeddedPlaylistServiceKill: ClassHook<NSObject> {
    typealias Group = EmbeddedPlaylistServiceGroup
    static let targetName =
        "_TtC32AdsEmbedded_EmbeddedPlaylistImpl27EmbeddedPlaylistServiceImpl"

    func load() {
        adlog("EmbeddedPlaylistServiceImpl.load")
    }
}

class NativeAdsElementServiceKill: ClassHook<NSObject> {
    typealias Group = NativeAdsElementServiceGroup
    static let targetName =
        "_TtC21NativeAds_ElementImpl27NativeAdsElementServiceImpl"

    func load() {
        adlog("NativeAdsElementServiceImpl.load")
    }
}

// No 9.1.88 symbol carries this name; the runtime guard skips it on that build.
class OnDemandAdEventLoggerServiceKill: ClassHook<NSObject> {
    typealias Group = OnDemandAdEventLoggerServiceGroup
    static let targetName =
        "_TtC28AdsStandalone_RewardedAdImpl28OnDemandAdEventLoggerService"

    func load() {
        adlog("OnDemandAdEventLoggerService.load")
    }
}

// In-stream audio ads. The player core does its HTTP through its own
// `SPTCoreURLSessionDataDelegate`, not through SPTDataLoaderService or
// HttpClientURLSession, so the response hooks never see its ad-break requests
// (`ads/v3/ads`, `ad-logic/prefetch`, `ad-logic/v3/config`, ...). Cancelling the
// response makes the core treat the ad fetch as failed and skip the break.
//
// Same `isAdRelated` predicate as the rest of the tweak: the previous local
// copy was narrower and drifted, so it missed the bare `/ads` endpoints.
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
        if let url = task.currentRequest?.url ?? task.originalRequest?.url, url.isAdRelated {
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
        (RealTimeAdControllerServiceKill.targetName, "RealTimeAdControllerServiceImpl", { RealTimeAdControllerServiceGroup().activate() }),
        (AdsBaseSwiftServiceKill.targetName, "AdsBaseSwiftServiceImpl", { AdsBaseSwiftServiceGroup().activate() }),
        (AudioAdPiPCoordinatorServiceKill.targetName, "AudioAdPictureInPictureCoordinatorService", { AudioAdPiPCoordinatorServiceGroup().activate() }),
        (AdsInstrumentationServiceKill.targetName, "AdsInstrumentationServiceImpl", { AdsInstrumentationServiceGroup().activate() }),
        (AdsElementServiceKill.targetName, "ElementServiceImpl", { AdsElementServiceGroup().activate() }),
        (RewardedAdFetchControllerServiceKill.targetName, "RewardedAdFetchControllerService", { RewardedAdFetchControllerServiceGroup().activate() }),
        (AdOnAppOpenServiceKill.targetName, "AdOnAppOpenServiceImpl", { AdOnAppOpenServiceGroup().activate() }),
        (EmbeddedCTACardsServiceKill.targetName, "EmbeddedCTACardsService", { EmbeddedCTACardsServiceGroup().activate() }),
        (EmbeddedPlaylistServiceKill.targetName, "EmbeddedPlaylistServiceImpl", { EmbeddedPlaylistServiceGroup().activate() }),
        (NativeAdsElementServiceKill.targetName, "NativeAdsElementServiceImpl", { NativeAdsElementServiceGroup().activate() }),
        (OnDemandAdEventLoggerServiceKill.targetName, "OnDemandAdEventLoggerService", { OnDemandAdEventLoggerServiceGroup().activate() }),
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
