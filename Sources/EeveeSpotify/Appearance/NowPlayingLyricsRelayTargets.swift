// 标题行 / 分享键的触摸替身视图（`NowPlayingLyricsPlate` 用到的几个小 UIView 子类）。
// 从 `NowPlayingLyricsPlate.swift` 原样拆出。
import Foundation
import SwiftUI
import UIKit
import Orion
import ObjectiveC.runtime

/// 被我们**移走**的标题行的触摸替身 —— 让"点歌名 / 歌手跳专辑 / 歌手页"这个原生功能活下来。
///
/// 为什么需要它：我们把标题行用 `transform` 抬到了左上角，但**行还在它原来的 cell 里** —— UIKit 的
/// 命中测试从窗口往下走：点落在 cell 的 frame **之外**时，那一整棵子树根本不会被问 ⇒ 抬上去的那一行
/// **看着在、点不到**（"移动别人的子视图"的固有代价，pw 也踩过）。
///
/// 做法（照 pw `PlayerLyrics.x` 的 `hitTest:`）：在**自己**这一层重写 `hitTest:`，把点**换算**进那一行，
/// 问它要一个命中视图并返回 ——
/// · 本层铺满页面，但 `point(inside:)` 只认**那一行当前的视觉 frame**；
/// · `hitTest` 里先问那一行；命中就把那个视图返回 ⇒ 触摸照常走到 Spotify 的控件（它的祖先手势 /
/// 选中机制也都还能收到这次触摸）。
/// 范围之外一律返回 nil，触摸穿透给下面原有的视图。
final class NowPlayingTitleRelayView: UIView {

    /// 被我们移走的那一行（弱引用：换歌 / 页面走了它自己就没了）。
    weak var row: UIView?

    /// 真的转发了一次触摸 ⇒ 叫一声（只给日志用，见 `noteTitleRelayForward`）。
    var onForward: (() -> Void)?

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return false }
        guard let row, row.window != nil else { return false }
        return row.convert(row.bounds, to: self).contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }
        guard let row, row.window != nil else { return nil }
        guard row.convert(row.bounds, to: self).contains(point) else { return nil }
        // 把点换算进那一行自己的坐标系，问它（以及它的子视图）谁接到这一下。
        let hit = row.hitTest(row.convert(point, from: self), with: event)
        if hit != nil { onForward?() }
        return hit
    }
}

/// 歌词容器。
///
/// **唯一特殊之处**：控件条那一条（底部 ≈40pt）**放行触摸**。
///
/// 为什么需要它：这个容器铺满整个歌词区、`isUserInteractionEnabled = true`（歌词行要靠它收点击去
/// 跳转）、而且被 `bringSubviewToFront` 顶到最上面 ⇒ **它把这一片的触摸全吃掉了**，包括 Spotify
/// 自己的收藏键（＋/绿色 ✓）。只让**那一条**（那一段本来就被上下渐隐遮着，少一点行点击没关系），
/// 歌词正文那一片照旧吃触摸。
final class NowPlayingLyricsContainerView: UIView {

    /// 底部放行多少 pt（0 = 不放行）。
    var passThroughBottom: CGFloat = 0
    /// 额外放行的矩形（**容器坐标**）。
    ///
    /// （点击 收藏 按钮没反应）：歌词容器伸到进度条上沿（587），
    /// 而收藏键在 549…597 —— 上半截被容器吃了。由调用方把收藏键的框换算到这里。
    var passThroughRects: [CGRect] = []

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        if passThroughRects.contains(where: { $0.contains(point) }) { return false }
        guard passThroughBottom > 0 else { return true }
        return point.y < bounds.height - passThroughBottom
    }
}

/// 歌词键的手势目标（`UIControl` 的 target 必须是 ObjC 对象）。
final class NowPlayingLyricsToggleTarget: NSObject {

    static let shared = NowPlayingLyricsToggleTarget()

    @objc func tapped() {
        onMainThreadSync { NowPlayingLyricsPlate.toggle() }
    }
}

/// 分享键**替身热区**的点击目标（同上，target 必须是 ObjC 对象）。
final class NowPlayingShareRelayTarget: NSObject {

    static let shared = NowPlayingShareRelayTarget()

    @objc func tapped() {
        onMainThreadSync { NowPlayingLyricsPlate.relayShareTap() }
    }
}

/// 歌词区底沿那条**署名**的点击目标（同上，target 必须是 ObjC 对象）。
///
/// 不带参数：多带一个 `sender` 就要写成 `#selector(...tapped(_:))`，两处签名必须一起改，
/// 而这种"改了选择器忘了改注册"的错只会在运行时炸。署名那条链接取全局状态即可
/// （`currentLyricsProviderURL` / `currentLyricsContributors`），不需要从手势里拿。
final class NowPlayingLyricsCreditTarget: NSObject {

    static let shared = NowPlayingLyricsCreditTarget()

    @objc func tapped() {
        onMainThreadSync { NowPlayingLyricsPlate.openCreditLink(nil) }
    }
}
