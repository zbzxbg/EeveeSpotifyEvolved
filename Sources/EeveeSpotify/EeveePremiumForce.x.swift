import Foundation
import Orion

private let oneYearFromNowISO: String = {
    let d = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date().addingTimeInterval(31_536_000)
    let f = ISO8601DateFormatter(); f.timeZone = TimeZone(abbreviation: "UTC")
    return f.string(from: d)
}()

private func forcedPremiumString(forKey key: String) -> String? {
    switch key {
    case "type":                                   return "premium"
    case "catalogue":                              return "premium"
    case "product":                                return "premium"
    case "name":                                   return "Spotify Premium"
    case "player-license":                         return "premium"
    case "player-license-v2":                      return "premium"
    case "financial-product":                      return "pr:premium,tc:0"

    case "ads":                                    return "0"
    case "ab-ad-player-targeting":                 return "0"
    case "allow-advertising-id-transmission":      return "0"
    case "restrict-advertising-id-transmission":   return "1"
    case "audio-ad-frequency":                     return "0"
    case "video-ad-frequency":                     return "0"
    case "ad-formats":                             return ""

    case "on-demand":                              return "1"
    case "unrestricted":                           return "1"
    case "shuffle-eligible":                       return "1"
    case "social-connect":                         return "1"
    case "tracks-in-collection-enabled":           return "1"
    case "is-eligible-premium-unboxing":           return "1"
    case "can_use_superbird":                      return "1"
    case "manager":                                return "1"
    case "nft-disabled":                           return "1"

    case "streaming-rules":                        return ""
    case "previous-streaming-rules":               return ""
    case "high-bitrate":                           return "1"
    case "shuffle":                                return "0"
    case "shuffle-mode":                           return "0"
    case "pick-and-shuffle":                       return "0"

    case "subscription-enddate":                   return oneYearFromNowISO
    case "product-expiry":                         return oneYearFromNowISO
    case "trial-ends-at":                          return "9999999999"
    case "current-period-end":                     return "9999999999"
    case "premium-promotion-eligible":             return "0"
    case "payments-initial-campaign":              return "default"

    // Server pushes these to trigger ForcedLogoutDaemon / AccessTokenRevokerDaemon.
    case "forced_logout":                          return ""
    case "forced_logout_abroad_since":             return ""
    case "force_logout":                           return ""
    case "logout_required":                        return "0"
    case "session_invalidated":                    return "0"

    // Never spoof — would break server geo.
    case "country":                                return nil

    default:                                       return nil
    }
}

private let stripKeys: Set<String> = [
    "payment-state",
    "last-premium-activation-date",
    "on-demand-trial",
    "on-demand-trial-in-progress",
    "smart-shuffle",
]

private func rewritePremiumDict(_ dict: NSDictionary) -> NSDictionary {
    let mutable = NSMutableDictionary(dictionary: dict)
    var changed = 0

    for k in stripKeys {
        if mutable[k] != nil { mutable.removeObject(forKey: k); changed += 1 }
    }

    for (k, _) in dict {
        guard let key = k as? String, let forced = forcedPremiumString(forKey: key) else { continue }
        let cur = mutable[key] as? String
        if cur != forced { mutable[key] = forced; changed += 1 }
    }

    // Over-seeding caused greyed-out tracks (streaming-rules mismatch).
    // Only seed the safe core set; dates and logout keys override-only.
    let seedAlways = [
        "type", "catalogue", "product",
        "ads", "on-demand", "unrestricted", "shuffle-eligible",
        "player-license", "player-license-v2",
    ]
    for k in seedAlways {
        if mutable[k] == nil, let v = forcedPremiumString(forKey: k) {
            mutable[k] = v
            changed += 1
        }
    }

    if changed > 0 {
        eeveeSanitizedNSLog("[FORCE][PS.dict] rewrote \(changed) keys (in=\(dict.count) out=\(mutable.count))")
    }
    return mutable
}

private let premiumWatchKeys: [String] = [
    "type", "catalogue", "product", "name",
    "ads", "audio-ad-frequency", "video-ad-frequency",
    "on-demand", "unrestricted", "shuffle-eligible",
    "player-license", "player-license-v2",
    "subscription-enddate", "product-expiry",
    "forced_logout", "forced_logout_abroad_since", "force_logout",
    "logout_required", "session_invalidated",
    "payment-state", "last-premium-activation-date",
    "country", "financial-product",
]

private func passiveLogProductState(_ tag: String, _ dict: NSDictionary) {
    var pairs: [String] = []
    for k in premiumWatchKeys {
        guard let v = dict[k] else { continue }

        // ⚠️ 2026-09-30：`name` 是这一批里**唯一可能带账号信息**的一项，而它到底是
        // "商品名"还是"账号显示名"从代码里定不死（真机日志也没定过性）—— 于是保留
        // "这一项在不在"这个判据，值一律不打。其余项（type / product / country /
        // 日期 / forced_logout…）都是排查自动登出要看的，原样保留。
        pairs.append(k == "name" ? "name=<redacted>" : "\(k)=\(v)")
    }
    if !pairs.isEmpty {
        // 走 `eeveeSanitizedNSLog`：这条 NSLog 不受「启用日志记录」开关控制，
        // 脱敏不能漏（见 `DebugLogSanitizer` 的说明）。
        let line = "[REVERT_WATCH][\(tag)] \(pairs.joined(separator: " "))"
        eeveeSanitizedNSLog(line)
        // ⚠️ 2026-10-02 追加：**同一行也进导出文件**。
        // 排查"整库变黑 / 听不了歌"时，产品状态（ads / on-demand / unrestricted /
        // player-license / catalogue …）有没有被服务端改回去，是**唯一**的本地判据；
        // 而它原先只走 NSLog，导出来的 `eeveespotify_debug_shared*.log` 里根本看不到。
        // `writeDebugLog` 内部自己会过 `DebugLogSanitizer`，所以脱敏不漏。
        writeDebugLog(line)
    } else if dict.count > 0 {
        let line = "[REVERT_WATCH][\(tag)] keys=\(dict.count) (no premium-relevant)"
        eeveeSanitizedNSLog(line)
        writeDebugLog(line)
    }
}

class CoreProductStateHook: ClassHook<NSObject> {
    typealias Group = EeveePremiumForceGroup
    static let targetName = "SPTCoreProductState"

    func setOriginalValues(_ dict: NSDictionary) {
        passiveLogProductState("setOriginal", dict)
        orig.setOriginalValues(enableDictRewrite ? rewritePremiumDict(dict) : dict)
    }

    func setOverrides(_ dict: NSDictionary) {
        passiveLogProductState("setOverrides", dict)
        orig.setOverrides(enableDictRewrite ? rewritePremiumDict(dict) : dict)
    }

    func initWithValuesDict(_ dict: NSDictionary, scheduler: UnsafeRawPointer) -> Any {
        // ★ 2026-10-02 补：**初始那一次也要打**。
        //
        // 以前只有 `setOriginalValues:` / `setOverrides:` 会打 —— 于是"启动之后没再被改过"
        // 的会话里 `[REVERT_WATCH]` **一行都没有**，排查"整库变黑 / 听不了歌"时反而没有判据
        // （日志 30 就是这样：0 行，H2 与 H1/H3 分不开）。
        // 打的是**改写前**的原始字典：要看的就是"服务端给的是什么档"。
        passiveLogProductState("init", dict)
        let d = enableDictRewrite ? rewritePremiumDict(dict) : dict
        return orig.initWithValuesDict(d, scheduler: scheduler)
    }

    func stringForKey(_ key: NSString) -> NSString? {
        if enableDirectGetters, let forced = forcedPremiumString(forKey: key as String) {
            return forced as NSString
        }
        return orig.stringForKey(key)
    }

    func objectForKeyedSubscript(_ key: NSString) -> Any? {
        if enableDirectGetters, let forced = forcedPremiumString(forKey: key as String) {
            return forced as NSString
        }
        return orig.objectForKeyedSubscript(key)
    }

    func values() -> NSDictionary {
        let d = orig.values()
        return enableDictRewrite ? rewritePremiumDict(d) : d
    }

    func originalValues() -> NSDictionary {
        let d = orig.originalValues()
        return enableDictRewrite ? rewritePremiumDict(d) : d
    }

    func valuesDictFromMap(_ map: UnsafeRawPointer) -> NSDictionary {
        let d = orig.valuesDictFromMap(map)
        return enableDictRewrite ? rewritePremiumDict(d) : d
    }

    func valuesDictFromChangedKeys(_ keys: UnsafeRawPointer) -> NSDictionary {
        let d = orig.valuesDictFromChangedKeys(keys)
        return enableDictRewrite ? rewritePremiumDict(d) : d
    }
}

class AdsProductStateHook: ClassHook<NSObject> {
    typealias Group = EeveePremiumForceGroup
    static let targetName = "SPTAdsProductState"

    func adsEnabled() -> Bool {
        return enableAdsHook ? false : orig.adsEnabled()
    }
}

private func swizzleObjectGetter(_ cls: AnyClass, _ name: String, _ value: @escaping () -> AnyObject) {
    let sel = sel_registerName(name)
    let block: @convention(block) (AnyObject) -> AnyObject = { _ in value() }
    let imp = imp_implementationWithBlock(block)
    class_replaceMethod(cls, sel, imp, "@@:")
}

private func swizzleIntGetter(_ cls: AnyClass, _ name: String, _ value: Int) {
    let sel = sel_registerName(name)
    let block: @convention(block) (AnyObject) -> Int = { _ in value }
    let imp = imp_implementationWithBlock(block)
    class_replaceMethod(cls, sel, imp, "q@:")
}

private func swizzleBoolGetter(_ cls: AnyClass, _ name: String, _ value: Bool) {
    let sel = sel_registerName(name)
    let block: @convention(block) (AnyObject) -> Bool = { _ in value }
    let imp = imp_implementationWithBlock(block)
    class_replaceMethod(cls, sel, imp, "B@:")
}

struct EeveePremiumForceGroup: HookGroup {}

private let enableDictRewrite = false
private let enableDirectGetters = false
private let enableAdsHook = false
private let enablePassiveProductStateLog = true

func activateEeveePremiumForce() {
    NSLog("[FORCE] activating dict=%@ getters=%@ ads=%@ passiveLog=%@",
          enableDictRewrite   ? "on" : "off",
          enableDirectGetters ? "on" : "off",
          enableAdsHook       ? "on" : "off",
          enablePassiveProductStateLog ? "on" : "off")
    guard enableDictRewrite || enableDirectGetters || enableAdsHook || enablePassiveProductStateLog else {
        return
    }
    // This ran completely unguarded before - unlike every other hook group in this
    // codebase - so a Spotify build that renames/removes one of these methods would
    // fail the hook and (pre handleError override) instantly crash at launch.
    guard NSClassFromString("SPTCoreProductState") != nil else {
        NSLog("[FORCE] Skipped: SPTCoreProductState not found")
        return
    }
    EeveePremiumForceGroup().activate()
}
