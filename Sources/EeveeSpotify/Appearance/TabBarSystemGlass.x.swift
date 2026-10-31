import Foundation
import Orion
import UIKit
import QuartzCore
import ObjectiveC.runtime

/// 标签栏：**把 Spotify 那条栏的内容藏起来，在它上面叠一条系统 `UITabBar`** ——
/// iOS 26 会把它画成真·液态玻璃（选中气泡、折射、明暗自适应），一行玻璃 API 都不用我们写。
///
/// 机制四步：① Spotify 的栏**留着**（frame / 交互 / inset 都不碰），但内容不可见；
/// ② 叠一条系统栏，item 从 Spotify 那几颗同步；③ 选中态跟着 Spotify 标成的那一颗走；
/// ④ 系统栏比 Spotify 的栏高时，把差额写进 `TabBarImpl.additionalSafeAreaInsets.bottom`。
///
/// 硬约束：只藏内容、绝不藏 item 视图（UIKit 的命中测试跳过 `alpha < 0.01` 的视图，藏了
/// item 整条栏就点不动；每个视图要记**它自己的**原 alpha）；宿主必须把底部安全区报成 0
/// （UIKit 按所在视图的安全区量玻璃高度，否则留 34pt 给 Home Indicator，内容区只剩 26pt）；
/// 几何只认 `TabBarGlassPlate.targetCapsuleRect`；只放真正在用的那几颗、按 `tag` 找格；
/// 触摸只在 `probeForwardRoute` 读得出转发路时才接管，全不通就 `handTouchesBack`；栏上不装
/// 任何手势（iOS 26 的玻璃标签栏本来就"按住就能滑"）。选中态判据见 `syncSelection`。
/// 开关：设置 → 扩展功能 → 标签栏 →「标签栏改用系统玻璃」，**默认开**（老版本拨过的盘上值由
/// `UserDefaults.applyTabBarSystemGlassDefaultIfNeeded` 一次性迁移）；关掉 = 系统栏与宿主
/// 移除 + 内容各自恢复原 alpha + `additionalSafeAreaInsets` 写回。日志 tag `[TabBarSystem]`；
/// enum 必须 `@MainActor`（要调 `@MainActor` 的 `TabBarGlassPlate.findTabsStack(in:)`）。
@MainActor
enum TabBarSystemGlass {

    static let logTag = "TabBarSystem"

    /// Spotify 自己那一行的高度（视图树里是 `UIStackView(0,0 414x49)`）。
    private static let stockRowHeight: CGFloat = 49
    /// `TabBarContainerImpl` 的类名：它是 Spotify 那条栏的容器 VC，按类名找它。
    private static let containerClassName = "_TtC23NavigationUI_TabBarImpl19TabBarContainerImpl"

    static var isEnabled: Bool { UserDefaults.tabBarSystemGlass }

    // MARK: - 状态（全部挂在**别人的对象**上：关联对象 / 弱注册表）

    private static var systemBarKey: UInt8 = 0
    private static var hostKey: UInt8 = 0
    private static var relayKey: UInt8 = 0
    private static var roomKey: UInt8 = 0

    /// 被我们按成透明的**内容**视图（图标 / 文字；**弱引用**）+ 各自的原 alpha。
    ///
    /// ⚠️ 两条纪律：
    /// · **只藏内容，不藏 item 视图本身** —— 藏了它，触摸就再也到不了 Spotify 那几颗；
    /// · 每个视图记**它自己的**原 alpha，不能一律写 1（统一写回 = 永久错）。
    private static let hiddenContent = NSHashTable<UIView>.weakObjects()
    private static var hiddenContentAlphas: [ObjectIdentifier: CGFloat] = [:]

    /// 系统栏量出来的高度**只量一次**：让出高度之后 `sizeThatFits` 会要得更多。
    private static var measuredGlassHeight: CGFloat = 0

    /// UIKit 自己留的那圈内边距（**玻璃 = 宿主 − 它**）：**量一次就冻结**，见 `place`。
    private static var glassInsets: UIEdgeInsets?
    private static weak var measuredInsetsBar: UIView?
    /// 上面那份内边距是**按几颗量**的 —— UIKit 的浮岛玻璃按**内容**定宽，三颗与四颗的常量不同
    /// （四颗 21/21、三颗 70/70）⇒ 颗数一变就重量一次。
    private static var glassInsetsCount = -1
    /// 我们是否已经把触摸交还给 Spotify（交还过就**不再收回**，避免"点一下空一下"）。
    private static var handedBackTouches = false
    /// 从"图标视图"快照出来的图标（按视图缓存：每拍生成新图会让 `syncItems` 永远判成"形状变了"）。
    private static var iconSnapshots: [ObjectIdentifier: UIImage] = [:]
    /// 我们装在 **Spotify 自己那条栏**上的那只"点一下"手势（**不抢触摸**，只让气泡立刻对过去）。
    ///
    /// ⚠️ 这里只能有这一只：pan（"按住划 = 滑过哪格切哪格"）`cancelsTouchesInView = true`，
    /// 会吃掉系统玻璃要的那次触摸，还会**替用户换页**、切不动时把气泡拨回原位 ⇒ 已删除。
    /// "跟手"是系统玻璃自己接住手指之后才有的东西，不是我们画出来的。
    private static var stockTapKey: UInt8 = 0
    private static var mirroredSelections = 0
    /// 上一次"探转发路"的时刻（`ProcessInfo.systemUptime`）—— 节流用，见 `probeForwardRouteThrottled`。
    private static var lastProbeAt: TimeInterval = 0
    /// 手势诊断（各只报一次）：见 `reportTapWithoutIndex` / `noteFirstTapSeen`。
    private static var didReportTapWithoutIndex = false
    private static var didNoteFirstTap = false

    private static var lastBar: UIView?
    private static var lastSkipReason = ""
    private static var lastSelectionIndex = -1
    private static var lastSelectionSignal = ""
    private static var didLogLayout = false

    /// 上一次打出去的"玻璃几何"那一行（只在变了的时候打，别刷屏）。
    private static var lastGeometryLine = ""
    /// 转发成功的次数：**只报前几次**（证明这条路通就够了，别把日志刷满）。
    private static var forwardedTaps = 0

    // MARK: - 对外入口
    //
    // 幂等。由 `TabBarPlateHook.layoutSubviews`（栏自己每次布局）与复查节拍调用。
    static func apply(to bar: UIView) {
        lastBar = bar

        guard isEnabled else {
            remove(reason: "switch off", in: bar)
            return
        }
        guard bar.bounds.width > 1, bar.bounds.height > 1 else { return }
        guard let stack = TabBarGlassPlate.findTabsStack(in: bar) else {
            noteSkipOnce("no tabs stack yet")
            return
        }

        // 复查节拍上再压一次（幂等）：Spotify 可能把「创建」显示回来。
        // 主驱动是栏自己的布局回合（`TabBarPlateHook.layoutSubviews`），这里是保险。
        // ⚠️ **必须在下面取 `items` 之前** —— 顺序反了的话，第一拍会按四颗镜像一次。
        TabBarGlassPlate.applyCreateTabVisibility(in: bar)

        // 这里的**输入**是"占着槽位的那几颗"（`visibleItems` = **四格**）。
        // 藏掉「创建」之后它**仍然占着第 4 格**（`applyCreateTabVisibility` 只把它按透明、
        // 点不到，不用 `isHidden`）—— 这是**几何**要的：宿主/玻璃的宽度按四格算，
        // 才不随那颗开关变（四颗 360×60 → 三颗 274×60；而迷你条按 `capsuleWidthRatio`
        // 等宽跟随 ⇒ 一起缩）。
        // ⚠️ 但**系统栏只放真正在用的那几颗**（`syncItems` 跳过被藏的那一格）+
        // `itemPositioning = .centered` + `itemWidth` ⇒ 三颗把整块玻璃**三等分**。
        // `item.tag` 是"占位列表"里的下标，转发与选中态都按它对齐（见 `item(at:on:)`）。
        let items = TabBarGlassPlate.visibleItems(in: stack)
        guard !items.isEmpty else { return }

        // ② 先同步系统栏 —— **顺序要紧**：下面"藏什么"取决于"镜像到了什么"
        // （拿不到图标的那一颗，原图标要留着当安全网）。
        let systemBar = ensureBar(in: bar)
        let mirrored = syncItems(on: systemBar, from: items)

        // ① 藏内容（**不是整颗 item**）：只藏那些已经镜像过去的图标，以及文字。
        hideStockContent(items: items, mirroredIcons: mirrored.icons)

        // ③ 选中态：气泡跟着 Spotify 走。
        syncSelection(on: systemBar, items: items)

        // 把"点一下"装到 **Spotify 自己那条栏**上（不抢它的触摸，只让气泡立刻对过去）。
        installStockGestures(on: bar)

        // **系统栏该不该接管触摸**？—— 判据是"能不能在**点之前**把转发路读出来"
        // （见 `probeForwardRoute`）。能读出来 ⇒ 玻璃才接得住手指（"跟手"与折射就是从这里来的）；
        // 读不出来 ⇒ 照旧把触摸留给 Spotify 那条栏，并把那条链**逐环**写进日志。
        // ⚠️ **一旦交还过触摸就不再收回**（否则会"点一下空一下"地来回抖）。
        if !handedBackTouches, !systemBar.isUserInteractionEnabled,
           let route = probeForwardRouteThrottled(in: bar) {
            systemBar.isUserInteractionEnabled = true
            hostView(for: bar)?.isUserInteractionEnabled = true
            writeDebugLog(
                "[\(logTag)] a forward route showed up — \(describe(route));"
                    + " the system bar takes the touches now (the glass answers the finger, taps are forwarded)"
            )
        }

        // 摆位：把宿主/系统栏摆成几何判据算出来的那一块（`TabBarGlassPlate.targetCapsuleRect`）。
        place(systemBar, in: bar)

        // ④ 让高度（放在最后：量高度要用**还没让过高度**的那次结果）。
        makeRoom(for: bar, systemBar: systemBar)

        // 把"我们给的框"与"UIKit 真画出来的玻璃"放进同一行 ——
        // 只有实测数字能收敛（UIKit 按自己的内边距画，我们给的框 ≠ 玻璃框）。
        reportGlassGeometry(systemBar, in: bar)

        logLayoutOnce(bar: bar, items: items, systemBar: systemBar, mirrored: mirrored)
    }

    /// 设置页切开关 / 复查节拍用：手里那次记下的栏还在窗口里就当场重来一次。
    static func reapply() {
        guard let bar = lastBar, bar.window != nil else { return }
        apply(to: bar)
    }

    /// 拿走（关开关 / 页面走了）。**精确还原三件事**：系统栏与宿主、内容 alpha、`additionalSafeAreaInsets`。
    static func remove(reason: String, in bar: UIView? = nil) {
        let target = bar ?? lastBar
        if let target {
            if let systemBar = objc_getAssociatedObject(target, &systemBarKey) as? UITabBar {
                systemBar.delegate = nil
                systemBar.removeFromSuperview()
                objc_setAssociatedObject(target, &systemBarKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                writeDebugLog("[\(logTag)] system bar removed (reason=\(reason))")
            }
            if let host = objc_getAssociatedObject(target, &hostKey) as? UIView {
                host.removeFromSuperview()
                objc_setAssociatedObject(target, &hostKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            objc_setAssociatedObject(target, &relayKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            // 装在 Spotify 那条栏上的那只"点一下"手势也要摘掉 —— 不然关掉开关之后它还挂着。
            if let tap = objc_getAssociatedObject(target, &stockTapKey) as? UIGestureRecognizer {
                target.removeGestureRecognizer(tap)
                objc_setAssociatedObject(target, &stockTapKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            restoreRoom(in: target)
        }
        restoreStockContent()
        measuredGlassHeight = 0
        glassInsets = nil
        measuredInsetsBar = nil
        glassInsetsCount = -1
        handedBackTouches = false
        iconSnapshots.removeAll()
        mirroredSelections = 0
        lastProbeAt = 0
        didReportTapWithoutIndex = false
        didNoteFirstTap = false
        didLogLayout = false
        lastSelectionIndex = -1
        lastSelectionSignal = ""
        lastGeometryLine = ""
        forwardedTaps = 0
    }

    // MARK: - ① 藏 Spotify 自己的内容（**不藏 item 本身**）
    //
    // 藏**图标与文字**：图标只藏"已经镜像到系统栏"的那些（安全网），文字一律藏
    // （文字要么由系统栏画标题，要么本来就该没有 —— 见 `tabBarHideLabels`）。
    //
    // ⚠️ 图标视图**不只是** `UIImageView`：这一版的图标是 `SPTEncoreIconView`，
    // 只藏 `glyphViews` 会一颗都藏不住，镜像出来的图标和原图标**叠在一起**。
    // ⇒ **镜像到了什么就藏什么**：`findIconView`（我们取快照的那颗）与 `glyphViews` 一起藏。
    private static func hideStockContent(items: [UIView], mirroredIcons: [Bool]) {
        for (index, item) in items.enumerated() {
            if index < mirroredIcons.count, mirroredIcons[index] {
                var glyphs: [UIView] = glyphViews(in: item)
                if let iconView = findIconView(in: item) { glyphs.append(iconView) }
                for glyph in glyphs { hide(glyph) }
            }
            for label in labelViews(in: item) { hide(label) }
        }
    }

    private static func hide(_ view: UIView) {
        guard view.alpha != 0 else { return }
        if hiddenContentAlphas[ObjectIdentifier(view)] == nil {
            hiddenContentAlphas[ObjectIdentifier(view)] = view.alpha
            hiddenContent.add(view)
        }
        view.alpha = 0
    }

    /// 还原成**每一个自己的**原 alpha（没记过的不碰）。
    private static func restoreStockContent() {
        for view in hiddenContent.allObjects {
            if let original = hiddenContentAlphas[ObjectIdentifier(view)] {
                view.alpha = original
            }
        }
        hiddenContent.removeAllObjects()
        hiddenContentAlphas.removeAll()
    }

    // MARK: - ② 系统栏、它的宿主与它的 item

    private struct Mirror {
        var icons: [Bool]
        var titles: [String?]
    }

    private static func ensureBar(in bar: UIView) -> UITabBar {
        if let existing = objc_getAssociatedObject(bar, &systemBarKey) as? TabBarSystemGlassBar {
            if existing.superview !== hostView(for: bar) { hostView(for: bar)?.addSubview(existing) }
            return existing
        }

        // 宿主：**只负责把底部安全区让掉**（见 `TabBarSystemGlassHost` 的说明）。
        // UIKit 按"所在视图的安全区"量玻璃条的高度，宿主报 0 才不会多留 34pt。
        let host = TabBarSystemGlassHost()
        host.backgroundColor = .clear
        host.accessibilityIdentifier = "eevee-tabbar-system-glass-host"

        // **"要不要接管触摸" = "能不能在点之前把转发路读出来"**（见 `probeForwardRoute`）。
        // 只认第 ① 条公开路（容器是 `UITabBarController`）是不行的：真机上容器**不是**
        // ⇒ 判定永远 false ⇒ **系统栏从来没接过一次触摸** ⇒ 玻璃只是一张画
        // （没有按下回弹、没有折射响应，也没有 UIKit 自己的跟手）。
        // 反过来，一旦接管，转发就必须真的成立 —— 否则立刻变成"看得见、点不动"。
        let route = probeForwardRoute(in: bar)
        let takesTouches = route != nil
        host.isUserInteractionEnabled = takesTouches

        let systemBar = TabBarSystemGlassBar(frame: host.bounds)
        systemBar.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // UIKit 按"这条栏继承到的外观"画玻璃，而这条栏在 Spotify 自己的深色导航栈之外
        // ⇒ 浅色模式的手机上会出现"亮玻璃压在纯黑上"。Spotify 永远是深色，这条栏也是。
        systemBar.overrideUserInterfaceStyle = .dark
        systemBar.accessibilityIdentifier = "eevee-tabbar-system-glass"
        systemBar.isUserInteractionEnabled = takesTouches
        // 自己的背景不要画：我们要的是系统玻璃本身。
        systemBar.backgroundImage = UIImage()
        systemBar.shadowImage = UIImage()
        systemBar.isTranslucent = true
        // 剩下的几颗要**等分整块玻璃**。
        // ⚠️ **`.fill` 在 iOS 26 这条新玻璃上不生效**（三颗仍然每颗 94、按内容居中、
        // platter 274），而且 `.fill` 会把 `itemWidth` 一起吃掉
        // ⇒ 改用 **`.centered` + `itemWidth`**（每颗宽度 = 目标胶囊宽 / 颗数，见 `place`）：
        // 三颗的方案就是"各占 1/3"，而且 platter 会跟着 item 宽度回到 360。
        systemBar.itemPositioning = .centered

        let relay = TabBarSystemGlassRelay()
        systemBar.delegate = relay
        objc_setAssociatedObject(bar, &relayKey, relay, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        // **手指落在哪条栏上，哪条栏就得有手势** —— 触摸归系统玻璃时，这条栏上一次触摸都
        // 收不到，所以"点一下立刻对气泡"这只也得装在这里（两只各装一遍，`label` 区分日志）。
        installStockGestures(on: systemBar, label: "our system glass")

        host.addSubview(systemBar)
        bar.addSubview(host)
        bar.bringSubviewToFront(host)
        objc_setAssociatedObject(bar, &systemBarKey, systemBar, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(bar, &hostKey, host, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        writeDebugLog(
            "[\(logTag)] system bar added \(frameText(bar.bounds)) on \(NSStringFromClass(type(of: bar)))"
                + " — in a host that reports no bottom safe area"
                + "; forward route probe: \(describe(route))"
                + (takesTouches
                    ? "; the system bar takes the touches (that is what makes the glass answer a finger)"
                    : "; leaving the touches to Spotify's own bar (nothing readable to forward a tap to,"
                        + " so tapping behaves exactly as before) — chain: \(chainDescription(in: bar))")
        )
        return systemBar
    }

    // MARK: - 转发路**读得出来**才接管触摸
    //
    // "点了某颗之后谁来接"——**在建栏时就能读出来的那几条路**。
    //
    // 为什么必须"读得出来"才算数：系统栏一旦接管触摸，Spotify 那几颗就再也收不到点击
    // ⇒ 转发要是落空，标签栏立刻变成"看得见、点不动"（仓库红线）。所以判据从
    // "先接管、失败了再还回去"（会白丢第一下）改成"**先证明有人接**"。
    private enum ForwardRoute {
        /// ① 公开 API：容器是 `UITabBarController`，`selectedIndex` 就能换页。
        case container(controllers: Int)
        /// ② item 子树里那颗 tap 识别器的 `_targets` 里有一对**目标真的响应**的 target/action
        /// （`TabBarItemElementUI` 的 `-handleTap` 就是它）。
        case tapRecognizer(index: Int, target: String, action: String)
        /// ①′ 容器**自己带着的那几个 view controller**（这台机器上容器不是 `UITabBarController`，
        /// 但它答 `setSelectedViewController:`）⇒ 直接用它的 setter 换页 ——
        /// **完全不依赖 Element 的私有手势**，所以这是最稳的一条路。
        case containerControllers(count: Int)
        /// ③ 子树里（响应链或 ivar 上）有对象响应 `-handleTap`。
        case handleTap(index: Int, holder: String)
        /// ⑤ 子树里有 `UIControl`（`sendActions` 能点）。
        case control(index: Int, name: String)
    }

    /// 一行说清"是**哪条**路、在哪一颗上"。否则"接管了又点不动"没法复盘。
    private static func describe(_ route: ForwardRoute?) -> String {
        guard let route = route else { return "none — no route can be read before a tap" }
        switch route {
        case .container(let controllers):
            return "route ① (public) the container is a UITabBarController with \(controllers) view controllers"
        case .containerControllers(let count):
            return "route ①′ the container carries \(count) view controllers of its own"
                + " (it answers setSelectedViewController:)"
        case .tapRecognizer(let index, let target, let action):
            return "route ② (pw's) the tap recogniser on #\(index) fires \(target):\(action)"
        case .handleTap(let index, let holder):
            return "route ③ handleTap answers on #\(index) (found on \(holder))"
        case .control(let index, let name):
            return "route ⑤ a UIControl on #\(index) (\(name)) answers sendActions"
        }
    }

    /// 一条都读不出来时，把**那条链逐环**写出来（`_targets` 在不在 / 有几对 / 每对解出来什么）。
    /// 这是"为什么那套转发写法在这版不通"的唯一判据。
    private static func chainDescription(in bar: UIView) -> String {
        guard let stack = TabBarGlassPlate.findTabsStack(in: bar) else { return "no tabs stack yet" }
        // ⚠️ 与转发用的是**同一份列表**（看得见的那几颗）—— 编号必须对得上。
        let items = TabBarGlassPlate.visibleItems(in: stack)
        return items.enumerated().map { index, item -> String in
            let name = shortName(NSStringFromClass(type(of: item)))
            let pieces = subtree(of: item, maxDepth: 6).flatMap { view -> [String] in
                (view.gestureRecognizers ?? []).map { recognizer in
                    "\(describe(recognizer)) on \(shortName(NSStringFromClass(type(of: view))))"
                }
            }
            return "#\(index) \(name)[\(pieces.isEmpty ? "no recognisers at all" : pieces.joined(separator: " | "))]"
        }.joined(separator: "; ")
    }

    /// 探一次：**能读出来的**第一条路（顺序与 `forwardTap` 一致，从最公开到最私有）。
    ///
    /// ⚠️ 只探"点得动"这件事；`accessibilityActivate` 那条**探不出来**（要真调一次才知道），
    /// 所以它只能留在 `forwardTap` 的兜底里，不能当接管触摸的判据。
    private static func probeForwardRoute(in bar: UIView) -> ForwardRoute? {
        let stack = TabBarGlassPlate.findTabsStack(in: bar)
        let itemCount = stack.map { TabBarGlassPlate.visibleItems(in: $0).count } ?? 0
        if let container = container(of: bar), let tabs = container as? UITabBarController,
           let controllers = tabs.viewControllers, controllers.count >= 2 {
            return .container(controllers: controllers.count)
        }
        // 容器**自己带着**那几个 VC 那一条：它比 route ② 更稳（不碰 Element 的私有手势），
        // 所以排在识别器前面。
        // ⚠️ 个数必须与"看得见的标签数"一致才敢按下标取（否则可能是别的 VC 数组）。
        if let container = container(of: bar), let controllers = containerControllers(of: container),
           itemCount == 0 || controllers.count == itemCount {
            return .containerControllers(count: controllers.count)
        }
        guard let stack else { return nil }
        // ⚠️ 只探**转得出去的**那几颗：被我们藏掉的「创建」即使读得出转发路也不算数
        // （它在系统栏那边是 `isEnabled = false`，永远选不到 ⇒ 拿它当判据等于白丢一下）。
        let items = TabBarGlassPlate.visibleItems(in: stack)
        for (index, item) in items.enumerated() where !TabBarGlassPlate.isMutedTabItem(item) {
            if let recognizer = firstFireableTapRecognizer(in: item, index: index) { return recognizer }
        }
        for (index, item) in items.enumerated() where !TabBarGlassPlate.isMutedTabItem(item) {
            if let holder = handleTapHolder(in: item) {
                return .handleTap(index: index, holder: holder.via)
            }
        }
        for (index, item) in items.enumerated() where !TabBarGlassPlate.isMutedTabItem(item) {
            if let control = subtree(of: item, maxDepth: 6).first(where: { $0 is UIControl }) {
                return .control(index: index, name: shortName(NSStringFromClass(type(of: control))))
            }
        }
        return nil
    }

    /// 子树里第一颗"**真的点得动**"的 tap 识别器：`_targets` 里至少有一对 target/action 能解出来，
    /// 且那个 target 能接住那个 action。读不出来就返回 nil（= 这条路不能算数）。
    ///
    /// ⚠️ **target 是 `nil` 也算数**：这台机器上那颗识别器逐字是
    /// `UITapGestureRecognizer[nil-target:handleTap]` —— `_action` 读得出来、`_target` 是 `nil`
    /// （Element 那边大概是"稍后再绑 target"或"走响应链"）。所以判据是**只要 action 读得出来**
    /// 就算有路；`nil` target 那一对在**点击那一刻**再读一次（也许那时已经绑上了），
    /// 仍然 `nil` 就走 `sendAction(to: nil)` 与响应链（见 `fire`）。
    private static func firstFireableTapRecognizer(in item: UIView, index: Int) -> ForwardRoute? {
        for view in subtree(of: item, maxDepth: 6) {
            for recognizer in view.gestureRecognizers ?? [] {
                guard recognizer is UITapGestureRecognizer, recognizer.isEnabled else { continue }
                for pair in pairs(of: recognizer) {
                    guard let action = action(of: pair) else { continue }
                    // target 是 `nil` **也算数**：见上面那段说明。
                    // ⚠️ 门与 `fire` 保持一致：**runtime 里找得到那个方法**就算数，
                    // 不用 `responds(to:)`（Element 的 Swift target 过不了那道门）。
                    let target = target(of: pair)
                    if let target,
                       class_getInstanceMethod(type(of: target), action) == nil,
                       !((target as? NSObject)?.responds(to: action) ?? false) {
                        continue
                    }
                    return .tapRecognizer(
                        index: index,
                        target: target.map { shortName(NSStringFromClass(type(of: $0))) } ?? "nil (responder chain)",
                        action: NSStringFromSelector(action)
                    )
                }
            }
        }
        return nil
    }

    /// 探一次要**走一遍四颗的子树**，而 `apply` 每次布局 + 每 0.5s 复查都会进来
    /// ⇒ 只在"系统栏还没接管触摸"这一档里探，并且**最多 1s 一次**（第一次立刻探）。
    /// 一旦接管了触摸就不再探（`apply` 那条 `if` 直接短路）。
    private static func probeForwardRouteThrottled(in bar: UIView) -> ForwardRoute? {
        let now = ProcessInfo.processInfo.systemUptime
        guard lastProbeAt == 0 || now - lastProbeAt >= 1 else { return nil }
        lastProbeAt = now
        return probeForwardRoute(in: bar)
    }

    private static func hostView(for bar: UIView) -> TabBarSystemGlassHost? {
        objc_getAssociatedObject(bar, &hostKey) as? TabBarSystemGlassHost
    }

    /// **把宿主摆成几何判据算出来的那一块**（`TabBarGlassPlate.targetCapsuleRect`）。
    ///
    /// **UIKit 画的玻璃比我们给的框小一圈**：`host 27,-3,360,60` → 它画出来的
    /// `_UITabBarItemPlatterView` 是 `48,-3,318,39` ⇒ 它自己留了 **左右各 21、底 21**（顶 0）。
    /// 所以修法**不写死 21**，而是按**实测差**把宿主往外扩 —— 关系是"玻璃 = 宿主 − 常量"
    /// ⇒ 一次收敛、幂等。拿不到可信几何（首次布局 / 栏还没进窗口 / 玻璃还没排完）时
    /// 退回"整条栏"，下一拍再对齐 —— 绝不因为量不到就把玻璃藏起来。
    ///
    /// 内边距**量一次就冻结**（`glassInsets`），而且只认**栏自己那块 platter**
    /// （见 `drawnGlassFrame`）。每拍都重量的话，选中动画期间那几块 platter 的尺寸会动
    /// ⇒ 宿主跟着变 ⇒ 玻璃肉眼可见地忽大忽小。冻结之后：量一次 → 之后每拍只按它摆位。
    private static func place(_ systemBar: UITabBar, in bar: UIView) {
        guard let host = hostView(for: bar) else { return }
        let target = TabBarGlassPlate.targetCapsuleRect(in: bar) ?? bar.bounds

        // UIKit 这块浮岛玻璃是**按 item 宽度**撑出来的（三颗 → platter 274；四颗 → 360），
        // 而 `.fill` 在 iOS 26 这条新玻璃上不生效 ⇒ 只能**把每颗的宽度钉死**：
        // 每颗宽 = 目标胶囊宽 / 颗数
        // ⇒ 三颗时正好把 360 三等分（item 中心 60 / 180 / 300），
        // 而且 platter 的宽度回到 360（与"创建还在"时一致）。
        // ⚠️ 幂等：只在真的变了才写（写 `itemWidth` 会触发一次布局 ⇒ 否则每拍互相打）。
        if let count = systemBar.items?.count, count > 1, target.width > 1 {
            let wanted = (target.width / CGFloat(count)).rounded()
            if abs(systemBar.itemWidth - wanted) > 0.5 {
                systemBar.itemWidth = wanted
                writeDebugLog(
                    "[\(logTag)] item width pinned to \(Int(wanted))pt"
                        + " (\(Int(target.width))pt capsule / \(count) item(s))"
                        + " — UIKit sizes the glass after the items, so this is what makes"
                        + " the remaining tabs split it evenly"
                )
            }
        }

        // 量内边距时**必须按"看得见的颗数"分家**：
        // ① 四颗量到 21/21，藏掉「创建」变三颗之后是 **70/70** —— UIKit 的浮岛玻璃是
        // **按内容**定宽的（三颗更窄），所以"玻璃 = 宿主 − 常量"这个常量**随颗数变**。
        // 冻结本身没错（防漂），错的是"换形状了还沿用旧常量" ⇒ 这里按颗数重量一次。
        // ② 宿主**不许越出栏**：曾量到 `-29,-3,472,81`（栏只有 414），越界那 29pt 两边
        // 没有任何用途，只会让命中区域跑到栏外。
        let visibleCount = TabBarGlassPlate.findTabsStack(in: bar)
            .map { TabBarGlassPlate.visibleItems(in: $0).count } ?? 0
        if measuredInsetsBar !== bar || glassInsetsCount != visibleCount {
            measuredInsetsBar = bar
            glassInsets = nil
            glassInsetsCount = visibleCount
        }
        let drawn = drawnGlassFrame(in: systemBar, in: bar)
        if glassInsets == nil, let drawn {
            let insets = UIEdgeInsets(
                top: drawn.minY - host.frame.minY,
                left: drawn.minX - host.frame.minX,
                bottom: host.frame.maxY - drawn.maxY,
                right: host.frame.maxX - drawn.maxX
            )
            glassInsets = insets
            writeDebugLog(
                "[\(logTag)] glass insets measured once — left \(Int(insets.left)) right \(Int(insets.right))"
                    + " top \(Int(insets.top)) bottom \(Int(insets.bottom))"
                    + " (UIKit keeps them to itself; the host is expanded by them so the glass lands on our capsule;"
                    + " measured once on purpose, so the glass cannot drift)"
            )
        }
        let insets = glassInsets ?? .zero
        let wanted = CGRect(
            x: target.minX - insets.left,
            y: target.minY - insets.top,
            width: target.width + insets.left + insets.right,
            height: target.height + insets.top + insets.bottom
        )
        // ⚠️ 夹回栏里（见上面 ②）：交集为空时退回整条栏，绝不把宿主摆到栏外。
        let clamped = wanted.intersection(bar.bounds)
        let frame = clamped.isNull ? bar.bounds : clamped
        if !host.frame.equalTo(frame) { host.frame = frame }
        if !systemBar.frame.equalTo(host.bounds) { systemBar.frame = host.bounds }

        // ⛔ **迷你播放条与标签栏玻璃解绑**：这里**不按"UIKit 真画的那块"刷新**
        // `capsuleWidth` / `capsuleWidthRatio`。那两个量保持**几何算出来的**那一份
        // （`TabBarGlassPlate.capsuleRect`：= "四格收紧后那条带 + 88"，360/414 ≈ 0.87）
        // ⇒ 迷你条回到原本 ~346pt，而且**不再随标签栏玻璃的宽度变**
        // （苹果给三颗的原生宽度是 274，那只是标签栏自己的事）。
    }

    // MARK: - 拖动胶囊：**系统自带，我们不碰**
    //
    // **原生 iOS 26 的液态玻璃标签栏本来就能"按住就滑"**：手指一贴上那条栏就能横向滑，
    // 选中镜片**立刻跟手**、松手选中手指下那一颗 —— 不用先长按。苹果 WWDC25
    // 「Build a UIKit app with the new design」里，标签栏（`UITabBarController`）整个是
    // 系统那一套（浮动玻璃 + 选中镜片 + minimize on scroll），**没有"自己画胶囊"这条题**。
    //
    // ⇒ 结论：**这一层一行代码都不该写**。我们唯一要做的是"别把触摸从系统栏手里拿走"
    // （见 `probeForwardRoute`：玻璃接管触摸 ⇒ 苹果那套交互才有机会发生）。
    //
    // ⚠️ 两条走不通的路，别再走回去：
    // ① 在 **Spotify 那条栏**上装 pan"滑过哪格切哪格"，每次 `.changed` 都提交
    // ⇒ 不跟手 / 胶囊回弹 / 替用户按按键；
    // ② 在**我们宿主**上装 pan、逐格切 + 独立开关 ⇒ **与系统自己那套重复**，
    // 而系统那套（连续跟手）比我们写得好。SwiftUI 自绘的标签栏才需要自己实现这件事，
    // 我们用的是**真系统栏**，所以归 UIKit。
    //
    // UIKit 自己画的那块玻璃 —— **只认 `UITabBarPlatterView` 那条线**（栏自己的 platter）。
    //
    // ⚠️ 不能按"面积最大"挑：同一族里还有 `_UITabBarItemPlatterView`（**选中那颗的气泡**）
    // 与 `_UILiquidLensView`（选中透镜）—— 它们的尺寸**随选中态变**，按面积挑会在点标签时
    // 挑到它们 ⇒ 宿主跟着变 ⇒ 玻璃忽大忽小。
    // 另外要求宽度至少是栏宽的四成（排到一半的 0×0 一律不要）。
    private static func drawnGlassFrame(in systemBar: UITabBar, in bar: UIView) -> CGRect? {
        let widest = max(bar.bounds.width, 1)
        return platterViews(in: systemBar)
            .filter { shortName(NSStringFromClass(type(of: $0.1))).contains("UITabBarPlatterView") }
            .map { $0.1.convert($0.1.bounds, to: bar) }
            .filter { $0.width > widest * 0.4 && $0.height > 1 }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    /// 从 Spotify 那几颗同步 item（**顺序一致**，索引就是选中态与转发的对齐依据）。
    ///
    /// 三条约束：
    /// · 「隐藏标签栏文字」开着时**不给标题** —— 这一条得由这里负责，否则文字仍然留着；
    /// · 图标拿不到就**照实记 `false`**（`glyphImage` 没找到）—— 调用方据此**不藏**原来那颗图标；
    /// · `tag` = 索引：转发要用它（`didSelectItem` 只给 item，不给序号）。
    private static func syncItems(on systemBar: UITabBar, from items: [UIView]) -> Mirror {
        let hidesLabels = UserDefaults.tabBarHideLabels

        var wanted: [UITabBarItem] = []
        var icons: [Bool] = []
        var titles: [String?] = []
        wanted.reserveCapacity(items.count)

        for (index, item) in items.enumerated() {
            // 被我们"保住槽位、只藏内容"的那一颗（「创建」）：**系统栏不给它 item**。
            // 它的槽位留在 **Spotify 那条栏**里（撑住我们的几何 ⇒ 宿主/玻璃的宽度不变），
            // 而系统栏只放**真正在用的那几颗** —— 配合 `itemWidth` 的等分，
            // 它们会把整块玻璃**三等分**。
            let muted = TabBarGlassPlate.isMutedTabItem(item)
            let title = (hidesLabels || muted) ? nil : labelText(of: item)
            let image = muted ? nil : glyphImage(of: item)?.withRenderingMode(.alwaysTemplate)
            // ⚠️ `icons` / `titles` **每一格都要有**：`hideStockContent` 是按位置跟 `items` 对齐的。
            icons.append(image != nil)
            titles.append(title)
            guard !muted else { continue }
            wanted.append(UITabBarItem(title: title, image: image, tag: index))
        }

        let mirror = Mirror(icons: icons, titles: titles)
        let current = systemBar.items ?? []
        let sameShape = current.count == wanted.count && zip(current, wanted).allSatisfy { pair in
            pair.0.title == pair.1.title && pair.0.image === pair.1.image
        }
        guard !sameShape else { return mirror }

        systemBar.items = wanted
        lastSelectionIndex = -1
        writeDebugLog(
            "[\(logTag)] items synced — \(wanted.count) item(s) over \(items.count) slot(s)"
                + (wanted.count < items.count
                    ? " (the muted Create slot keeps the row at full width; the system bar just"
                        + " does not get an item for it, so the other tabs split it evenly)"
                    : "")
                + "; titles \(titles.map { $0 ?? "-" })"
                + "; icons \(icons.map { $0 ? "Y" : "N" })"
                + (hidesLabels ? " (the hide-labels switch is on, so no titles)" : "")
        )
        return mirror
    }

    /// 按 `tag` 找系统栏上对应的那一格。
    ///
    /// ⚠️ **不要用 `items[index]` 直接下标**：被我们藏掉的那一格（「创建」）**不在系统栏的
    /// item 列表里**（它只留在 Spotify 那条栏里撑着几何 ⇒ 两边下标不再一一对应）。
    /// `tag` 才是"占着槽位的那几颗"里的下标 —— `forwardSelection` 用的也是同一套。
    private static func item(at index: Int, on systemBar: UITabBar) -> UITabBarItem? {
        guard index >= 0 else { return nil }
        return systemBar.items?.first { $0.tag == index }
    }

    // MARK: - 把系统栏上的选择**转发**成 Spotify 那一颗的点击
    //
    // 系统栏选中了某一颗（`delegate` 中继叫到这里）。**只在主 actor 上跑**。
    //
    // 为什么必须转发：系统栏**接管了触摸** ⇒ 手指再也落不到 Spotify 那几颗上。
    // 不转发就是那条红线（"看得见、点不动"）。
    static func forwardSelection(from systemBar: UITabBar, item: UITabBarItem) {
        guard let bar = lastBar, let stack = TabBarGlassPlate.findTabsStack(in: bar) else {
            writeDebugLog("[\(logTag)] ⚠️ a tab was picked but the stock row is gone — nothing to forward to")
            return
        }
        // ⚠️ 与 `syncItems` 用的是**同一份列表**（`visibleItems`）：`item.tag` 就是它的下标。
        // 藏掉「创建」之后这里是三颗 —— 拿 `stack.subviews` 会把第 3 颗转发到第 4 颗上。
        let items = TabBarGlassPlate.visibleItems(in: stack)
        let index = item.tag
        guard index >= 0, index < items.count else {
            writeDebugLog("[\(logTag)] ⚠️ picked item tag \(index) is out of range (\(items.count) item(s))")
            return
        }
        // 被我们藏掉的那一格（「创建」）**不该被转发**：它现在压根不在系统栏的 item 列表里
        // （`syncItems` 跳过它）⇒ 正常永远选不到；这里再兜一道，将来若把它加回来也不会误转发。
        guard !TabBarGlassPlate.isMutedTabItem(items[index]) else {
            writeDebugLog("[\(logTag)] picked the muted tab #\(index) — nothing to forward to")
            return
        }
        forwardTap(to: items[index], index: index, systemBar: systemBar)

        // Spotify 会在 ~0.25s 后重画标签颜色（那是我们唯一的选中态信号）⇒ 那一刻再对一次气泡。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { reapply() }
    }

    /// 五条路依次试，**顺序是"从最公开到最私有"**：
    ///
    /// ① **`UITabBarController.selectedIndex`** —— Spotify 那条栏的容器
    /// （`NavigationUI_TabBarImpl.TabBarContainerImpl`）**是 `UITabBarController` 的子类**
    /// ⇒ `selectedIndex` 就是"用户点了那一颗"的等价物，**一行签名都不用猜**。
    /// ①′ 容器的 `setSelectedViewController:`（容器不是 `UITabBarController` 时走这条，
    /// 不碰 Element 的私有手势）。
    /// ② 读 item 子树里 tap 识别器的 target/action 并触发它；
    /// ③ `-handleTap`：不猜签名、只找"响应它的对象"；
    /// ④ `accessibilityActivate` → ⑤ `UIControl.sendActions`。
    /// 全不通就**把触摸还给 Spotify 那条栏**（见 `handTouchesBack`）——
    /// 宁可不要"按下回弹"，也绝不能留下"看得见、点不动"。
    private static func forwardTap(to item: UIView, index: Int, systemBar: UITabBar) {
        if selectThroughContainer(index: index) {
            reportForward(index: index, route: "UITabBarController.selectedIndex on Spotify's own container")
            return
        }
        // ①′：容器**自己带着**那几个 VC 时，直接叫它的 `setSelectedViewController:` ——
        // Spotify 内部就是这一步，而且**不依赖 Element 的私有手势**。
        // 排在 ② 前面是有意的：它能用就先用它。
        if selectThroughContainerControllers(index: index) {
            reportForward(index: index, route: "setSelectedViewController: on Spotify's own container")
            return
        }
        if fireTapRecognizers(in: item) {
            reportForward(index: index, route: "the item's own tap recognizer")
            return
        }
        if callHandleTap(in: item) {
            reportForward(index: index, route: "handleTap on the item's element")
            return
        }
        if activateAccessibility(in: item) {
            reportForward(index: index, route: "accessibilityActivate")
            return
        }
        if sendControlActions(in: item) {
            reportForward(index: index, route: "UIControl.sendActions")
            return
        }
        reportForwardFailure(index: index, item: item)
        // 全失败时把"这颗识别器的 target 藏在哪"摊开一次 —— 见 `reportTapAnatomyOnce`。
        reportTapAnatomyOnce(item)
        handTouchesBack(to: systemBar, reason: "every route failed on #\(index)")
    }

    /// ① 公开 API：让 Spotify 自己的容器换页（= 那条栏的 `selectedIndex`）。
    ///
    /// 判据：容器是 `UITabBarController` 的子类、并且它的 `viewControllers` 里有第 index 个。
    /// 对不上就**什么都不做**（返回 false，交给下一路）—— 绝不瞎改别人的选中态。
    private static func selectThroughContainer(index: Int) -> Bool {
        guard let bar = lastBar, let container = container(of: bar),
              let tabs = container as? UITabBarController,
              let controllers = tabs.viewControllers,
              index >= 0, index < controllers.count else { return false }
        guard tabs.selectedIndex != index else { return true }
        tabs.selectedIndex = index
        return true
    }

    /// ①′ 容器**自己带着**的那几个 VC（`TabBarContainerImpl` 在这台机器上不是 `UITabBarController`，
    /// 但它答 `setSelectedViewController:`；数组顺序 = 标签顺序）。
    ///
    /// 读法**有界且保守**：只看容器自己（含 3 层父类）的**对象型** ivar（编码 `@`），
    /// 取第一个"每个元素都是 `UIViewController`"的数组；对不上就返回 nil（绝不瞎猜下标）。
    /// ⚠️ Swift 的 `Array` 存储不是 `@` ivar ⇒ 天然被过滤掉，不会把裸指针当数组读。
    private static func containerControllers(of container: UIViewController) -> [UIViewController]? {
        var cls: AnyClass? = type(of: container)
        var hops = 0
        while let current = cls, hops < 3 {
            var count: UInt32 = 0
            if let ivars = class_copyIvarList(current, &count) {
                defer { free(ivars) }
                for index in 0 ..< Int(count) {
                    let ivar = ivars[index]
                    guard let encoding = ivar_getTypeEncoding(ivar), encoding.pointee == 0x40 else { continue }
                    guard let value = object_getIvar(container, ivar) as? [AnyObject] else { continue }
                    let controllers = value.compactMap { $0 as? UIViewController }
                    guard controllers.count == value.count, controllers.count >= 2 else { continue }
                    return controllers
                }
            }
            cls = class_getSuperclass(current)
            hops += 1
        }
        return nil
    }

    /// 把 `setSelectedViewController:` 直接叫在容器身上 —— 这就是 Spotify 点标签时内部走的那一步。
    /// **不碰 Element 的私有手势**，所以最稳。
    private static func selectThroughContainerControllers(index: Int) -> Bool {
        guard let bar = lastBar, let container = container(of: bar),
              let controllers = containerControllers(of: container),
              index >= 0, index < controllers.count else { return false }
        // ⚠️ 只有"VC 个数 == 看得见的标签数"才敢按 `index` 取 —— 否则这可能是别的 VC 数组
        // （导航栈之类），宁可返回 false 交给下一路，也绝不把页面切到不相干的 controller。
        let itemCount = TabBarGlassPlate.findTabsStack(in: bar)
            .map { TabBarGlassPlate.visibleItems(in: $0).count } ?? 0
        guard itemCount == 0 || controllers.count == itemCount else { return false }
        let selector = NSSelectorFromString("setSelectedViewController:")
        guard let method = class_getInstanceMethod(type(of: container), selector) else { return false }
        typealias ObjectiveCMessage = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        let send = unsafeBitCast(method_getImplementation(method), to: ObjectiveCMessage.self)
        send(container, selector, controllers[index])
        writeDebugLog(
            "[\(logTag)] tap → the container's own \(controllers.count) view controllers"
                + " (setSelectedViewController: on #\(index))"
        )
        return true
    }

    // MARK: - 点一下（装在 **Spotify 自己那条栏**上，不抢触摸）
    //
    // 只装**一只**手势：`UITapGestureRecognizer`（**`cancelsTouchesInView = false`**）——
    // 点击照旧由 Spotify 完成（唯一被证明能换页的路），我们**同时**知道点了哪一颗
    // ⇒ **气泡立刻对过去**，不再等 0.5s 复查节拍（节拍那一路气泡是半秒一跳，观感就是"反应慢"）。
    //
    // ⚠️ **它的兄弟 `UIPanGestureRecognizer` 已删除**：那只 pan 做"按住划 = 滑过哪格切哪格"，
    // · `cancelsTouchesInView = true` ⇒ **吃掉那次触摸**，系统玻璃永远接不到手指（不跟手 / 没有反射）；
    // · 每次 `.changed` 都提交 ⇒ **替用户换页**；
    // · 提交不了时把气泡**拨回真实那一颗** ⇒ 看到的"胶囊回弹"。
    //
    // ⚠️ **两条栏各装一遍**：触摸归系统玻璃时，手指全落在我们的系统栏上，Spotify 那条栏上的
    // 识别器一次都收不到。
    // 长按主页进设置那只手势已整体回退（`holdHome` / `openSettingsFromHold` / `holdHomeUntil`
    // 一并删掉）；落点 `EeveeSettingsLauncher` 留着，设置列表里那一行还在用它。
    private static func installStockGestures(on stockBar: UIView, label: String = "Spotify's own bar") {
        if objc_getAssociatedObject(stockBar, &stockTapKey) == nil {
            let tap = UITapGestureRecognizer(
                target: TabBarSystemGlassGestureRelay.shared,
                action: #selector(TabBarSystemGlassGestureRelay.stockTapped(_:))
            )
            tap.cancelsTouchesInView = false
            stockBar.addGestureRecognizer(tap)
            objc_setAssociatedObject(stockBar, &stockTapKey, tap, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            // 这一行是"点一下到底有没有被我们看见"的**判据**：有它而没有 `first tap seen`
            // 就说明触摸没到我们手里（手势没装 / 装了没收到 / 收到了但算不出第几颗，三者靠日志分开）。
            writeDebugLog(
                "[\(logTag)] tap recogniser installed on \(label) — it does not cancel touches,"
                    + " so Spotify still switches the page; we only mirror the bubble at once."
                    + " Waiting for the first tap."
            )
        }
    }

    /// 点击/划动时算"手指在哪一格"（按四颗的 frame 判；落缝里就按 x 等分兜底）。
    ///
    /// ⚠️ 走 `visibleItems`：藏掉「创建」之后这里只有三格，与系统栏那三颗**同序同数**
    /// （两处不一致的话，点第 3 颗会被算成第 4 颗）。
    static func itemIndex(at point: CGPoint, in bar: UIView) -> Int? {
        guard let stack = TabBarGlassPlate.findTabsStack(in: bar) else { return nil }
        let items = TabBarGlassPlate.visibleItems(in: stack)
        if let hit = items.firstIndex(where: { $0.convert($0.bounds, to: bar).contains(point) }) { return hit }
        guard bar.bounds.width > 1, !items.isEmpty else { return nil }
        let ratio = max(0, min(0.999, point.x / bar.bounds.width))
        return Int(ratio * CGFloat(items.count))
    }

    /// **立刻**把气泡对到第 index 颗 —— 这就是"反应慢"那一半的修法（不再等 0.5s 节拍）。
    static func mirrorSelection(index: Int, reason: String) {
        guard isEnabled else { return }
        guard let bar = lastBar,
              let systemBar = objc_getAssociatedObject(bar, &systemBarKey) as? UITabBar,
              let target = item(at: index, on: systemBar) else { return }
        lastSelectionIndex = index
        if systemBar.selectedItem !== target { systemBar.selectedItem = target }
        mirroredSelections += 1
        guard mirroredSelections <= 3 else { return }
        writeDebugLog("[\(logTag)] bubble mirrored straight away — #\(index) (\(reason); no waiting for the 0.5s tick)")
    }

    /// 手势**收到了触摸**，但算不出第几颗（= 手势没问题，是"哪一个"的判据不成立）—— 只报一次。
    static func reportTapWithoutIndex() {
        guard !didReportTapWithoutIndex else { return }
        didReportTapWithoutIndex = true
        writeDebugLog(
            "[\(logTag)] ⚠️ the tap recogniser fired but no tab index could be worked out"
                + " — either the tabs stack is not where we think, or the point is outside all four frames"
        )
    }

    /// 第一次真的收到点击（与上面那行"Waiting for the first tap"配对读：有前者没后者 = 触摸没到我们手里）。
    static func noteFirstTapSeen() {
        guard !didNoteFirstTap else { return }
        didNoteFirstTap = true
        writeDebugLog("[\(logTag)] first tap seen on Spotify's own bar — the bubble now moves at once")
    }

    /// 兜底：五条路全不通 ⇒ **把触摸还给 Spotify 自己那条栏**。
    /// 代价：**只有第一次点击失效**，之后每一次都落到 Spotify 那条栏上（点得动，但没有"按下回弹"）。
    /// 收益：绝不留下"看得见、点不动"。
    /// 之所以能做到"只失效一次"：系统栏一旦不吃触摸，我们的 `delegate` 就不会再被叫到，
    /// 而 `apply` 只在**建栏那一刻**设过 `isUserInteractionEnabled`（之后每拍都不碰它）。
    private static func handTouchesBack(to systemBar: UITabBar, reason: String) {
        guard systemBar.isUserInteractionEnabled else { return }
        handedBackTouches = true
        systemBar.isUserInteractionEnabled = false
        // ⚠️ **宿主必须一起关**：它开着交互、又盖在胶囊那一块上 ⇒ 只关栏的话触摸会被宿主吃掉，
        // 页面既切不动、也没有回弹。
        systemBar.superview?.isUserInteractionEnabled = false
        writeDebugLog(
            "[\(logTag)] ⚠️ \(reason) — handing the touches back to Spotify's own bar so taps keep working from now on;"
                + " the system glass stays as a picture (no press bounce) until the switch is toggled"
        )
    }

    /// **读那颗 item 子树里 tap 识别器自己的 target/action 并触发它**
    /// （`NavigationUI_TabBarImpl.TabBarItemElementUI` 就是用 `-handleTap` 答这个识别器的）。
    ///
    /// ⚠️ `_targets` / `_target` / `_action` 都是私有 ivar —— 这一颗 item 没有公开的点击入口，
    /// 只能走这条路。
    private static func fireTapRecognizers(in item: UIView) -> Bool {
        for view in subtree(of: item, maxDepth: 6) {
            for recognizer in view.gestureRecognizers ?? [] {
                guard recognizer is UITapGestureRecognizer, recognizer.isEnabled else { continue }
                if fire(recognizer) { return true }
            }
        }
        return false
    }

    private static func fire(_ recognizer: UIGestureRecognizer) -> Bool {
        var fired = false
        for pair in pairs(of: recognizer) {
            guard let action = action(of: pair) else { continue }
            if let target = target(of: pair) {
                // ⚠️ 这里**不能**用 `responds(to:)` 当门：target 是 Element 的 Swift 对象
                // （`…19TabBarItemElementUI`），`responds` 会把它误判成"不会响应"，
                // 于是整条路被跳过。改法：**直接用 runtime 找到方法、取 IMP 调** ——
                // 与 UIKit 自己派发这条 action 是同一件事（`handleTap` 无参 ⇒ 只要 self/_cmd）。
                if let method = class_getInstanceMethod(type(of: target), action) {
                    typealias ObjectiveCMessage = @convention(c) (AnyObject, Selector) -> Void
                    let send = unsafeBitCast(method_getImplementation(method), to: ObjectiveCMessage.self)
                    send(target, action)
                    writeDebugLog(
                        "[\(logTag)] tap → \(shortName(NSStringFromClass(type(of: target))))"
                            + " \(NSStringFromSelector(action)) (via its IMP)"
                    )
                    fired = true
                    continue
                }
                // 退一步：`NSObject` 那一支（`perform` 需要 NSObjectProtocol）。
                if let performer = target as? NSObject, performer.responds(to: action) {
                    _ = performer.perform(action, with: recognizer)
                    writeDebugLog(
                        "[\(logTag)] tap → \(NSStringFromClass(type(of: performer)))"
                            + " \(NSStringFromSelector(action)) (via perform)"
                    )
                    fired = true
                    continue
                }
            }
            // `_target` 是 `nil` 的那一对 —— nil target 的动作按 UIKit 的规矩送到**响应者链**上
            // ⇒ 用 `sendAction(to: nil)` 复现同一条路；返回 `false` 说明没人接，
            // 交给下面的兜底（`handleTap` 响应链 / 无障碍 / `UIControl`）。
            if UIApplication.shared.sendAction(action, to: nil, from: recognizer, for: nil) {
                writeDebugLog(
                    "[\(logTag)] tap → responder chain \(NSStringFromSelector(action)) (that pair's target is nil)"
                )
                fired = true
            }
        }
        return fired
    }

    /// 读一条手势的 `_targets`（**私有 ivar**）。读不出来就是空数组 = 这条路不能算数。
    ///
    /// 两处共用：`fire`（真的触发）与 `probeForwardRoute`（**点之前**先读一遍，
    /// 判断"点了有没有人接"）。
    private static func pairs(of recognizer: UIGestureRecognizer) -> [AnyObject] {
        guard let targetsIvar = class_getInstanceVariable(UIGestureRecognizer.self, "_targets"),
              let raw = object_getIvar(recognizer, targetsIvar) as? [AnyObject] else {
            return []
        }
        return raw
    }

    /// 读一对 `_targets` 里的 **target**。
    ///
    /// ⚠️ **不能 `as? NSObject`**：Element 的 target 是 `…19TabBarItemElementUI`（Swift 对象），
    /// `object_getIvar(pair, ivar) as? NSObject` 会把它**读成 nil** ⇒ route ② 永远被跳过、
    /// `sendAction(to: nil)` 又没人接 ⇒ 五条全败 ⇒ 第一次松手就把触摸还了回去。
    /// 所以：先按名字找，再**按 ivar 列表扫**，一律以 `AnyObject` 返回 ——
    /// 是不是 `NSObject` 由调用方按需再判（见 `fire`）。
    private static func target(of pair: AnyObject) -> AnyObject? {
        if let ivar = class_getInstanceVariable(type(of: pair), "_target"),
           let value = object_getIvar(pair, ivar) {
            return value as AnyObject
        }
        var cls: AnyClass? = type(of: pair)
        var hops = 0
        while let current = cls, hops < 3 {
            var count: UInt32 = 0
            if let ivars = class_copyIvarList(current, &count) {
                defer { free(ivars) }
                for index in 0 ..< Int(count) {
                    let ivar = ivars[index]
                    guard let encoding = ivar_getTypeEncoding(ivar), encoding.pointee == 0x40,
                          let name = ivar_getName(ivar), String(cString: name) == "_target" else { continue }
                    if let value = object_getIvar(pair, ivar) { return value as AnyObject }
                }
            }
            cls = class_getSuperclass(current)
            hops += 1
        }
        return nil
    }

    /// `_action` 是 SEL ivar，KVC 读不了（不是对象）⇒ 按 ivar 偏移把指针读出来再转回 `Selector`。
    private static func action(of pair: AnyObject) -> Selector? {
        guard let ivar = class_getInstanceVariable(type(of: pair), "_action") else { return nil }
        let base = Unmanaged.passUnretained(pair).toOpaque()
        let raw = base.advanced(by: ivar_getOffset(ivar))
            .assumingMemoryBound(to: UnsafeRawPointer?.self).pointee
        guard let raw else { return nil }
        return unsafeBitCast(raw, to: Selector.self)
    }

    /// ③ 私有退路：`-handleTap`（`TabBarItemElementUI` 就是用这个方法答那颗 tap 识别器的）。
    ///
    /// **这里不猜参数/返回值** —— 只在"响应这个 selector 的对象"上调用它，找不到就返回 false：
    /// · 先看那颗 item 子树里每个视图的 **`next`（响应链）**；
    /// · 再**有界扫它们的 ivar**（Element 的 UI 对象一般挂在某个视图的 ivar 上，不在响应链里）。
    ///
    /// ⚠️ 真正的转发主路是 ② `fireTapRecognizers`，只是那个识别器的 action 恰好叫 `-handleTap`。
    /// 这一条是"那一步读不出来时的补网"，不是主路。
    private static func callHandleTap(in item: UIView) -> Bool {
        guard let found = handleTapHolder(in: item) else { return false }
        _ = found.holder.perform(NSSelectorFromString("handleTap"))
        writeDebugLog(
            "[\(logTag)] tap → \(shortName(NSStringFromClass(type(of: found.holder)))) handleTap (\(found.via))"
        )
        return true
    }

    /// 谁响应 `-handleTap`（③ 那条路）。**读得出来**就说明"点了有人接" ——
    /// 所以 `probeForwardRoute` 与 `callHandleTap` 共用这一处。
    private static func handleTapHolder(in item: UIView) -> (holder: NSObject, via: String)? {
        let selector = NSSelectorFromString("handleTap")
        // ① **从"那颗 tap 识别器所在视图"沿响应者链往上找** ——
        // `nil`-target 的动作就是走这条链的，所以实现者最可能在这儿。
        for view in subtree(of: item, maxDepth: 6) {
            for recognizer in view.gestureRecognizers ?? [] where recognizer is UITapGestureRecognizer {
                var responder: UIResponder? = view
                var hops = 0
                while let current = responder, hops < 12 {
                    if let object = current as? NSObject, object.responds(to: selector) {
                        return (object, "responder chain from the tap recogniser's view")
                    }
                    responder = current.next
                    hops += 1
                }
            }
        }
        // ② 原来的两条：子树里每个视图的 `next`，以及它们（含父类）的 ivar。
        for view in subtree(of: item, maxDepth: 6) {
            if let responder = view.next as? NSObject, responder.responds(to: selector) {
                return (responder, "responder chain")
            }
            if let holder = ivarHolding(selector: selector, in: view) {
                let owner = shortName(NSStringFromClass(type(of: view)))
                return (holder, "an ivar of \(owner)")
            }
        }
        return nil
    }

    /// 有界扫一个对象的 ivar（含父类，最多 4 层），找**第一个**响应 `selector` 的对象。
    private static func ivarHolding(selector: Selector, in object: NSObject) -> NSObject? {
        var cls: AnyClass? = type(of: object)
        var hops = 0
        while let current = cls, hops < 4 {
            var count: UInt32 = 0
            if let ivars = class_copyIvarList(current, &count) {
                defer { free(ivars) }
                for index in 0 ..< Int(count) {
                    let ivar = ivars[index]
                    // 只看对象类型的 ivar（编码首字符 '@'）——SEL/int/结构体一律跳过。
                    guard let encoding = ivar_getTypeEncoding(ivar), encoding.pointee == 0x40 else { continue }
                    if let value = object_getIvar(object, ivar) as? NSObject, value.responds(to: selector) {
                        return value
                    }
                }
            }
            cls = class_getSuperclass(current)
            hops += 1
        }
        return nil
    }

    /// 把"这颗 tap 识别器到底把 target 藏在哪"**一次性摊开** —— 那台机器上它逐字是
    /// `UITapGestureRecognizer[nil-target:handleTap]`。
    ///
    /// 打三样（只打一次，就在"五条路全不通"那一刻）：
    /// ① 每对 `_targets` 的**类名**与它自己的**对象型 ivar 及取值类名**
    /// （`_target` / `_targetWeak` / `_targetRef` … 哪个有值，一眼看出来）；
    /// ② 从那颗识别器所在视图沿**响应者链**往上 12 跳的类名，标出谁响应 `handleTap`；
    /// ③ 同一个视图上还有哪些识别器（顺带）。
    ///
    /// ⚠️ 只在第一条"全失败"的点击时打一次：下一次它还是失败，这一行就是唯一的答案。
    private static var didReportTapAnatomy = false

    private static func reportTapAnatomyOnce(_ item: UIView) {
        guard !didReportTapAnatomy else { return }
        didReportTapAnatomy = true

        var pieces: [String] = []
        for view in subtree(of: item, maxDepth: 6) {
            for recognizer in view.gestureRecognizers ?? [] where recognizer is UITapGestureRecognizer {
                let recognizerName = shortName(NSStringFromClass(type(of: recognizer)))
                let viewName = shortName(NSStringFromClass(type(of: view)))

                let pairTexts = pairs(of: recognizer).enumerated().map { offset, pair -> String in
                    let pairName = shortName(NSStringFromClass(type(of: pair)))
                    var fields: [String] = []
                    var cls: AnyClass? = type(of: pair)
                    var hops = 0
                    while let current = cls, hops < 3 {
                        var count: UInt32 = 0
                        if let ivars = class_copyIvarList(current, &count) {
                            defer { free(ivars) }
                            for index in 0 ..< Int(count) {
                                let ivar = ivars[index]
                                // 只看对象类型（'@'）——`_action` 是 SEL，`object_getIvar` 读它会崩。
                                guard let encoding = ivar_getTypeEncoding(ivar), encoding.pointee == 0x40,
                                      let name = ivar_getName(ivar) else { continue }
                                // ⚠️ `object_getIvar` 返回 `Any?`，**不能**直接 `type(of:)`（那是给类类型的
                                // 重载，编译器会报 "expected to be instance of class or
                                // class-constrained type"）⇒ 先 `as AnyObject` 再取类名。
                                let field = String(cString: name)
                                if let raw = object_getIvar(pair, ivar) {
                                    let object = raw as AnyObject
                                    fields.append("\(field)=\(shortName(NSStringFromClass(type(of: object))))")
                                } else {
                                    fields.append("\(field)=nil")
                                }
                            }
                        }
                        cls = class_getSuperclass(current)
                        hops += 1
                    }
                    // 除了 ivar，还把**两条判据**一起打出来：
                    // `imp` = `class_getInstanceMethod(target, action)` 找不找得到（转发路就靠它）；
                    // `responds` = 老那条 `responds(to:)` 门（在这台机器上是 false）。
                    let actionName = action(of: pair).map { NSStringFromSelector($0) } ?? "nil-action"
                    var verdict = "action=\(actionName)"
                    if let action = action(of: pair) {
                        let holder = target(of: pair)
                        let hasIMP = holder.map { class_getInstanceMethod(type(of: $0), action) != nil } ?? false
                        let responds = (holder as? NSObject)?.responds(to: action) ?? false
                        verdict += " imp=\(hasIMP ? "yes" : "no") responds=\(responds ? "yes" : "no")"
                    }
                    return "#\(offset) \(pairName)[\(fields.joined(separator: " "))] \(verdict)"
                }
                pieces.append("\(recognizerName) on \(viewName) { \(pairTexts.joined(separator: " | ")) }")

                var chain: [String] = []
                var responder: UIResponder? = view.next
                var hops = 0
                while let current = responder, hops < 12 {
                    let answers = (current as? NSObject)?.responds(to: NSSelectorFromString("handleTap")) ?? false
                    chain.append(shortName(NSStringFromClass(type(of: current))) + (answers ? "★" : ""))
                    responder = current.next
                    hops += 1
                }
                pieces.append("chain from \(viewName): \(chain.joined(separator: " → "))")
            }
        }
        // 顺带把**容器**的对象型 ivar 也摊开：如果 ①′ 还是读不到 VC 数组，
        // 这一节就是答案（那几个 VC 到底挂在哪儿）。
        if let bar = lastBar, let container = container(of: bar) {
            var fields: [String] = []
            var cls: AnyClass? = type(of: container)
            var hops = 0
            while let current = cls, hops < 3 {
                var count: UInt32 = 0
                if let ivars = class_copyIvarList(current, &count) {
                    defer { free(ivars) }
                    for index in 0 ..< Int(count) {
                        let ivar = ivars[index]
                        guard let encoding = ivar_getTypeEncoding(ivar), encoding.pointee == 0x40,
                              let name = ivar_getName(ivar) else { continue }
                        let field = String(cString: name)
                        if let raw = object_getIvar(container, ivar) {
                            let object = raw as AnyObject
                            let arrayCount = (object as? [AnyObject])?.count
                            let described = arrayCount.map { "array(\($0))" }
                                ?? shortName(NSStringFromClass(type(of: object)))
                            fields.append("\(field)=\(described)")
                        } else {
                            fields.append("\(field)=nil")
                        }
                    }
                }
                cls = class_getSuperclass(current)
                hops += 1
            }
            pieces.append(
                "container \(shortName(NSStringFromClass(type(of: container)))) { \(fields.joined(separator: " ")) }"
            )
        }
        writeDebugLog(
            "[\(logTag)] tap anatomy — \(pieces.isEmpty ? "no tap recogniser at all" : pieces.joined(separator: "; "))"
        )
    }

    /// 第四路：无障碍激活（最深的那一层先试 —— 真正响应点击的往往是里层那颗）。
    private static func activateAccessibility(in item: UIView) -> Bool {
        for view in subtree(of: item, maxDepth: 6).reversed() {
            if view.accessibilityActivate() { return true }
        }
        return false
    }

    /// 第五路：`UIControl` 的 target-action。
    private static func sendControlActions(in item: UIView) -> Bool {
        for view in subtree(of: item, maxDepth: 6) {
            guard let control = view as? UIControl else { continue }
            control.sendActions(for: .touchUpInside)
            return true
        }
        return false
    }

    private static func reportForward(index: Int, route: String) {
        forwardedTaps += 1
        guard forwardedTaps <= 3 else { return }
        writeDebugLog(
            "[\(logTag)] tap on #\(index) forwarded to Spotify — route \(route) (forward #\(forwardedTaps))"
        )
    }

    /// 几条路全不通时的现场：**把子树里的识别器与 UIControl 全列出来**，下一份日志直接给答案。
    ///
    /// **tap 识别器要把转发链逐环写清楚**（`_targets` 在不在 → 有几对 →
    /// 每对的 `_target`/`_action` 解出来没有）。只报类名等于什么都没说。
    private static func reportForwardFailure(index: Int, item: UIView) {
        var pieces: [String] = []
        for view in subtree(of: item, maxDepth: 6) {
            let viewName = shortName(NSStringFromClass(type(of: view)))
            if view is UIControl { pieces.append("UIControl \(viewName)") }
            for recognizer in view.gestureRecognizers ?? [] {
                if recognizer is UITapGestureRecognizer {
                    pieces.append("\(describe(recognizer)) on \(viewName)")
                } else {
                    pieces.append("\(shortName(NSStringFromClass(type(of: recognizer)))) on \(viewName)")
                }
            }
        }
        writeDebugLog(
            "[\(logTag)] ⚠️ tap on #\(index) found nothing to forward to — \(shortName(NSStringFromClass(type(of: item))))"
                + "; inside [\(pieces.isEmpty ? "nothing at all" : pieces.joined(separator: " | "))]"
        )
    }

    /// 把一条 tap 识别器的**转发链**逐环写清楚（`_targets` → 每对 `_target`/`_action`）。
    private static func describe(_ recognizer: UIGestureRecognizer) -> String {
        let name = shortName(NSStringFromClass(type(of: recognizer)))
        guard let ivar = class_getInstanceVariable(UIGestureRecognizer.self, "_targets") else {
            return "\(name)[_targets ivar is gone in this build]"
        }
        guard let raw = object_getIvar(recognizer, ivar) else {
            return "\(name)[_targets is nil]"
        }
        guard let pairs = raw as? [AnyObject] else {
            return "\(name)[_targets is not a walkable array]"
        }
        guard !pairs.isEmpty else { return "\(name)[no target/action pairs at all]" }
        let described = pairs.map { pair -> String in
            let targetName = target(of: pair).map { shortName(NSStringFromClass(type(of: $0))) } ?? "nil-target"
            let actionName = action(of: pair).map { NSStringFromSelector($0) } ?? "nil-action"
            return "\(targetName):\(actionName)"
        }
        return "\(name)[\(described.joined(separator: " "))]"
    }

    private static func subtree(of node: UIView, maxDepth: Int, depth: Int = 0) -> [UIView] {
        guard depth <= maxDepth else { return [] }
        var found: [UIView] = [node]
        for sub in node.subviews { found.append(contentsOf: subtree(of: sub, maxDepth: maxDepth, depth: depth + 1)) }
        return found
    }

    // MARK: - ③ 选中态
    //
    // 选中态：**先看文字亮度**（Spotify 选中那颗画白色、其余 `#B3B3B3`），
    // 再看 `accessibilityTraits.contains(.selected)`。
    //
    // ⚠️ 顺序不能反过来：9.1.88 上 item 的 `traits` **全是 `0x0`**（文字 `#FFFFFF` 是唯一信号）
    // ⇒ 无障碍那条判据**根本不成立**。判据只有一处（这里），用了哪条会打进日志。
    private static func syncSelection(on systemBar: UITabBar, items: [UIView]) {
        // ⚠️ 按 `tag` 找（被藏掉的那一格不在系统栏的 item 列表里 —— 见 `item(at:on:)`）。
        guard let picked = selectedIndex(items: items),
              let target = item(at: picked.index, on: systemBar) else { return }
        if lastSelectionSignal != picked.signal {
            lastSelectionSignal = picked.signal
            writeDebugLog("[\(logTag)] selection signal in use: \(picked.signal)")
        }
        guard picked.index != lastSelectionIndex else { return }
        lastSelectionIndex = picked.index
        systemBar.selectedItem = target
        writeDebugLog("[\(logTag)] selection → #\(picked.index)")
    }

    private static func selectedIndex(items: [UIView]) -> (index: Int, signal: String)? {
        if let index = items.firstIndex(where: { isBrightLabel($0) }) {
            return (index, "bright label")
        }
        if let index = items.firstIndex(where: { $0.accessibilityTraits.contains(.selected) }) {
            return (index, "accessibility selected trait")
        }
        return nil
    }

    private static func isBrightLabel(_ node: UIView) -> Bool {
        guard let color = firstLabelColor(node) else { return false }
        var white: CGFloat = 0, alpha: CGFloat = 0
        if color.getWhite(&white, alpha: &alpha) { return white > 0.85 }
        return false
    }

    /// 有界找第一段文字的颜色（深度 ≤ 4，与探针同一套读法）。
    private static func firstLabelColor(_ node: UIView, depth: Int = 0) -> UIColor? {
        guard depth <= 4 else { return nil }
        if let label = node as? UILabel, let text = label.text, !text.isEmpty {
            return label.textColor
        }
        for sub in node.subviews {
            if let found = firstLabelColor(sub, depth: depth + 1) { return found }
        }
        return nil
    }

    /// 一颗 item 的图标：**先找现成的 `UIImage`；拿不到就把那个"图标视图"整个渲染成一张图**。
    ///
    /// ⚠️ 这一版的图标**不是** `UIImageView` —— 视图树里是
    /// `16.OBJC_ONLY_IconView@40,5,24,24,id=Encore.IconView`（Encore 自己画的图标视图）
    /// ⇒ 只找 `UIImageView.image` **永远拿不到**，于是原图标留在玻璃底下：
    /// 又暗（隔着一层玻璃）又偏（位置由 Spotify 那条栏决定），而那几颗 item 只剩文字。
    /// 所以补一条：**把那个视图的 layer 渲染成 UIImage**，当模板图交给 UIKit
    /// （`.alwaysTemplate` 会自己上色）。
    ///
    /// ⚠️ 快照**必须在藏原图标之前**做（`apply` 里顺序是先 `syncItems` 再 `hideStockContent`）；
    /// 而且要**按视图缓存**，否则每拍都会生成一张"新"图，`syncItems` 的"形状没变就不重建"永远不成立。
    private static func glyphImage(of node: UIView) -> UIImage? {
        if let ready = glyphViews(in: node).first?.image { return ready }
        guard let icon = findIconView(in: node), icon.bounds.width >= 8, icon.bounds.height >= 8 else { return nil }
        let key = ObjectIdentifier(icon)
        if let cached = iconSnapshots[key] { return cached }

        let renderer = UIGraphicsImageRenderer(bounds: icon.bounds)
        let shot = renderer.image { context in
            icon.layer.render(in: context.cgContext)
        }.withRenderingMode(.alwaysTemplate)
        iconSnapshots[key] = shot
        writeDebugLog(
            "[\(logTag)] icon taken from \(shortName(NSStringFromClass(type(of: icon))))"
                + " at \(frameText(icon.bounds)) — read as a snapshot of its layer, because this build draws icons itself"
        )
        return shot
    }

    /// 类名含 `IconView`、尺寸像个图标的那颗视图（深度 ≤ 6）。
    private static func findIconView(in node: UIView, depth: Int = 0) -> UIView? {
        guard depth <= 6 else { return nil }
        if className(node).contains("IconView"), node.bounds.width >= 8, node.bounds.height >= 8 { return node }
        for sub in node.subviews {
            if let found = findIconView(in: sub, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func className(_ view: UIView) -> String {
        NSStringFromClass(type(of: view))
    }

    private static func glyphViews(in node: UIView, depth: Int = 0) -> [UIImageView] {
        guard depth <= 6 else { return [] }
        var found: [UIImageView] = []
        if let imageView = node as? UIImageView, imageView.image != nil { found.append(imageView) }
        for sub in node.subviews { found.append(contentsOf: glyphViews(in: sub, depth: depth + 1)) }
        return found
    }

    /// 那一颗里所有的文字视图（同上，深度 ≤ 6）。
    private static func labelViews(in node: UIView, depth: Int = 0) -> [UILabel] {
        guard depth <= 6 else { return [] }
        var found: [UILabel] = []
        if let label = node as? UILabel, !(label.text ?? "").isEmpty { found.append(label) }
        for sub in node.subviews { found.append(contentsOf: labelViews(in: sub, depth: depth + 1)) }
        return found
    }

    /// 那一颗的文字。
    private static func labelText(of node: UIView) -> String? {
        labelViews(in: node).first?.text
    }

    // MARK: - ④ 让高度
    //
    // 把系统栏**比 Spotify 那条栏多出来的高度**写成容器的 `additionalSafeAreaInsets.bottom`。
    //
    // 为什么是这里：Spotify 那条栏的高度由"安全区往上 49pt"决定，迷你播放器站在同一条基准上，
    // 页面拿 49 + inset ⇒ **只要容器多让出多少，那一整套自己就跟着让**。
    // `additionalSafeAreaInsets` 是**我们写的**，关开关时能**精确写回**。
    //
    // ⚠️ **没有** `made room` 那一行是**正确结果**：Face ID 机型 `83 - 49 - 34 = 0`。
    // ⚠️ 宿主已经把底部安全区报成 0 ⇒ 这里量出来的高度只会更小（差额仍为 0），
    // 也就是说"让高度"这条在 Face ID 机型上依旧不生效。
    private static func makeRoom(for bar: UIView, systemBar: UITabBar) {
        guard let container = container(of: bar), container.isViewLoaded,
              let view = container.view else {
            noteSkipOnce("no TabBarContainerImpl above the bar - not making room")
            return
        }

        let extra = container.additionalSafeAreaInsets
        let inset = view.safeAreaInsets.bottom - extra.bottom
        let height = glassHeight(systemBar, width: bar.bounds.width)
        // Spotify 的常规宽度栏是固定 76pt、不吃 inset；窄宽度时它的栏就是 49 + inset。
        let compact = container.traitCollection.horizontalSizeClass == .compact
        let room = compact ? max(0, ceil(height - stockRowHeight - inset)) : 0
        guard abs(extra.bottom - room) > 0.5 else { return }

        rememberOriginalRoom(for: container, current: extra.bottom)

        var updated = extra
        updated.bottom = room
        container.additionalSafeAreaInsets = updated
        writeDebugLog(
            "[\(logTag)] made room under Spotify's bar: \(Int(room))pt"
                + " (glass \(Int(height)) - row \(Int(stockRowHeight)) - inset \(Int(inset)))"
        )
    }

    private static func glassHeight(_ systemBar: UITabBar, width: CGFloat) -> CGFloat {
        if measuredGlassHeight > 0 { return measuredGlassHeight }
        measuredGlassHeight = systemBar
            .sizeThatFits(CGSize(width: max(width, 1), height: stockRowHeight))
            .height
        return measuredGlassHeight
    }

    private static func restoreRoom(in bar: UIView) {
        guard let container = container(of: bar) else { return }
        guard let state = objc_getAssociatedObject(container, &roomKey) as? RoomState else { return }
        var insets = container.additionalSafeAreaInsets
        guard abs(insets.bottom - state.written) < 0.5 else { return }
        insets.bottom = state.original
        container.additionalSafeAreaInsets = insets
        objc_setAssociatedObject(container, &roomKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        writeDebugLog("[\(logTag)] room restored to \(Int(state.original))pt")
    }

    private final class RoomState: NSObject {
        let original: CGFloat
        let written: CGFloat
        init(original: CGFloat, written: CGFloat) {
            self.original = original
            self.written = written
        }
    }

    /// 第一次写之前记下**原来那个值**（我们只许改自己改过的那一档；别人写过的值不动）。
    private static func rememberOriginalRoom(for container: UIViewController, current: CGFloat) {
        guard objc_getAssociatedObject(container, &roomKey) == nil else { return }
        objc_setAssociatedObject(
            container,
            &roomKey,
            RoomState(original: current, written: current),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    /// 从栏往上找 `TabBarContainerImpl`（它是这条栏的容器 VC）。
    private static func container(of bar: UIView) -> UIViewController? {
        guard let containerClass = NSClassFromString(containerClassName) else { return nil }
        var responder: UIResponder? = bar.next
        var hops = 0
        while let current = responder, hops < 30 {
            if let controller = current as? UIViewController, type(of: controller) == containerClass {
                return controller
            }
            responder = current.next
            hops += 1
        }
        return nil
    }

    // MARK: - 日志与小工具

    private static func noteSkipOnce(_ reason: String) {
        guard lastSkipReason != reason else { return }
        lastSkipReason = reason
        writeDebugLog("[\(logTag)] standing by (\(reason))")
    }

    /// **把"我们给的框"和"UIKit 真画出来的玻璃"放进同一行**。
    ///
    /// UIKit 的浮岛玻璃**按自己的内边距画**（我们给的宿主框 ≠ 玻璃框）⇒ 只有实测数字能收敛：
    /// 这一行里 `host` 是我们摆的、`system bar` 是系统栏自己的、`drawn` 里那几块（platter /
    /// liquid lens / selection）**才是屏幕上真正的那条胶囊**。
    private static func reportGlassGeometry(_ systemBar: UITabBar, in bar: UIView) {
        let host = hostView(for: bar)
        let pieces = platterViews(in: systemBar).map { name, view in
            "\(name)=\(frameText(view.convert(view.bounds, to: bar)))"
        }
        let line = "[\(logTag)] glass geometry — host \(frameText(host?.frame ?? .null))"
            + "; system bar \(frameText(systemBar.frame))"
            + "; drawn [\(pieces.isEmpty ? "not laid out yet" : pieces.joined(separator: " "))]"
        guard line != lastGeometryLine else { return }
        lastGeometryLine = line
        writeDebugLog(line)
    }

    /// 系统栏里"玻璃自己那几块"（按类名认：`Platter` / `LiquidLens` / `SelectionView`）。
    private static func platterViews(in node: UIView, depth: Int = 0) -> [(String, UIView)] {
        guard depth <= 6 else { return [] }
        var found: [(String, UIView)] = []
        let name = NSStringFromClass(type(of: node))
        if name.contains("Platter") || name.contains("LiquidLens") || name.contains("SelectionView") {
            found.append((shortName(name), node))
        }
        for sub in node.subviews { found.append(contentsOf: platterViews(in: sub, depth: depth + 1)) }
        return found
    }

    /// 类名去掉模块前缀。
    private static func shortName(_ name: String) -> String {
        name.split(separator: ".").last.map(String.init) ?? name
    }

    private static func logLayoutOnce(
        bar: UIView,
        items: [UIView],
        systemBar: UITabBar,
        mirrored: Mirror
    ) {
        guard !didLogLayout else { return }
        didLogLayout = true
        // ⚠️ 打的是**每颗的 frame**，不是 `stack.frame`（后者在首拍还没排，是 `0,0,0,0`）。
        let frames = items.map { frameText($0.convert($0.bounds, to: bar)) }.joined(separator: " ")
        // ⚠️ 触摸状态必须**照实报**：写死一句 "taking touches" 会和上面 `apply` 那行
        // `leaving the touches to Spotify's own bar` 自相矛盾。`isUserInteractionEnabled`
        // 是什么就写什么。
        let touchState = systemBar.isUserInteractionEnabled
            ? "; taking the touches, taps forwarded to Spotify's own items"
            : "; not taking the touches (nothing readable to forward a tap to), so Spotify's own bar still gets them"
        writeDebugLog(
            "[\(logTag)] installed — \(items.count) item(s); icons \(mirrored.icons.map { $0 ? "Y" : "N" })"
                + "; item frames [\(frames)]; system bar \(frameText(systemBar.frame))"
                + "; class \(NSStringFromClass(type(of: systemBar)))"
                + touchState
        )
    }

    private static func frameText(_ frame: CGRect) -> String {
        "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
    }
}

/// 系统栏本体。
///
/// 它只管"长得对"；**接管触摸之后**，选中的那一颗由 `TabBarSystemGlassRelay`
/// 转发成对 Spotify 那一颗的点击（见 `forwardSelection`）。
