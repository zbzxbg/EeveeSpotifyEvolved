import Orion
import UIKit

/// 「实验 → 显示 Instagram 分享位」。
///
/// 上游挂 `SPTSharingSDK.canHandleShareDestination(_:)` 与两个 `SPTShare_FoundationImplProperties.isInstagram*SharingEnabled` getter —— 但那三个名字在 9.1.88 上**一个都不存在**（全文搜 0 命中），而上游 README 写的目标版本也是 9.1.88 ⇒ 上游那份在这版上是死代码，照抄只会得到一个"开了没反应"的开关。
///
/// 9.1.88 的等价物：那一族换成了 `Share_SharingSDKSwift.*ShareHandler`（Notes / Stories / 私信三个 handler），开关变成了构造 `Share_FoundationSwiftImpl.SPTShare_FoundationSwiftImplProperties` 时传进去的 6 个 BOOL：
///
/// initWithIsInstagramDirectMessageSharingEnabled:
/// isInstagramStoriesCanvasSharingEnabled:
/// isFacebookCanvasSharingEnabled:
/// isFacebookMessengerSharingEnabled:
/// isSnapchatCanvasSharingEnabled:
/// isUseractivitySharingEnabled:
///
/// ⇒ 这里 hook 那个 init，把**两个 Instagram 参数改写成 true**、其余原样传下去 —— 与上游"把那两个 getter 强写成 true"是同一件事，只是换成了这一版的形态。
///
/// ⚠️ 第二条路（更保守、不碰任何类）：`ExperimentFlagReplacements` 里强制那三条服务端 flag。
struct InstagramDestinationGroup: HookGroup { }

class SPTShareFoundationSwiftImplPropertiesHook: ClassHook<NSObject> {
    typealias Group = InstagramDestinationGroup

    /// ⚠️ 这里必须写 **Swift 重整名**：dump:6190 逐字就是它
    /// （`Share_FoundationSwiftImpl.SPTShare_FoundationSwiftImplProperties` 这种带点的写法
    /// 在 `NSClassFromString` 里查不到 —— 本仓库挂 `_TtC14Creator_ECMKit…` 那张卡时同一条教训）。
    static let targetName = "_TtC25Share_FoundationSwiftImpl38SPTShare_FoundationSwiftImplProperties"

    func initWithIsInstagramDirectMessageSharingEnabled(
        _ instagramDirectMessage: Bool,
        isInstagramStoriesCanvasSharingEnabled instagramStories: Bool,
        isFacebookCanvasSharingEnabled facebookCanvas: Bool,
        isFacebookMessengerSharingEnabled facebookMessenger: Bool,
        isSnapchatCanvasSharingEnabled snapchatCanvas: Bool,
        isUseractivitySharingEnabled useractivity: Bool
    ) -> Target {
        // 两个 Instagram 参数**只认 true**；另外四个（Facebook / Messenger / Snapchat /
        // UserActivity）保持服务端给的原值 —— 用户只要求放开 Instagram。
        return orig.initWithIsInstagramDirectMessageSharingEnabled(
            true,
            isInstagramStoriesCanvasSharingEnabled: true,
            isFacebookCanvasSharingEnabled: facebookCanvas,
            isFacebookMessengerSharingEnabled: facebookMessenger,
            isSnapchatCanvasSharingEnabled: snapchatCanvas,
            isUseractivitySharingEnabled: useractivity
        )
    }
}

/// 装之前先问一句"**这个类、这个方法在不在**"（与 `EeveeAdBlockerExtended` /
/// CarPlayCrashFix 同一个套路）：对不上就只打一行日志 —— 不让 Orion 去解析一个不存在的名字。
enum InstagramShareDestination {

    static let className = "_TtC25Share_FoundationSwiftImpl38SPTShare_FoundationSwiftImplProperties"

    /// dump:26180 的那条选择器（6 个 BOOL）。
    static let initSelector = NSSelectorFromString(
        "initWithIsInstagramDirectMessageSharingEnabled:"
            + "isInstagramStoriesCanvasSharingEnabled:"
            + "isFacebookCanvasSharingEnabled:"
            + "isFacebookMessengerSharingEnabled:"
            + "isSnapchatCanvasSharingEnabled:"
            + "isUseractivitySharingEnabled:"
    )

    static func activateIfNeeded() {
        guard UserDefaults.experimentsOptions.showInstagramDestination else { return }

        guard let cls = NSClassFromString(className),
              class_getInstanceMethod(cls, initSelector) != nil else {
            writeDebugLog(
                "[Instagram] share-destination properties class/method missing — nothing hooked"
                    + " (Spotify changed the sharing SDK again; the flag rewrite alone stays in effect)"
            )
            return
        }

        InstagramDestinationGroup().activate()
        writeDebugLog(
            "[Instagram] share-destination hook on — Instagram Stories / direct message forced on"
                + " at initWithIsInstagram… (dump:26180)"
        )
    }
}
