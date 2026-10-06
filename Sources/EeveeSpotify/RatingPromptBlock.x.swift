import Foundation
import Orion
import StoreKit

/// 「阻止评分提示」：拦住 App Store 的系统评分弹窗。
///
/// 为什么要在系统类上下手：Spotify 听够次数之后会调 `SKStoreReviewController` 弹系统的
/// 评分对话框。它**不是** Spotify 自己的 UI ⇒ 我们那套弹窗 hook（`UpsellPopupBlocker`
/// 拦 `SPTEncorePopUp*`）碰不到它，只能在系统这两个入口上拦。
///
/// **两个入口都要拦**：`requestReview()`（老入口，Spotify 仍在用）与
/// `requestReviewInScene(_:)`（场景化入口）。只拦一个的话另一个照样弹。
///
/// 与「隐私与上报」的分工：那边拦的是**出网的上报请求**（`TelemetryEndpointRules`），
/// 这里拦的是**系统弹窗**；两者互不替代 —— 评分弹窗不经过我们规则表里的那些端点。
///
/// ⚠️ 开关**只在启动时读一次**：`RatingPromptBlockGroup` 是启动时按开关决定装不装的
/// （`activateRatingPromptBlock`），所以改完要重启 —— 设置页那一行下面配了「立即重启」。
///
/// 上游对应实现：`EeveeSpotifyReincarnated/Sources/EeveeSpotify/Misc/RatingPromptBlock.x.swift`
/// （40 行）。我们是移植 + 换成本仓库的日志出口（`writeDebugLog`，自带脱敏）。
struct RatingPromptBlockGroup: HookGroup {}

class StoreReviewHook: ClassHook<SKStoreReviewController> {
    typealias Group = RatingPromptBlockGroup

    // 这里**故意不调** `orig.*`：要的就是"整段吞掉原实现" —— 转发回原实现等于照样弹窗。
    // （`orion_hook_guard.py` 的规则 2 只对"提到过 `orig.<同名>`"的方法做校验，不会误报。）
    class func requestReview() {
        RatingPromptBlock.blocked("requestReview")
    }

    class func requestReviewInScene(_ scene: UIWindowScene) {
        RatingPromptBlock.blocked("requestReviewInScene")
    }
}

enum RatingPromptBlock {
    /// 启动时的快照值 —— hook 组装不装只看它。
    static let launchEnabled = UserDefaults.blockRatingPrompts

    private static var count = 0

    static func blocked(_ method: String) {
        count += 1
        writeDebugLog("[RatingPrompt] blocked \(method) (\(count) total)")
    }
}

func activateRatingPromptBlock() {
    guard RatingPromptBlock.launchEnabled else { return }

    let start = CFAbsoluteTimeGetCurrent()
    RatingPromptBlockGroup().activate()

    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
    writeDebugLog("[RatingPrompt] on (\(String(format: "%.2f", elapsed)) ms)")
}
