import Foundation
import UIKit
import MediaPlayer
import ObjectiveC.runtime

/// 听歌页**我们自己的覆盖层** —— AM 页面（kumone 那种一屏播放器）的**地基**。
///
/// ## 它是什么、**不是什么**（这一段是纪律，别再踩 2026-10-02 的坑）
///
/// * **是**：一层**整页透明**的 `UIView`，挂在页面根视图的**最上面**。我们自己的控件
///   （音量条，以后还有头部一行 / 三个圆按钮）全放在它上面，用它当一个**统一的坐标系**。
/// * **不是**"自绘壳"：2026-10-02 那版是**加模糊 / 铺实心盖住原生内容**（照片 19/20 的糊底、
///   一整页空白），被整块删掉（`Tweak.x.swift:384-387`）。这一层**什么都不画** ——
///   透明、无背景、无内容，只提供坐标系。
/// * 容器自己 `isUserInteractionEnabled = false`：**不吃触摸**，Spotify 原生手势
///   （下拉关闭 / 滚动 / 左右切歌）全部照常；只有放在它上面的**具体控件**才开交互。
/// * **不碰 Spotify 任何属性**（唯一会动的是"往它上面加我们自己的子视图"）⇒
///   关掉 = 把这一层拿掉，**天然完全还原**。
///
/// ## 怎么定位（依据：日志 38 的真机树，不是猜的）
///
/// 播放器底部那一坨五行（进度 / 标题 / 控件 / 图标）在
/// `13.UIStackView@4,560,406,273,id=npv.bottomStackView` 里 —— 它**有 accessibilityIdentifier**，
/// 所以我们靠 id 认它，不靠类名、不靠猜层级。控件的落点就从它的 frame 推：
/// 音量条放在它**下面**，左右各内缩 4pt；找不到锚就退回页面安全区底 ——
/// **宁可位置保守，也不要压到原生控件上**。
///
/// ## 开关
///
/// 扩展功能 → 听歌页 →「底部音量条」，**默认关**（先看效果，再决定默认值）。
/// 日志 tag：`[NPVPage]`。
enum NowPlayingPageOverlay {

    static let logTag = "NPVPage"

    /// 播放器底部那一坨在真机树里的 id（日志 38 的 `[Tree] #7`）。
    private static let bottomAnchorIdentifier = "npv.bottomStackView"
    /// 锚点走查上限（本仓库纪律）。
    private static let maxNodes = 2000
    /// 音量条自己的尺寸（左右内缩各 4pt，与 `npv.bottomStackView` 的 4,0,406 对齐）。
    private static let volumeHeight: CGFloat = 32
    private static let sideInset: CGFloat = 8
    private static let gapBelowAnchor: CGFloat = 4

    private static var overlayKey: UInt8 = 0

    private static weak var lastPage: UIView?
    private static weak var lastOverlay: UIView?

    private static var didLogInstall = false

    static var isEnabled: Bool { UserDefaults.nowPlayingVolume }

    // MARK: - 对外入口

    /// 进听歌页时叫一次（蹭既有的 `NPVScrollViewControllerHook` 两个 appear 点）。
    static func apply(in pageView: UIView) {
        lastPage = pageView

        guard isEnabled else {
            remove(reason: "switch off")
            return
        }
        guard pageView.bounds.width > 1, pageView.bounds.height > 1 else { return }

        let overlay = attach(to: pageView)
        layout(overlay: overlay, in: pageView)
    }

    /// 蹭 `DeclutterChrome` 既有的复查节拍（**不新开定时器**）。
    ///
    /// 为什么需要：Spotify 的布局回合会重排 subviews（把我们的层挤回下面），
    /// 换歌 / 转场之后锚点的 frame 也会变。成本：没在听歌页时三次 weak 读；
    /// 在听歌页时几次 frame 比较（没变就一个字节都不写）。
    @discardableResult
    static func reconcile() -> Bool {
        guard isEnabled else { return false }
        guard let page = lastPage, page.window != nil else { return false }

        guard let overlay = lastOverlay, overlay.superview === page else {
            let overlay = attach(to: page)
            layout(overlay: overlay, in: page)
            return true
        }
        return layout(overlay: overlay, in: page)
    }

    /// 设置页切开关时叫一次：页面还挂着就**当场**落地，否则等下次进听歌页。
    static func reapply() {
        guard let page = lastPage, page.window != nil else { return }
        apply(in: page)
    }

    /// 关掉开关时把整层拿走（我们只加过自己的视图 ⇒ 不需要还原任何东西）。
    static func remove(reason: String) {
        guard let overlay = lastOverlay else { return }
        overlay.removeFromSuperview()
        lastOverlay = nil
        didLogInstall = false
        writeDebugLog("[\(logTag)] 覆盖层已拿走（reason=\(reason)）")
    }

    // MARK: - 建层

    /// 幂等：已经有就复用；被挤下去就重新置顶。
    private static func attach(to page: UIView) -> UIView {
        let overlay: UIView
        if let existing = objc_getAssociatedObject(page, &overlayKey) as? UIView {
            overlay = existing
        } else {
            overlay = UIView(frame: page.bounds)
            overlay.backgroundColor = .clear
            // ★ 容器不吃触摸：原生的下拉关闭 / 滚动 / 左右切歌全部照常。
            overlay.isUserInteractionEnabled = false
            overlay.clipsToBounds = false
            overlay.accessibilityIdentifier = "eevee-npv-overlay"
            overlay.isAccessibilityElement = false
            objc_setAssociatedObject(page, &overlayKey, overlay, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        if overlay.superview !== page || page.subviews.last !== overlay {
            // 放最上面：Spotify 重排 subviews 会把我们挤下去（同 `AmazonMusicLyricsOverlay`
            // 那条真机教训），所以每次进来都确保一次。
            page.addSubview(overlay)
        }
        lastOverlay = overlay
        return overlay
    }

    // MARK: - 布局

    /// 把覆盖层铺满、把音量条摆到锚点下面。**返回这一拍有没有真的改东西**。
    @discardableResult
    private static func layout(overlay: UIView, in page: UIView) -> Bool {
        var changed = false

        let wanted = CGRect(origin: .zero, size: page.bounds.size)
        if overlay.frame != wanted {
            overlay.frame = wanted
            changed = true
        }

        let slider = ensureVolumeSlider(in: overlay)
        let target = volumeFrame(in: page, overlay: overlay)
        if slider.frame != target {
            slider.frame = target
            changed = true
        }

        if !didLogInstall {
            didLogInstall = true
            let anchor = findBottomAnchor(in: page)
            let anchorText = anchor.map { frameText($0.convert($0.bounds, to: page)) } ?? "没找到（退回安全区底）"
            writeDebugLog(
                "[\(logTag)] 覆盖层已装 \(frameText(overlay.frame))"
                    + "；底部锚 \(bottomAnchorIdentifier) = \(anchorText)"
                    + "；音量条 \(frameText(target))"
            )
        }
        return changed
    }

    /// 音量条放哪：**锚点下面**；锚点不在（或空间不够）就贴安全区底。
    private static func volumeFrame(in page: UIView, overlay: UIView) -> CGRect {
        let width = max(120, page.bounds.width - sideInset * 2)
        let x = (page.bounds.width - width) / 2

        // 安全区底：页面自己的 `safeAreaInsets` 就是最可靠的"别压到 home indicator"来源。
        let bottomLimit = page.bounds.height - page.safeAreaInsets.bottom - 4

        var y: CGFloat
        if let anchor = locateBottomAnchor(in: page) {
            let frame = anchor.convert(anchor.bounds, to: overlay)
            y = frame.maxY + gapBelowAnchor
        } else {
            y = bottomLimit - volumeHeight
        }

        // 越界就往回收，绝不叠到原生控件上。
        if y + volumeHeight > bottomLimit {
            y = max(0, bottomLimit - volumeHeight)
        }
        return CGRect(x: x, y: y, width: width, height: volumeHeight)
    }

    /// 幂等：音量条只建一次（`MPVolumeView` 走的是系统音量，Apple 自己的控件）。
    private static func ensureVolumeSlider(in overlay: UIView) -> MPVolumeView {
        if let existing = overlay.subviews.compactMap({ $0 as? MPVolumeView }).first {
            return existing
        }

        let slider = MPVolumeView(frame: .zero)
        slider.showsRouteButton = false          // 不要那枚 AirPlay 路由按钮（kumone 也没有）
        // ⚠️ 只有这一个子视图开交互；容器本身仍然不吃触摸。
        slider.isUserInteractionEnabled = true
        overlay.addSubview(slider)
        return slider
    }

    /// `npv.bottomStackView` 在哪：**页面 → 播放器列表 → 窗口**，三跳。
    ///
    /// 为什么要补中间那一跳（2026-10-04，日志 40/41/42/43 四次同样的现场）：
    /// 它**不在页面根视图的子树里**（日志 42 的定向树显示它在
    /// `scrolling_npv_collection_view_accessibility_identifier` 的子树里，`4,593,406,240`），
    /// 而"窗口"那一跳也没命中 ⇒ 每次进页面都退回安全区底。
    /// 列表这一跳用的是 `NowPlayingOneScreen` 认出来的那一张（判据只留一处）。
    private static func locateBottomAnchor(in page: UIView) -> UIView? {
        if let anchor = findBottomAnchor(in: page) { return anchor }
        if let list = NowPlayingOneScreen.pinnedList,
           let anchor = findBottomAnchor(in: list) {
            return anchor
        }
        guard let window = page.window else { return nil }
        return findBottomAnchor(in: window)
    }

    /// 按 `accessibilityIdentifier` 找播放器底部那一坨（有界广度优先）。
    private static func findBottomAnchor(in root: UIView) -> UIView? {
        var visited = 0
        var queue: [UIView] = [root]

        while !queue.isEmpty, visited < maxNodes {
            let view = queue.removeFirst()
            visited += 1

            if view.accessibilityIdentifier == bottomAnchorIdentifier { return view }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    // MARK: - 日志

    private static func frameText(_ frame: CGRect) -> String {
        "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
    }
}
