import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 主页（Home / Listen Now）头部 —— 照 pw 的 `Redesigned/Home/HomeHeader.x`，
/// 观感标准仍然是 **Apple Music 的 Listen Now**（用户 2026-10-12：「以网上的 AM 为准…还是要求优雅」）。
///
/// ── AM 的 Listen Now 长什么样（网上查的，不是记忆）──────────────────────────
/// · **大标题 32pt/800、贴左沿**（AM 是 "Listen Now"；我们读**标签栏那一颗**的文字 ⇒「主页」，跟随语言）；
/// · 标题行**右端一颗**（AM 是账户头像，我们这里就是打开侧边栏的头像）；
/// · 顶部**没有那层压暗的灰纱**；
/// · **没有 Spotify 那排「全部 / 音乐 / 播客」筛选 pills** —— AM 的 Listen Now 是
///   "Stations for You 横排 → Recently Played 网格 → 推荐卡"，没有内容筛选胶囊。
///   ⚠️ 所以这一页**与音乐库刻意相反**：音乐库的 chips **保留**（那是排序用的，pw 删过又装回来 —— issue #20），
///   这里的 pills 是**内容筛选**、AM 没有 ⇒ **收掉**（要装回来只需把 `HomeHeaderMetrics.vanishPills` 改 false）。
///
/// ── 真机结构（日志 64 的 `[Tree] #1`，我们自己的机器，不是 pw 的树）──────────
/// ```
/// 16.GradientView@0,0,414,98,id=LiquidGlass.GradientView          ← 灰纱（收掉）
/// 16.HomeHeaderView@0,0,414,50                                    ← 头部（hook 目标在页面 VC 上，见下）
/// └ 17.UIStackView@0,8,414,34                                     ← 那一行
///   ├ 18.AdaptiveFaceContainer@16,0,32,34
///   │ └ 19.EncoreButton@0,0,32,34,id=Components.UI.SideDrawerButton    ← 头像
///   └ 18.LeadingFadeMaskView@48,1,366,32
///     └ 19.PillScrollView@0,0,366,32 → 22.PillView id=home-feed-{default,music,podcasts}-chip
/// ```
///
/// ── 四条"照 pw"的实现纪律（每条都有理由，别再自己发明）──────────────────────
///   1. **头像靠右用"把那一行翻成 RTL"**（`semanticContentAttribute = .forceRightToLeft`），
///      不是自己算 transform：RTL 下 stack 会把**第一个 arranged subview 摆到右沿**，于是每拍自动对，
///      而且"正在收听的朋友"临时插进来改变宽度时也不用管（pw 的原话就是这个）；
///   2. **pills 是 arranged subview ⇒ 只能 `alpha = 0`，不能 `isHidden`、更不能摘掉**
///      （摘掉会让那个 stack 卡在 `updateConstraints` —— pw 的 `SGRRestyle.h` 立的规矩，我们音乐库也吃过）；
///   3. **标题自己画**（一个 `UILabel`，加在 header 上、不属于任何 stack）：文字从**标签栏那一颗**读
///      （`TabBar.Item.Home` 里第一个 `UILabel`）⇒ 跟随 App 语言；**绝不去改 Spotify 自己那个 label** ——
///      那一行会**随滚动往上滑并淡出**；
///   4. **所有事情都做在页面的 `viewDidLayoutSubviews` 里**（pw 同款）：主页的头部**随滚动动**
///      ⇒ 音乐库那套"头部静止 + 0.5s 复查"在这里**不成立**；页面的布局回合在滑动每一步都会来。
///
/// ⚠️ 与「隐藏主页头部」那颗开关（`DeclutterChrome.hideHomeHeader`）的关系：那颗开着时整个 header 被隐掉
///    ⇒ 我们**让位**（标题挂在一个看不见的容器上没意义），并在日志里说一次。
struct HomeHeaderAppearanceGroup: HookGroup {}

enum HomeHeaderMetrics {
    /// 左沿（pw 的 `SGRSideMargin`，与音乐库同一个数）。
    static let sideMargin: CGFloat = 16
    /// 标题右端与头像之间留多少（pw 的 `SGRGrid`）。
    static let gap: CGFloat = 8
    /// AM 的大标题档（规格页：`--large-title` = **32pt / 800**）。
    static let titleSize: CGFloat = 32
    /// 收不收那排「全部 / 音乐 / 播客」（AM 没有；见文件头，改 false 就装回来）。
    static let vanishPills = true
}

enum HomeHeaderAppearance {

    static var isEnabled: Bool { UserDefaults.homeLargeTitle }

    /// 我们画的那颗标题（挂在 header 上）。
    private static var titleKey: UInt8 = 0
    /// 被收掉的那些视图（pills 那一块）**各自的原 alpha** —— 记在视图自己身上，弱表管还原。
    private static let vanishedViews = NSHashTable<UIView>.weakObjects()
    private static var vanishedAlphaKey: UInt8 = 0
    /// 灰纱（`LiquidGlass.GradientView`）：同上一套。
    private static var scrimAlphaKey: UInt8 = 0
    private static var didLog = false
    private static var didLogStandDown = false
    private static var didLogMissing = false
    /// 首页标签的名字（从标签栏那一颗读一次，跟随 App 语言）。
    private static var tabName: String?

    // MARK: - 施加

    /// 由页面 VC 的 `viewDidLayoutSubviews` 调用（**滑动每一步都会来**）。幂等。
    @MainActor
    static func apply(to page: UIView) {
        guard isEnabled else {
            restore(in: page)
            return
        }
        // 「隐藏主页头部」开着 ⇒ 让位（那颗开关会把整个 header 藏掉）。
        guard !UserDefaults.hideHomeHeader else {
            if !didLogStandDown {
                didLogStandDown = true
                writeDebugLog(
                    "[Home] standing down — the hide-home-header switch owns this header, so the Apple Music title would sit on a hidden view"
                )
            }
            return
        }
        guard let header = findView(in: page, where: { className($0).contains("HomeHeaderView") }) else {
            if !didLogMissing {
                didLogMissing = true
                writeDebugLog("[Home] ⚠️ no HomeHeaderView on the page — the header is left as Spotify's")
            }
            return
        }
        layout(header: header)
    }

    @MainActor
    private static func layout(header: UIView) {
        // 灰纱：真机里它与 header **同父**（都在那个 LayoutOnlyView 下）⇒ 回头看兄弟。
        clearScrim(around: header)

        guard let stack = findView(in: header, where: { $0 is UIStackView }) else { return }

        // ① 那一行翻成 RTL ⇒ 头像自动落到右沿（每拍都成立，宽度变了也不用管）。
        if stack.semanticContentAttribute != .forceRightToLeft {
            stack.semanticContentAttribute = .forceRightToLeft
            stack.setNeedsLayout()
        }
        stack.layoutIfNeeded()

        // ② 除头像外，arranged subview 一律收掉（**只有 alpha**，不摘、不 hidden —— 见文件头 ②）。
        var face: UIView?
        for part in stack.arrangedSubviews {
            if className(part).contains("AdaptiveFaceContainer") {
                face = part
                continue
            }
            if HomeHeaderMetrics.vanishPills { vanish(part) }
        }

        // ③ 自己画的大标题（AM：32pt bold、贴左、与那一行垂直居中、右端到头像左边 8pt）。
        let title = titleLabel(in: header)
        let text = homeTabTitle(in: header)
        if title.text != text {
            title.text = text
            title.accessibilityLabel = text
        }
        let font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(
            for: UIFont.systemFont(ofSize: HomeHeaderMetrics.titleSize, weight: .bold)
        )
        if title.font != font { title.font = font }

        let row = stack.convert(stack.bounds, to: header)
        let trailing = face.map { stack.convert($0.frame, to: header).minX - HomeHeaderMetrics.gap }
            ?? (header.bounds.width - HomeHeaderMetrics.sideMargin)
        let height = ceil(font.lineHeight)
        let frame = CGRect(
            x: HomeHeaderMetrics.sideMargin,
            y: round(row.midY - height / 2),
            width: max(0, trailing - HomeHeaderMetrics.sideMargin),
            height: height
        )
        if !title.frame.equalTo(frame) { title.frame = frame }

        if !didLog, header.window != nil, header.bounds.width > 1 {
            didLog = true
            writeDebugLog(
                "[Home] header the way Apple Music has it — title \"\(text)\" \(Int(font.pointSize))pt at the leading edge"
                    + ", avatar \(face.map { frameText($0.convert($0.bounds, to: header)) } ?? "not found") at the trailing edge"
                    + ", pills \(HomeHeaderMetrics.vanishPills ? "vanished (alpha only, they stay in the stack)" : "left alone")"
                    + ", scrim off"
            )
        }
    }

    /// 我们那颗标题：不是任何 stack 的 arranged subview（`header.addSubview` 直接加）。
    @MainActor
    private static func titleLabel(in header: UIView) -> UILabel {
        if let existing = objc_getAssociatedObject(header, &titleKey) as? UILabel { return existing }
        let title = UILabel()
        title.textColor = .label
        title.accessibilityTraits = .header
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.6
        title.userInteractionEnabled = false
        header.addSubview(title)
        objc_setAssociatedObject(header, &titleKey, title, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return title
    }

    /// 首页标签的名字：**从标签栏那一颗读**（`TabBar.Item.Home` 里第一个有字的 `UILabel`）
    /// ⇒ 跟随 App 语言（我们机器上是「主页」）。读不到就退回本地化文案，并只报一次。
    @MainActor
    private static func homeTabTitle(in header: UIView) -> String {
        if let tabName { return tabName }
        if let window = header.window,
           let item = findView(in: window, where: { $0.accessibilityIdentifier == "TabBar.Item.Home" }),
           let label = findView(in: item, where: { ($0 as? UILabel)?.text?.isEmpty == false }),
           let text = (label as? UILabel)?.text {
            tabName = text
            return text
        }
        return "home_header_title".localized
    }

    // MARK: - 收 / 还原

    @MainActor
    private static func vanish(_ view: UIView) {
        if objc_getAssociatedObject(view, &vanishedAlphaKey) == nil {
            objc_setAssociatedObject(
                view,
                &vanishedAlphaKey,
                NSNumber(value: Double(view.alpha)),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            vanishedViews.add(view)
        }
        if view.alpha != 0 { view.alpha = 0 }
        if view.isUserInteractionEnabled { view.isUserInteractionEnabled = false }
        view.accessibilityElementsHidden = true
    }

    /// 顶部那层灰纱：pw 从页面直接子视图里找 `GradientView`；我们**从 header 的父视图的兄弟里找**
    /// （真机两者同父，见文件头的树）—— 比扫整页稳，扫整页会碰到别的页面的 GradientView。
    @MainActor
    private static func clearScrim(around header: UIView) {
        guard let parent = header.superview else { return }
        guard let scrim = findView(in: parent, where: { className($0).contains("GradientView") && $0 !== header }) else { return }
        if objc_getAssociatedObject(scrim, &scrimAlphaKey) == nil {
            objc_setAssociatedObject(
                scrim,
                &scrimAlphaKey,
                NSNumber(value: Double(scrim.alpha)),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            vanishedViews.add(scrim)
        }
        if scrim.alpha != 0 { scrim.alpha = 0 }
    }

    /// 开关关掉 / 页面走了。**精确还原四件事**：标题、RTL、被收掉的 alpha、灰纱 alpha。
    @MainActor
    static func restore(in page: UIView) {
        if let header = findView(in: page, where: { className($0).contains("HomeHeaderView") }),
           let title = objc_getAssociatedObject(header, &titleKey) as? UILabel {
            title.removeFromSuperview()
            objc_setAssociatedObject(header, &titleKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        if let stack = findView(in: page, where: { $0 is UIStackView && $0.semanticContentAttribute == .forceRightToLeft }),
           stack.semanticContentAttribute != .unspecified {
            stack.semanticContentAttribute = .unspecified
            stack.setNeedsLayout()
        }
        for view in vanishedViews.allObjects {
            if let alpha = objc_getAssociatedObject(view, &vanishedAlphaKey) as? NSNumber {
                view.alpha = CGFloat(alpha.doubleValue)
                objc_setAssociatedObject(view, &vanishedAlphaKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            if let alpha = objc_getAssociatedObject(view, &scrimAlphaKey) as? NSNumber {
                view.alpha = CGFloat(alpha.doubleValue)
                objc_setAssociatedObject(view, &scrimAlphaKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            view.isUserInteractionEnabled = true
            view.accessibilityElementsHidden = false
        }
        vanishedViews.removeAllObjects()
        didLog = false
        didLogMissing = false
    }

    // MARK: - 小工具

    private static func findView(in view: UIView, where matches: (UIView) -> Bool) -> UIView? {
        if matches(view) { return view }
        for sub in view.subviews {
            if let found = findView(in: sub, where: matches) { return found }
        }
        return nil
    }

    private static func className(_ view: UIView) -> String {
        NSStringFromClass(type(of: view))
    }

    private static func frameText(_ frame: CGRect) -> String {
        "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
    }
}

// MARK: - Hook

/// 主页：`Home_FunkisPageImpl.FunkisViewController`（pw 挂的也是它）。
///
/// ⚠️ **为什么挂页面而不是挂 header**：首页滚动时 Spotify 会把那一行**往上滑并淡出**
/// （pw 的注释 + 我们的真机树都证实）⇒ 只在 header 自己的布局回合里算，会在滑动过程中"卡住不动"。
/// 页面的 `viewDidLayoutSubviews` 在**滑动每一步**都会来，天然就是"每拍重算"。
class HomeHeaderAppearanceHook: ClassHook<UIViewController> {
    typealias Group = HomeHeaderAppearanceGroup
    static let targetName = "Home_FunkisPageImpl.FunkisViewController"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        // ⚠️ hook 方法体里**不许直接碰 @MainActor 的东西**（`viewIfLoaded` 就是）——
        //   仓库成文规矩，见 `LyricsChromeVisibility.swift:3-17`。所以只把 VC 这个**引用**带进去，
        //   `viewIfLoaded` 在 `onMainThreadSync` 的闭包里读（那个闭包本身就是 `@MainActor`）。
        let controller = target
        onMainThreadSync {
            guard let view = controller.viewIfLoaded else { return }
            HomeHeaderAppearance.apply(to: view)
        }
    }
}

func activateHomeHeaderAppearance() {
    guard NSClassFromString(HomeHeaderAppearanceHook.targetName) != nil else {
        writeDebugLog("[Home] missing \(HomeHeaderAppearanceHook.targetName) — hook inactive")
        return
    }
    HomeHeaderAppearanceGroup().activate()
    writeDebugLog(
        "[Home] home header restyle installed (switch=\(UserDefaults.homeLargeTitle ? "ON" : "OFF"))"
            + " — a large title at the leading edge, the avatar at the trailing edge, the pills and the scrim gone"
    )
}
