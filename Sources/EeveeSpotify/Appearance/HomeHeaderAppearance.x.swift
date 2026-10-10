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
/// ⚠️ 与「隐藏主页头部」那颗开关（`DeclutterChrome.hideHomeHeader`）的关系 ——
///    ★ 2026-10-14（用户批准"隐藏态不留灰纱"之后定的）：**「隐藏」是一个独立状态**，
///    不再挂在 `homeLargeTitle` 后面；让位**只让"画"那一半，灰纱照收**。
///    · **让位**：不建标题、不动那一行与 pills、不碰 RTL —— header 被 `DeclutterChrome` 设成
///      `isHidden = true`（`DeclutterChrome.x.swift:382-388`，视图**还在树里**）⇒ 往一个看不见的
///      容器上画标题没有意义，还会跟 Spotify 自己的隐藏逻辑打架；
///    · **灰纱照收**（`clearScrim`）：灰纱与 header **同父、是兄弟**（上面的真机树 + `clearScrim`
///      的注释），`DeclutterChrome` 藏的是 header **自己** ⇒ 谁都不会顺手带走灰纱。
///      让位若排在 `clearScrim` **之前**，用户看到的就是"顶部条没了、灰纱还在"—— 那正是这次修的。
///    · **可逆**：`clearScrim` 把原 alpha 记进 `vanishedViews`，切回「原样」时 `restore(in:)`
///      会原样写回 ⇒ 灰纱不会被"粘死"。
///    ⚠️ 为什么隐藏分支要排在 `isEnabled`（= `homeLargeTitle`）**之前**：设置页的三态是
///      「原样 = 两颗都 false / AM 式 = `homeLargeTitle == true` / **隐藏 = `hideHomeHeader == true`，
///      `homeLargeTitle` 的值被忽略**」（`Settings/Sections/HomeLibrary/Views/HomeAndLibrarySettingsView.swift`
///      文件头 + `HomeHeaderStyle`）。而那个选择器可以从「原样」（它会写 `homeLargeTitle = false`）
///      **直接切到「隐藏」** ⇒ `false + true` 不是历史值、是今天就到的组合；
///      隐藏行为若还看 `homeLargeTitle`，"顶部条没了、灰纱还在"就会在这个组合里复发。
///    ⚠️ 隐藏态**不调 `restore(in:)`**：`restore` 会把灰纱 alpha 还回去（= 灰纱又出现，正好是
///      要修的那一件）；标题/RTL/pills 那三件在 hidden 的 header 里反正看不见，留着还能让
///      「隐藏 → AM 式」不用重建。切到「原样」时才走 `restore`（那条路一个字没动）。
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
        // ★ 2026-10-14：隐藏态**单独一条**、排在 `isEnabled` 前面（理由见文件头那段 ⚠️）：
        //   「隐藏」= `hideHomeHeader == true`，`homeLargeTitle` 的值**被忽略**。
        //   ⚠️ 这里读的是同一个键、而且是一个纯读（`UserDefaults+Extension.swift:532-539`）⇒
        //   它为 false 时，下面每一步与改动前是**同一条语句、同一个顺序**（等价性逐条见交接报告）。
        if UserDefaults.hideHomeHeader {
            standDown(in: page)
            return
        }
        guard isEnabled else {
            restore(in: page)
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

    /// 「隐藏主页头部」开着 ⇒ 让位：**只让"画"这一半，灰纱照收**（理由见文件头那段 ⚠️）。
    ///
    /// 找 header 用的是与 `layout(header:)` **同一条判据**；**不**扫整页找 `GradientView`
    /// （`clearScrim` 上面那段写了理由：扫整页会碰到别的页面的灰纱）。`DeclutterChrome` 是
    /// `view.isHidden = true`、视图**还在树里**（`DeclutterChrome.x.swift:382-388`）⇒ 照样找得到。
    /// ⚠️ 拿不到 header（页面还没建好）时什么都不做：那一拍的灰纱不收，下一个布局回合还会再来
    ///    （页面的 `viewDidLayoutSubviews` + header 自己那一拍）—— 与改动前一致（改动前连找都不找）。
    /// ⚠️ 也**不**在这里删我们画过的标题 / 翻回 RTL：它们都在那个 hidden 的 header 里，看不见；
    ///    留着反而让「隐藏 → AM 式」这一跳不用重建（切「原样」时由 `restore(in:)` 收尾）。
    @MainActor
    private static func standDown(in page: UIView) {
        if !didLogStandDown {
            didLogStandDown = true
            writeDebugLog(
                "[Home] standing down — the hide-home-header switch owns this header,"
                    + " so the Apple Music title would sit on a hidden view; scrim still collected"
                    + " (it is the header's sibling, not its child)"
            )
        }
        guard let header = findView(in: page, where: { className($0).contains("HomeHeaderView") }) else { return }
        clearScrim(around: header)
    }

    @MainActor
    private static func layout(header: UIView) {
        // 灰纱：真机里它与 header **同父**（都在那个 LayoutOnlyView 下）⇒ 回头看兄弟。
        clearScrim(around: header)

        // ⚠️ 必须**强转成 `UIStackView`**：`findView` 的返回类型是 `UIView`，而 `arrangedSubviews`
        //   只有 stack 才有（2026-10-12 编译错第 1 条就是漏了这个 `as?`）。
        guard let stack = findView(in: header, where: { $0 is UIStackView }) as? UIStackView else { return }

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

        // 水平：左沿固定，右端到"头像左边 8pt"为止（拿不到头像就顶到右沿留一个边距）。
        let trailing = face.map { $0.convert($0.bounds, to: header).minX - HomeHeaderMetrics.gap }
            ?? (header.bounds.width - HomeHeaderMetrics.sideMargin)

        // 垂直：**以头像那一颗为心**（用户 2026-10-12：「主页上的 主页两个字会偏上」）——
        // 头像是他看得见的那一行，标题就该跟它一条中线；拿不到头像才退回那一行的中心。
        let rowMidY = face.map { $0.convert($0.bounds, to: header).midY }
            ?? stack.convert(stack.bounds, to: header).midY
        let height = ceil(font.lineHeight)
        let frame = CGRect(
            x: HomeHeaderMetrics.sideMargin,
            y: round(rowMidY - height / 2),
            width: max(0, trailing - HomeHeaderMetrics.sideMargin),
            height: height
        )
        if !title.frame.equalTo(frame) { title.frame = frame }

        // ⚠️ 这一行**不许嵌转义双引号**、也**不要** `header.window != nil` 这个条件：
        //   上一版就是这么写的，结果整行没进日志（日志 65 里一条 `[Home] header …` 都没有，
        //   而 `LeadingFadeMaskView … alpha=0.00` 证明代码其实跑了）⇒ 我们白猜了一轮。
        if !didLog, header.bounds.width > 1 {
            didLog = true
            writeDebugLog(
                "[Home] header restyled — title \(text) at \(Int(font.pointSize))pt, frame \(frameText(frame))"
                    + "; row \(frameText(stack.convert(stack.bounds, to: header)))"
                    + "; avatar \(face.map { frameText($0.convert($0.bounds, to: header)) } ?? "not found")"
                    + "; header \(frameText(header.bounds))"
                    + "; pills \(HomeHeaderMetrics.vanishPills ? "faded with alpha" : "left alone")"
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
        // ⚠️ Swift 里是 **`isUserInteractionEnabled`**（`userInteractionEnabled` 是 ObjC 那个名字；
        //   写成旧的会被编译器直接拦下 —— 2026-10-12 编译错第 2 条）。
        title.isUserInteractionEnabled = false
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

/// ★ 2026-10-12 补（用户第二轮反馈："主页那两个字**还是**偏上"）：
/// **页面那一拍不够** —— 真机日志 67 里我们那一行是**对齐的**
/// （`title frame 16,6,342,39` ⇒ 中心 25.5；`avatar 366,8,32,34` ⇒ 中心 25），
/// 说明用户看到的错位发生在**某次只有那一行自己在动**的时候（滚动时 Spotify 会让这一行单独滑动/淡出，
/// 那种回合**不一定**经过页面的 `viewDidLayoutSubviews`）。
/// 这正是 pw 的教训，他的原话：**"那一行也要盯着，它自己的每一拍都把控件重新摆一遍"**
/// （`LibraryHeader.x` 文件头最后一段）⇒ 所以这里**再挂一个头部自己的布局回合**，
/// 两条路都算一次（幂等，重复算没有代价）。
class HomeHeaderLayoutHook: ClassHook<UIView> {
    typealias Group = HomeHeaderAppearanceGroup
    // 与 `DeclutterChrome` 的「隐藏主页头部」同一个类名（那是另一颗开关，互不干扰）。
    static let targetName = "_TtC19Home_FunkisPageImplP33_297EC57FD07AE9FCEAA7B66079FC278C14HomeHeaderView"

    func layoutSubviews() {
        orig.layoutSubviews()
        let header = target
        onMainThreadSync {
            // 传 header 自己也行：`apply` 找的就是"类名含 HomeHeaderView"的那个视图，
            // 而且 `matches(view)` 先判自己 ⇒ 一下命中。
            HomeHeaderAppearance.apply(to: header)
        }
    }
}

func activateHomeHeaderAppearance() {
    // 两个挂点：页面（滑动每一步）+ 头部自己（那一行自己的每一拍）——缺一个就可能"某一刻错位"。
    let targets = [HomeHeaderAppearanceHook.targetName, HomeHeaderLayoutHook.targetName]
    let missing = targets.filter { NSClassFromString($0) == nil }
    if missing.count == targets.count {
        writeDebugLog("[Home] missing \(missing.joined(separator: ", ")) — hook inactive")
        return
    }
    HomeHeaderAppearanceGroup().activate()
    writeDebugLog(
        "[Home] home header restyle installed (switch=\(UserDefaults.homeLargeTitle ? "ON" : "OFF"))"
            + " — a large title at the leading edge, the avatar at the trailing edge, the pills and the scrim gone"
            + (missing.isEmpty ? "" : " (missing targets: \(missing.joined(separator: ", ")))")
    )
}
