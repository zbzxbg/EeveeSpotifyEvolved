import Foundation

/// 「实验」页里那些**靠强制服务端 flag 落地**的实验（目前只有「显示 Instagram 分享位」）。
///
/// ## 为什么是 flag，不是 hook
///
/// 老实现删掉的那个）挂的是 `SPTSharingSDK` 与 `SPTShare_FoundationImplProperties`
/// —— 那两个类**只在 Spotify 9.1.0 上存在**，在 9.1.86/9.1.88 上永远不可能生效。
/// 9.1.88 里这一族换成了 `Share_SharingSDKSwift.*ShareHandler`
/// （dump 3220 / 3226 / 3228：`…InstagramNotesShareHandler` / `…InstagramStoriesShareHandler` /
/// `…InstagramDirectMessageShareHandler`），而**开关本身变成了服务端 flag**
/// （IPA 的 flag 表）。
///
/// ⇒ 与其去猜那些 Swift 类的私有方法名（猜错就是崩或静默无效），不如直接强制那三条 flag：
/// 走的是**同一条**已经用了几个月的替换管线（`propertyReplacements + 这里 + 用户的 Flag 覆盖`），
/// 每一步都有 `[Flags] override … N match(es)` 的日志可对账。
///
/// | scope | name | 9.1.88 随包快照里有没有 |
/// | `ios-feature-share` | `is_instagram_direct_message_sharing_enabled` | **有** |
/// | `ios-share-destinationhandler-impl` | `is_instagram_notes_enabled` | **有** |
/// | `ios-feature-share-menu` | `is_instagram_stories_canvas_sharing_enabled` | 只有 scope，没这条（`.forceBool` 会补一条） |
///
/// ⚠️ 三条副作用要说清楚：
/// ① 生效时机 = **启动时改写配置** ⇒ 改开关后要**重启 Spotify**（与 flag 一致）；
/// ② Flag 覆盖里写的同名条目**仍然压得过**它（数组顺序 = 应用顺序，用户在最后）；
/// ③ 第三条快照里没有 ⇒ 补出来的那条**效果未知**。
enum ExperimentFlagReplacements {

    /// Instagram 那三条 flag。**只在实验开着时才存在**，关着返回空数组
    /// ⇒ 关掉之后连"补一条"都不会做，行为与从前逐字一致。
    static var active: [EeveePropertyReplacement] {
        guard UserDefaults.experimentsOptions.showInstagramDestination else { return [] }

        return [
            EeveePropertyReplacement(
                name: "is_instagram_direct_message_sharing_enabled",
                scope: "ios-feature-share",
                modification: .forceBool(true)
            ),
            EeveePropertyReplacement(
                name: "is_instagram_notes_enabled",
                scope: "ios-share-destinationhandler-impl",
                modification: .forceBool(true)
            ),
            EeveePropertyReplacement(
                name: "is_instagram_stories_canvas_sharing_enabled",
                scope: "ios-feature-share-menu",
                modification: .forceBool(true)
            ),
        ]
    }
}
