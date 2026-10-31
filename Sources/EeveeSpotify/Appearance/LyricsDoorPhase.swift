import Foundation

/// 「歌词进播放器」这一层**展开到哪一步** —— 相位机与三条窗口的判定规则。
///
/// ## 为什么要有它
///
/// 这件事原来散在六个旗标里（`isOpen` / `wantsOpen` / `wantsOpenUntil` / `pendingOpenUntil` /
/// `pageLeaving` / `coverGeneration`），而且**同一条判据在七八处各写一遍**：
/// 「屏幕上真有我们的东西」= `coverHost != nil || lastContainer != nil` —— 每修一次回归，
/// 就又有一处要跟着多 OR 一个旗标。
/// ⇒ 这里把"什么组合算哪一相"收成**唯一一处**，而且它是**可测的**：
/// `Tests/LyricsDoorPhase/main.swift` 把转换表钉住，CI 每次 push 都跑
/// （`.github/workflows/tests.yml`；本仓库本机没有 Swift 工具链，那是唯一的编译反馈）。
///
/// ## 两件**不是**相位的东西（故意留在外面）
///
/// * `pageLeaving` —— 它不是"展开到哪一步"，而是"页面还在屏上、但正在走"：退出转场里我们
/// **故意什么都不收**，好让整个动画都是我们的样子。它只作为 `.closing` 的来源出现在相位里，
/// 而"该不该收尾"另有一条 `needsPageTeardown`。
/// * `coverGeneration` —— 异步收尾的**取消令牌**（动画没走完又被点开 ⇒ 这一次收尾作废），
/// 与相位无关，不该塞进同一个枚举。
///
/// ## ⚠️ `isOpen` 是一个**会撒谎**的旗标
///
/// 它在 `openAndMount` 里是"**尝试**铺的那一瞬间"就置 `true` 的（铺失败才回退），
/// 而 `wasLive` 那条路会让它对"屏上什么都没有"的状态也说 `true`。
/// 所以 `isOpen == true` **不等于**开着 —— 四个读取点（`apply` 的残留守卫、`reconcile` 的
/// 半成品护栏、`toggle` 的折叠判据、单行歌词的 `!isOpen`）各自想要的东西并不一样。
/// `phase` 因此**不看** `isOpen`：它只在明确表达"我们可能改过东西"的那两条判据里单独留下。
enum LyricsDoorPhase: Equatable {
    /// 关：没有意图，也没铺上任何东西。
    case closed
    /// 展开中：有意图（刚点开 / 记忆重进），但这一拍还没铺上。
    case opening
    /// 开着：我们自己的封面或歌词容器**在屏上**。
    case open
    /// 收起中：页面还在屏上、但正在离开（这一段时间里保持现状）。
    case closing
}

/// 判定规则（全是纯函数，输入全是值 —— 所以能脱离 UIKit 测）。
enum LyricsDoorRules {

    /// 这一拍处在哪一相。**判据的优先级就是语义，别调换顺序**：
    ///
    /// 1. `pageLeaving` ⇒ `.closing`（页面要走时，"什么都不收"压倒其它状态）；
    /// 2. **铺上了** ⇒ `.open`；
    /// 3. 还有意图 ⇒ `.opening`；
    /// 4. 否则 `.closed`。
    static func phase(
        isLive: Bool,
        wantsOpen: Bool,
        pageLeaving: Bool
    ) -> LyricsDoorPhase {
        if pageLeaving { return .closing }
        if isLive { return .open }
        if wantsOpen { return .opening }
        return .closed
    }

    /// 意图**现在还作数吗**（`NowPlayingLyricsPlate.wantsOpenNow` 的纯版本）。
    ///
    /// 三种情况：没意图 ⇒ 否；**已经铺上了** ⇒ 是（这时按住原生封面本来就是对的）；
    /// 还在"点了但没铺上"的那段窗口里 ⇒ 是。
    /// ⚠️ 过了窗口 ⇒ **否**，调用方负责撤意图并把封面写回去（别在这里写状态：
    /// `coverDidLayOut` 也会问它，而那个回调是别人的 `layoutSubviews`）。
    static func intentStillValid(
        wantsOpen: Bool,
        isLive: Bool,
        now: CFAbsoluteTime,
        intentUntil: CFAbsoluteTime
    ) -> Bool {
        guard wantsOpen else { return false }
        if isLive { return true }
        return now < intentUntil
    }

    /// 「点开了但这一拍没铺上」的**重试窗口**还开着吗（2.5s ≈ 5 拍，不新开定时器）。
    static func retryWindowOpen(now: CFAbsoluteTime, retryUntil: CFAbsoluteTime) -> Bool {
        now < retryUntil
    }

    /// 该不该做**页面收尾**（`reconcile` 里"页面真的不在窗口里了"那条守卫）。
    ///
    /// `phase != .closed || isOpen` 是原来 `pageLeaving || isOpen || isLive || wantsOpen` 的**等价**写法：
    /// `.closing` 覆盖 `pageLeaving`，`.open` / `.opening` 覆盖 `isLive || wantsOpen`。
    ///
    /// ⚠️ `isOpen` 必须单独留下：这条守卫要的是"**我们可能改过东西**"，宁可多收一次也不能漏收
    /// （漏收的后果写在 `reconcile` 那段名单里：封面缩着不回、歌手行永远挂着提供商）。
    static func needsPageTeardown(
        phase: LyricsDoorPhase,
        isOpen: Bool,
        hasPendingEdits: Bool
    ) -> Bool {
        (phase != .closed) || isOpen || hasPendingEdits
    }

    /// 该不该**按住 Spotify 那张原生封面**（`coverDidLayOut` 的门禁）。
    ///
    /// ⚠️ `isOpen` 单独留下是刻意的：进页面第一拍它还是 `false`、而转场里原生封面已经在动，
    /// 那时只有**意图**能救它（"进播放器的转场里闪过原生大封面"就是这么来的）。
    /// "页面正在离开"那一支由调用方**先判**，不在这里。
    static func shouldHoldNativeCover(
        isOpen: Bool,
        isLive: Bool,
        intentValid: Bool
    ) -> Bool {
        isOpen || isLive || intentValid
    }
}
