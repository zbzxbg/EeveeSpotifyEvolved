import Foundation
import UIKit
import ObjectiveC.runtime

/// 标签栏：**把 Spotify 那条栏的内容藏起来，在它上面叠一条系统 `UITabBar`** ——
/// iOS 26 会把它画成**真·液态玻璃**（选中气泡、折射、明暗自适应），**一行玻璃 API 都不用我们写**。
///
/// ## 做法照 pw（`Redesigned/Navbar/TabBar.x`，GPL-3.0；**思路复用、代码自己写**）四步
///
///   ① Spotify 的栏**留着**（frame / 交互 / inset 都不碰），但它的**内容不可见**；
///   ② 叠一条**系统栏**，item 从 Spotify 那几颗同步（顺序跟着；标题与图标同源 ⇒ 开关跟着）；
///   ③ **选中态**：系统栏的选中项跟着"Spotify 把哪一颗标成选中"走 —— 气泡因此会**滑过去/形变**；
///   ④ **让高度**：系统栏比 Spotify 的栏高时，把差额写进 `TabBarContainerImpl` 的
///      `additionalSafeAreaInsets.bottom` ⇒ Spotify 自己把栏 / 迷你播放器 / 页面**一起让开**。
///
/// ## ★ 2026-10-12 第一次真机（日志 63 + 照片 82）——三处已修
///
/// | 现场 | 根因 | 现在的做法 |
/// |---|---|---|
/// | **整条栏点不动**（"划不动"） | 我把**整颗 item 视图**按成 `alpha = 0`，而 UIKit 命中测试**跳过 alpha < 0.01 的视图** ⇒ 点击再也落不到 Spotify 那几颗上 | 只藏**图标与文字**这两个子视图，**item 视图本身的 alpha 一个字不动** ⇒ 看不见但照样收触摸 |
/// | **图标不见了** | 系统栏的 item 只拿到标题（`glyphImage` 没找到），而原图标又被藏了 ⇒ 那行只剩文字 | 先同步、后隐藏：**拿不到图标的那一颗，原图标就不藏**（安全网：绝不留下空行）；并把每颗的 `icon=Y/N` 打进日志 |
/// | 「隐藏标签栏文字」**不生效** | 文字是**系统栏**画的，而我没读那颗开关 | `tabBarHideLabels` 开着时**不给系统栏标题**（原文字本来就被我们藏了） |
///
/// 顺带记两条**实测**（都写进日志了，别再猜）：
///   · `accessibilityTraits` 在 Spotify 9.1.88 上**没有** `.selected` 标记（`traits=0x0`）
///     ⇒ 选中态**实际靠"谁的文字是白色那颗"**：`主页` 的 label 是 `#FFFFFF`、其余 `#B3B3B3`；
///   · 这台机器上 `made room` 那一行**没出现**是**对的**：`83 - 49 - 34 = 0`，本来就不需要让
///     （pw 的注释也这么说：Face ID 机型两条栏本来就对得上）。
///
/// ## ⚠️ 这一片**不吃触摸**（第二片才接管）
///
/// 系统栏 `isUserInteractionEnabled = false` ⇒ 手指点下去落到 **Spotify 自己那条栏**上
/// （它只是**内容不可见**，交互一点没动）⇒ 点击行为与以前一致。
/// 「按下回弹」那种**果冻感**要求系统栏接管触摸 + 把点击**转发**给 Spotify 那一颗 —— 那是第二片。
///
/// ## 开关
///
/// 设置 → 扩展功能 → 标签栏 → 「**标签栏改用系统玻璃**」，**默认关**。
/// 关掉 = 系统栏移除 + 被藏的内容**各自恢复原 alpha** + `additionalSafeAreaInsets` **写回原值**。
/// 日志 tag：`[TabBarSystem]`。
///
/// ⚠️ **整个 enum 标 `@MainActor`**（与 `NowPlayingControlsPlate` 同一个写法）：
///    它要调 `TabBarGlassPlate.findTabsStack(in:)`，而那个函数是 `@MainActor` 的
///    ⇒ 我们不在主 actor 上就会被 Swift 6 并发检查直接判错（CI 2026-10-12 就是这么红的）。
///    两个调用点本来就都在主 actor 上：
///      · `TabBarPlateHook.layoutSubviews` 里那句 —— 包在 `onMainThreadSync` 里，
///        而它的闭包类型就是 `@escaping @MainActor () -> Void`（`LyricsChromeVisibility.swift:25`）；
///      · 设置页 `persist:` 闭包 —— 与既有那些 `NowPlayingControlsPlate.reapply()` 同一个上下文。
@MainActor
enum TabBarSystemGlass {

    static let logTag = "TabBarSystem"

    /// Spotify 自己那一行的高度（真机树里 `UIStackView(0,0 414x49)`）。
    private static let stockRowHeight: CGFloat = 49
    /// `TabBarContainerImpl` 的类名（pw 也是按名字找它：它是 Spotify 那条栏的容器 VC）。
    private static let containerClassName = "_TtC23NavigationUI_TabBarImpl19TabBarContainerImpl"

    static var isEnabled: Bool { UserDefaults.tabBarSystemGlass }

    // MARK: - 状态（全部挂在**别人的对象**上：关联对象 / 弱注册表）

    private static var systemBarKey: UInt8 = 0
    private static var roomKey: UInt8 = 0

    /// 被我们按成透明的**内容**视图（图标 / 文字；**弱引用**）+ 各自的原 alpha。
    ///
    /// ⚠️ 两条纪律：
    ///   · **只藏内容，不藏 item 视图本身** —— 藏了它，触摸就再也到不了 Spotify 那几颗
    ///     （日志 63 的"整条栏点不动"就是这个）；
    ///   · 每个视图记**它自己的**原 alpha，不能一律写 1（仓库在封面那条路上踩过"统一写回 = 永久错"）。
    private static let hiddenContent = NSHashTable<UIView>.weakObjects()
    private static var hiddenContentAlphas: [ObjectIdentifier: CGFloat] = [:]

    /// 系统栏量出来的高度**只量一次**：让出高度之后 `sizeThatFits` 会要得更多（pw 的注释点了这件事）。
    private static var measuredGlassHeight: CGFloat = 0

    private static var lastBar: UIView?
    private static var lastSkipReason = ""
    private static var lastSelectionIndex = -1
    private static var lastSelectionSignal = ""
    private static var didLogLayout = false

    // MARK: - 对外入口

    /// 幂等。由 `TabBarPlateHook.layoutSubviews`（栏自己每次布局）与复查节拍调用。
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

        let items = stack.subviews
        guard !items.isEmpty else { return }

        // ② 先同步系统栏 —— **顺序要紧**：下面"藏什么"取决于"镜像到了什么"
        //   （拿不到图标的那一颗，原图标要留着当安全网）。
        let systemBar = ensureBar(in: bar)
        let mirrored = syncItems(on: systemBar, from: items)

        // ① 藏内容（**不是整颗 item**）：只藏那些已经镜像过去的图标，以及文字。
        hideStockContent(items: items, mirroredIcons: mirrored.icons)

        // ③ 选中态：气泡跟着 Spotify 走。
        syncSelection(on: systemBar, items: items)

        // ④ 让高度（放在最后：量高度要用**还没让过高度**的那次结果）。
        makeRoom(for: bar, systemBar: systemBar)

        logLayoutOnce(bar: bar, items: items, systemBar: systemBar, mirrored: mirrored)
    }

    /// 设置页切开关 / 复查节拍用：手里那次记下的栏还在窗口里就当场重来一次。
    static func reapply() {
        guard let bar = lastBar, bar.window != nil else { return }
        apply(to: bar)
    }

    /// 拿走（关开关 / 页面走了）。**精确还原三件事**：系统栏、内容 alpha、`additionalSafeAreaInsets`。
    static func remove(reason: String, in bar: UIView? = nil) {
        let target = bar ?? lastBar
        if let target {
            if let systemBar = objc_getAssociatedObject(target, &systemBarKey) as? UITabBar {
                systemBar.removeFromSuperview()
                objc_setAssociatedObject(target, &systemBarKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                writeDebugLog("[\(logTag)] system bar removed (reason=\(reason))")
            }
            restoreRoom(in: target)
        }
        restoreStockContent()
        measuredGlassHeight = 0
        didLogLayout = false
        lastSelectionIndex = -1
        lastSelectionSignal = ""
    }

    // MARK: - ① 藏 Spotify 自己的内容（**不藏 item 本身**）

    /// 藏**图标与文字**：图标只藏"已经镜像到系统栏"的那些（安全网），文字一律藏
    /// （文字要么由系统栏画标题，要么本来就该没有 —— 见 `tabBarHideLabels`）。
    private static func hideStockContent(items: [UIView], mirroredIcons: [Bool]) {
        for (index, item) in items.enumerated() {
            if index < mirroredIcons.count, mirroredIcons[index] {
                for glyph in glyphViews(in: item) { hide(glyph) }
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

    // MARK: - ② 系统栏与它的 item

    private struct Mirror {
        var icons: [Bool]
        var titles: [String?]
    }

    private static func ensureBar(in bar: UIView) -> UITabBar {
        if let existing = objc_getAssociatedObject(bar, &systemBarKey) as? TabBarSystemGlassBar {
            if existing.superview !== bar { bar.addSubview(existing) }
            if existing.frame != bar.bounds { existing.frame = bar.bounds }
            bar.bringSubviewToFront(existing)
            return existing
        }

        let systemBar = TabBarSystemGlassBar(frame: bar.bounds)
        systemBar.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // UIKit 按"这条栏继承到的外观"画玻璃，而这条栏在 Spotify 自己的深色导航栈之外
        // ⇒ 浅色模式的手机上会出现"亮玻璃压在纯黑上"。Spotify 永远是深色，这条栏也是。
        systemBar.overrideUserInterfaceStyle = .dark
        systemBar.accessibilityIdentifier = "eevee-tabbar-system-glass"
        // ★ 这一片**不吃触摸**（见文件头）：点下去落到 Spotify 自己那条栏上，点击行为不变。
        systemBar.isUserInteractionEnabled = false
        // 自己的背景不要画：我们要的是系统玻璃本身。
        systemBar.backgroundImage = UIImage()
        systemBar.shadowImage = UIImage()
        systemBar.isTranslucent = true

        bar.addSubview(systemBar)
        bar.bringSubviewToFront(systemBar)
        objc_setAssociatedObject(bar, &systemBarKey, systemBar, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        writeDebugLog(
            "[\(logTag)] system bar added \(frameText(bar.bounds)) on \(NSStringFromClass(type(of: bar)))"
        )
        return systemBar
    }

    /// 从 Spotify 那几颗同步 item（**顺序一致**，索引就是选中态的对齐依据）。
    ///
    /// ★ 两条来自日志 63 的实测：
    ///   · 「隐藏标签栏文字」开着时**不给标题** —— 文字以前由我们自己那盘胶囊负责藏，
    ///     这一条开着时那盘让位了 ⇒ 得由这里负责（用户报的"隐藏标签栏文字对它不生效"）；
    ///   · 图标拿不到就**照实记 `false`**（`glyphImage` 没找到）—— 调用方据此**不藏**原来那颗图标。
    private static func syncItems(on systemBar: UITabBar, from items: [UIView]) -> Mirror {
        let hidesLabels = UserDefaults.tabBarHideLabels

        var wanted: [UITabBarItem] = []
        var icons: [Bool] = []
        var titles: [String?] = []
        wanted.reserveCapacity(items.count)

        for (index, item) in items.enumerated() {
            let title = hidesLabels ? nil : labelText(of: item)
            let image = glyphImage(of: item)?.withRenderingMode(.alwaysTemplate)
            wanted.append(UITabBarItem(title: title, image: image, tag: index))
            icons.append(image != nil)
            titles.append(title)
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
            "[\(logTag)] items synced — \(wanted.count) item(s); titles \(titles.map { $0 ?? "-" })"
                + "; icons \(icons.map { $0 ? "Y" : "N" })"
                + (hidesLabels ? " (the hide-labels switch is on, so no titles)" : "")
        )
        return mirror
    }

    // MARK: - ③ 选中态

    /// 选中态：**先看文字亮度**（Spotify 选中那颗画白色、其余 `#B3B3B3`），
    /// 再看 `accessibilityTraits.contains(.selected)`。
    ///
    /// ⚠️ 顺序**与第一版相反**，依据是日志 63：这台机器上四颗的 `traits` **全是 `0x0`**
    /// （`[TabBarSel] item=TabBar.Item.主页 traits=0x0 … label text=#FFFFFF`，其余 `#B3B3B3`）
    /// ⇒ 无障碍那条判据在 9.1.88 上**根本不成立**，只有亮度是真的。
    /// 判据只有一处（这里），而且**用了哪条会打进日志**，下一份日志能核对。
    private static func syncSelection(on systemBar: UITabBar, items: [UIView]) {
        guard let picked = selectedIndex(items: items),
              picked.index < (systemBar.items?.count ?? 0) else { return }
        if lastSelectionSignal != picked.signal {
            lastSelectionSignal = picked.signal
            writeDebugLog("[\(logTag)] selection signal in use: \(picked.signal)")
        }
        guard picked.index != lastSelectionIndex else { return }
        lastSelectionIndex = picked.index
        systemBar.selectedItem = systemBar.items?[picked.index]
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

    /// 那一颗里所有的图标视图（**最深 6 层**：日志 63 证明原来只找 `UIImageView.image`、
    /// 深度 ≤ 4 时是**找不到**的 —— 所以放宽，并且调用方会按"找没找到"决定藏不藏）。
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

    private static func glyphImage(of node: UIView) -> UIImage? {
        glyphViews(in: node).first?.image
    }

    /// 那一颗的文字。
    ///
    /// ⚠️ **不看 alpha**：那些文字是**我们自己**在上一拍藏掉的（`hideStockContent`），
    /// 按 alpha 过滤的话第二轮就会读成 nil ⇒ 系统栏的标题会在第二拍凭空消失。
    /// "要不要标题"只由「隐藏标签栏文字」那颗开关决定（`syncItems` 里）。
    private static func labelText(of node: UIView) -> String? {
        labelViews(in: node).first?.text
    }

    // MARK: - ④ 让高度

    /// 把系统栏**比 Spotify 那条栏多出来的高度**写成容器的 `additionalSafeAreaInsets.bottom`。
    ///
    /// 为什么是这里（pw 的注释写得很清楚）：Spotify 那条栏的高度由"安全区往上 49pt"决定，
    /// 迷你播放器站在同一条基准上，页面拿 49 + inset ⇒ **只要容器多让出多少，那一整套自己就跟着让**。
    /// `additionalSafeAreaInsets` 是**我们写的**，关开关时能**精确写回**。
    ///
    /// ⚠️ 日志 63 里**没有** `made room` 那一行是**正确结果**：Face ID 机型 `83 - 49 - 34 = 0`。
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

    /// 从栏往上找 `TabBarContainerImpl`（pw 也是这么找的：它是这条栏的容器 VC）。
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

    private static func logLayoutOnce(
        bar: UIView,
        items: [UIView],
        systemBar: UITabBar,
        mirrored: Mirror
    ) {
        guard !didLogLayout else { return }
        didLogLayout = true
        // ⚠️ 日志 63 里我打的是 `stack.frame`，那时它是 `0,0,0,0`（还没排）⇒ 现在改打**每颗的 frame**。
        let frames = items.map { frameText($0.convert($0.bounds, to: bar)) }.joined(separator: " ")
        writeDebugLog(
            "[\(logTag)] installed — \(items.count) item(s); icons \(mirrored.icons.map { $0 ? "Y" : "N" })"
                + "; item frames [\(frames)]; system bar \(frameText(systemBar.frame))"
                + "; class \(NSStringFromClass(type(of: systemBar)))"
                + "; not taking touches (taps go to Spotify's own bar)"
        )
    }

    private static func frameText(_ frame: CGRect) -> String {
        "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
    }
}

/// 系统栏本体。
///
/// 这一片它**只负责长得对**（真玻璃 + 让选中气泡跟着走），**不接管触摸** —— 见文件头的说明。
final class TabBarSystemGlassBar: UITabBar {
}
